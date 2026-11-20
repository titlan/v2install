#!/usr/bin/env bash
# =============================================================================
#  Hysteria2 — instalador MUSTAFA
#  Instala el servidor Hysteria2 (HyNetwork/hysteria, QUIC sobre UDP) como
#  servicio systemd. Escucha en UDP :443 por defecto y sirve como proxy
#  general (el tráfico que no es Hysteria2 se camufla hacia
#  www.microsoft.com). La app Mustafa VPN NO trae cliente Hysteria2
#  (solo Hysteria v1, modo 6): este servidor se usa con sing-box,
#  NekoBox, Hiddify o el cliente oficial.
#
#  EL BINARIO: se descarga el binario OFICIAL del último release de
#  HyNetwork/hysteria (mismo criterio que Xray: el proyecto publica
#  binarios oficiales y se verifica su SHA-256 contra hashes.txt).
#  No se compila desde fuente (proyecto Go grande, muchos módulos).
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash hysteria2.sh
# =============================================================================

set -euo pipefail

BIN="/usr/local/bin/hysteria"
CONF_DIR="/etc/hysteria2"
CONF="$CONF_DIR/config.yaml"
PASS_FILE="$CONF_DIR/password"
CERT="$CONF_DIR/cert.pem"
KEY="$CONF_DIR/key.pem"
SERVICE="hysteria2"
REPO="HyNetwork/hysteria"

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[hysteria2] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash hysteria2.sh)."

# --- Puerto --------------------------------------------------------------------
# HYSTERIA2_PORT lo fija quien llama (el menú). Sin él se mantiene el puerto
# actual (si ya está instalado) o 443 (UDP; no choca con Xray, que usa TCP 443).
PORT_REQ="${HYSTERIA2_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/hysteria2 ]] && p="$(cat /etc/mustafa/ports/hysteria2 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep -o -- '^listen: :[0-9]*' "$CONF" 2>/dev/null | grep -o '[0-9]*$' || true)"
    fi
    [[ -z "$p" ]] && p="443"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) fail "HYSTERIA2_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "HYSTERIA2_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[hysteria2] Desinstalando Hysteria2..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$BIN"
    rm -rf "$CONF_DIR" /etc/mustafa/ports/hysteria2
    systemctl daemon-reload 2>/dev/null || true
    echo "[hysteria2] Hysteria2 desinstalado (servicio, binario y /etc/hysteria2 eliminados)."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        info "Hysteria2 ya está instalado y activo."
        info "  Escucha UDP :$PORT"
        if [[ -f "$PASS_FILE" ]]; then
            IP="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
            info "  Enlace: hysteria2://$(cat "$PASS_FILE")@${IP:-<IP>}:$PORT/?insecure=1#MUSTAFA-HY2"
        fi
        systemctl --no-pager status "$SERVICE" --lines=5 || true
        exit 0
    fi
    info "Cambiando puerto Hysteria2 de $(port_actual) a $PORT_REQ ..."
fi

# --- Binario oficial (solo si no hay uno que funcione) -------------------------
if [[ ! -x "$BIN" ]] || ! "$BIN" version >/dev/null 2>&1; then
    command -v curl >/dev/null 2>&1 || fail "Para descargar Hysteria2 se necesita curl."
    command -v jq >/dev/null 2>&1 || fail "Para descargar Hysteria2 se necesita jq."
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l|armv7)  arch="arm" ;;
        *) fail "Arquitectura no soportada: $(uname -m)" ;;
    esac
    TAG="$(curl -fsSL -m 20 "https://api.github.com/repos/$REPO/releases/latest" | jq -r '.tag_name // empty')"
    [[ -n "$TAG" ]] || fail "No se pudo obtener el último release de $REPO."
    info "Descargando Hysteria2 $TAG (linux-$arch) del release oficial ..."
    TMPD="$(mktemp -d /tmp/hysteria2-dl.XXXXXX)"
    curl -fsSL -o "$TMPD/hysteria" "https://github.com/$REPO/releases/download/$TAG/hysteria-linux-$arch" ||
        { rm -rf "$TMPD"; fail "No se pudo descargar el binario."; }
    curl -fsSL -o "$TMPD/hashes.txt" "https://github.com/$REPO/releases/download/$TAG/hashes.txt" ||
        { rm -rf "$TMPD"; fail "No se pudo descargar hashes.txt para verificar."; }
    EXPECTED="$(awk -v f="hysteria-linux-$arch" '$2 == "build/"f {print $1}' "$TMPD/hashes.txt")"
    [[ -n "$EXPECTED" ]] || { rm -rf "$TMPD"; fail "No hay SHA-256 publicado para hysteria-linux-$arch."; }
    GOT="$(sha256sum "$TMPD/hysteria" | awk '{print $1}')"
    [ "$GOT" = "$EXPECTED" ] || { rm -rf "$TMPD"; fail "El SHA-256 del binario no coincide (descarga corrupta)."; }
    install -m 755 "$TMPD/hysteria" "$BIN"
    rm -rf "$TMPD"
    info "Binario instalado: $("$BIN" version 2>/dev/null | grep -i '^Version' || "$BIN" version 2>/dev/null | head -n 1 || true)"
else
    info "Binario ya presente en $BIN, se reutiliza (sin descargar)."
fi

# --- Contraseña (se reutiliza si ya existe) ------------------------------------
mkdir -p "$CONF_DIR"
if [[ -f "$PASS_FILE" ]]; then
    PASSWORD="$(cat "$PASS_FILE")"
    info "Reutilizando contraseña existente en $PASS_FILE"
else
    # (|| true: con pipefail, tr muere por SIGPIPE cuando head ya leyó
    #  24 caracteres y eso mataría el script con exit 141.)
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
fi
printf '%s' "$PASSWORD" > "$PASS_FILE"
chmod 600 "$PASS_FILE"

# --- Certificado TLS autofirmado ----------------------------------------------
if [[ ! -f "$CERT" ]]; then
    info "Generando certificado autofirmado (CN=hysteria2, 3650 días) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$KEY" -out "$CERT" \
        -subj "/CN=hysteria2" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 600 "$KEY"
else
    info "Certificado existente en $CONF_DIR, se reutiliza."
fi

# --- Configuración -------------------------------------------------------------
cat > "$CONF" <<EOF
listen: :$PORT

tls:
  cert: $CERT
  key: $KEY

auth:
  type: password
  password: "$PASSWORD"

masquerade:
  type: proxy
  proxy:
    url: https://www.microsoft.com
    rewriteHost: true
EOF
chmod 600 "$CONF"

# --- Servicio systemd -----------------------------------------------------------
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Hysteria2 server (MUSTAFA, QUIC/UDP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN server -c $CONF
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# enable --now solo no reinicia un servicio que ya corre: un cambio
# de puerto exige reiniciar para que tome la nueva config.
systemctl enable "$SERVICE"
systemctl restart "$SERVICE" || true
sleep 1
if ! systemctl is-active --quiet "$SERVICE"; then
    echo "[hysteria2] El servicio no quedó activo. Diario:"
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null || true
    echo "[hysteria2] Puertos UDP:"
    ss -uln 2>/dev/null | head -20 || true
    fail "El servicio $SERVICE no quedó activo."
fi
# Verificar que REALMENTE escucha en el puerto UDP elegido (no solo "activo").
ss -uln 2>/dev/null | grep -q ":$PORT " ||
    fail "El servicio está activo pero no escucha en UDP :$PORT. Revisa: journalctl -u $SERVICE -n 50"
mkdir -p /etc/mustafa/ports
echo "$PORT" > /etc/mustafa/ports/hysteria2

IP="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
info "Hysteria2 instalado y corriendo."
info "  Escucha UDP :$PORT (QUIC)"
info "  Servicio: $SERVICE.service"
info "  Enlace para pegar en el cliente (sing-box / NekoBox / Hiddify):"
info "    hysteria2://$PASSWORD@${IP:-<IP>}:$PORT/?insecure=1#MUSTAFA-HY2"
info "  La contraseña también está en $PASS_FILE"
info "  Logs    : journalctl -u $SERVICE -f"
