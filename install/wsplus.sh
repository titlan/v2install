#!/usr/bin/env bash
# =============================================================================
#  WSPLUS Server — instalador MUSTAFA
#  Instala el servidor WSPLUS (handshake HTTP Upgrade 101 idéntico a
#  WebSocket, luego bytes crudos al SSH, sin framing de WebSocket; token
#  por contraseña, TLS con cert autofirmado) como servicio systemd.
#  Escucha en :8081 (TLS) y reenvía al SSH local (127.0.0.1:22).
#  La app Mustafa VPN se conecta con el modo WSPLUS (modo 11).
#
#  EL CÓDIGO: se compila desde la fuente que viene junto a este script, en
#  el directorio "wsplus-src" (main.go + go.mod, solo librería estándar de
#  Go, sin dependencias externas). No descarga binarios ni usa GitHub.
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash wsplus.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/wsplus-src"
BIN="/usr/local/bin/wsplus-server"
CONF_DIR="/etc/wsplus"
SERVICE="wsplus"
ADDR=":8081"
SSH_ADDR="127.0.0.1:22"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[wsplus] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash wsplus.sh)."

# --- Puerto --------------------------------------------------------------------
# WSPLUS_PORT lo fija quien llama (el menú). Sin él se mantiene el puerto
# actual (si ya está instalado) o 8081.
PORT_REQ="${WSPLUS_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/wsplus ]] && p="$(cat /etc/mustafa/ports/wsplus 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep -o -- '--listen :[0-9]*' /etc/systemd/system/wsplus.service 2>/dev/null | grep -o '[0-9]*$' || true)"
    fi
    [[ -z "$p" ]] && p="8081"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) fail "WSPLUS_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "WSPLUS_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi
ADDR=":$PORT"

# --- IP pública (IPv4; ifconfig.me devuelve IPv6 en algunas VMs) --------------
# Se define antes de la idempotencia porque ahí ya se usa.
ip_publica() {
    local ip=""
    ip="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        printf '%s' "$ip"
        return
    fi
    hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[wsplus] Desinstalando WSPLUS..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$BIN"
    rm -rf "$CONF_DIR" /etc/mustafa/ports/wsplus
    systemctl daemon-reload 2>/dev/null || true
    echo "[wsplus] WSPLUS desinstalado (servicio, binario y /etc/wsplus eliminados)."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        info "WSPLUS ya está instalado y activo."
        info "  Escucha : $ADDR (TLS) -> SSH $SSH_ADDR"
        if [[ -f "$CONF_DIR/password" ]]; then
            IP="$(ip_publica)"
            info "  Enlace: wsplus://$(cat "$CONF_DIR/password")@${IP:-<IP>}:${ADDR##*:}?insecure=1"
        fi
        systemctl --no-pager status "$SERVICE" --lines=5 || true
        exit 0
    fi
    info "Cambiando puerto WSPLUS de $(port_actual) a $PORT_REQ ..."
fi

# --- Go ----------------------------------------------------------------------
go_version_ok() {
    local v major minor
    v="$("$1" version 2>/dev/null | awk '{print $3}')" || return 1
    v="${v#go}"
    major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
    case "$major$minor" in ""|*[!0-9]*) return 1 ;; esac
    [ "$major" -gt "$2" ] || { [ "$major" -eq "$2" ] && [ "$minor" -ge "$3" ]; }
}

obtener_go() {
    # Deja el binario "go" a usar en la variable global GO_BIN.
    # NO se captura con $(...) : la captura corre en un subshell, donde
    # (a) los mensajes info irían mezclados en GO_BIN y (b) el trap EXIT
    # borraría el Go descargado antes de compilar. Los mensajes van a stderr.
    if command -v go >/dev/null 2>&1 && go_version_ok "$(command -v go)" 1 23; then
        info "Usando Go del sistema: $(go version)" >&2
        GO_BIN="$(command -v go)"
        return
    fi
    command -v curl >/dev/null 2>&1 || fail "Para descargar Go se necesita curl."
    local arch tgz sha
    case "$(uname -m)" in
        x86_64|amd64)  arch="amd64"; sha="$GO_SHA256_AMD64" ;;
        aarch64|arm64) arch="arm64"; sha="$GO_SHA256_ARM64" ;;
        *) fail "Arquitectura no soportada: $(uname -m)" ;;
    esac
    tgz="$GO_VERSION.linux-$arch.tar.gz"
    GO_TMPDIR="$(mktemp -d /tmp/wsplus-go.XXXXXX)"
    info "Descargando Go $GO_VERSION ($arch) de go.dev ..." >&2
    curl -fsSL -o "$GO_TMPDIR/$tgz" "https://go.dev/dl/$tgz" ||
        { rm -rf "$GO_TMPDIR"; fail "No se pudo descargar Go."; }
    local got
    got="$(sha256sum "$GO_TMPDIR/$tgz" | awk '{print $1}')"
    [ "$got" = "$sha" ] || { rm -rf "$GO_TMPDIR"; fail "El SHA-256 de Go no coincide (descarga corrupta)."; }
    tar -xzf "$GO_TMPDIR/$tgz" -C "$GO_TMPDIR" ||
        { rm -rf "$GO_TMPDIR"; fail "No se pudo descomprimir Go."; }
    local gobin="$GO_TMPDIR/go/bin/go"
    [ -x "$gobin" ] || { rm -rf "$GO_TMPDIR"; fail "El toolchain descargado no trae el binario go."; }
    go_version_ok "$gobin" 1 23 || { rm -rf "$GO_TMPDIR"; fail "El Go descargado no es >= 1.23."; }
    info "Go $GO_VERSION listo: $($gobin version)" >&2
    GO_BIN="$gobin"
}

limpiar_go_tmp() {
    [ -n "$GO_TMPDIR" ] && [ -d "$GO_TMPDIR" ] && rm -rf "$GO_TMPDIR"
    # Siempre 0: con set -e, si esta función (trap EXIT) devuelve 1
    # el script terminaría con exit 1 aunque todo haya ido bien.
    return 0
}
trap limpiar_go_tmp EXIT

# --- Compilación (solo si no hay binario; solo stdlib, sin red) ---------------
if [[ ! -x "$BIN" ]]; then
    for f in "$SRC_DIR/go.mod" "$SRC_DIR/main.go"; do
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio wsplus-src debe estar junto a wsplus.sh)."
    done
    GO_BIN=""
    obtener_go || exit 1
    info "Compilando wsplus-server desde $SRC_DIR ..."
    (cd "$SRC_DIR" && GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0 \
        "$GO_BIN" build -trimpath -ldflags "-s -w" \
        -o "$BIN" .) ||
        fail "La compilación falló. Revisa el error de arriba."
    limpiar_go_tmp; GO_TMPDIR=""
    [ -x "$BIN" ] || fail "No quedó el binario en $BIN."
    chmod 755 "$BIN"
    info "Binario compilado: $(stat -c %s "$BIN") bytes"
else
    info "Binario ya presente en $BIN, se reutiliza (sin compilar)."
fi

# --- Contraseña (se reutiliza si ya existe) ------------------------------------
mkdir -p "$CONF_DIR"
if [[ -n "${WSPLUS_PASSWORD:-}" ]]; then
    PASSWORD="$WSPLUS_PASSWORD"
elif [[ -f "$CONF_DIR/password" ]]; then
    PASSWORD="$(cat "$CONF_DIR/password")"
    info "Reutilizando contraseña existente en $CONF_DIR/password"
else
    # (|| true: con pipefail, tr muere por SIGPIPE cuando head ya leyó
    #  24 caracteres y eso mataría el script con exit 141.)
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24 || true)"
fi
printf '%s' "$PASSWORD" > "$CONF_DIR/password"
chmod 600 "$CONF_DIR/password"

# --- Certificado TLS autofirmado ----------------------------------------------
if [[ ! -f "$CONF_DIR/cert.pem" ]]; then
    info "Generando certificado autofirmado (CN=wsplus, 3650 días) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
        -subj "/CN=wsplus" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 600 "$CONF_DIR/key.pem"
else
    info "Certificado existente en $CONF_DIR, se reutiliza."
fi

# --- Servicio systemd -----------------------------------------------------------
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=wsplus server (MUSTAFA, Upgrade 101 -> SSH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN --listen $ADDR --target $SSH_ADDR --password-file $CONF_DIR/password --cert $CONF_DIR/cert.pem --key $CONF_DIR/key.pem
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
systemctl is-active --quiet "$SERVICE" ||
    fail "El servicio no quedó activo. Revisa con: journalctl -u $SERVICE -n 50"
ss -tln 2>/dev/null | grep -q ":$PORT " ||
    fail "El servicio está activo pero no escucha en el puerto $PORT. Revisa: journalctl -u $SERVICE -n 50"
mkdir -p /etc/mustafa/ports
echo "$PORT" > /etc/mustafa/ports/wsplus

IP="$(ip_publica)"
echo
info "WSPLUS instalado y corriendo."
info "  Escucha : $ADDR (TLS) -> SSH $SSH_ADDR"
info "  Servicio: $SERVICE.service"
info "  Enlace para pegar en la app (modo WSPLUS):"
info "    wsplus://$PASSWORD@${IP:-<IP>}:${ADDR##*:}?insecure=1"
info "  La contraseña también está en $CONF_DIR/password"
info "  Logs    : journalctl -u $SERVICE -f"
