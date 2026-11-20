#!/usr/bin/env bash
# =============================================================================
#  HCR Server — instalador MUSTAFA
#  Instala el servidor HCR (protocolo binario propio, TLS) como servicio
#  systemd. Escucha en :8080 (TLS) y reenvía al SSH local (127.0.0.1:22).
#  La app Mustafa VPN se conecta con el modo HCR (modo 8).
#
#  EL CÓDIGO: se compila desde la fuente limpia que viene junto a este
#  script, en el directorio "hcr-src" (implementación clean-room del
#  protocolo HCR v1, solo Go estándar + tun2socks/x/crypto). Por eso este
#  instalador no depende de ningún binario cerrado ni de descargas de
#  terceros: la fuente viaja con el instalador.
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash hcr.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/hcr-src"
BIN="/usr/local/bin/hcr-server"
CONF_DIR="/etc/hcr"
SERVICE="hcr-server"
LISTEN=""  # se fija en el bloque "Puerto" de abajo (HCR_PORT o actual o :8080)
SSH_TARGET="127.0.0.1:22"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[hcr] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash hcr.sh)."

# --- Puerto --------------------------------------------------------------------
# HCR_PORT lo fija quien llama (el menú). Sin él se mantiene el puerto
# actual (si ya está instalado) o 8080.
PORT_REQ="${HCR_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/hcr ]] && p="$(cat /etc/mustafa/ports/hcr 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep -o -- '-listen :[0-9]*' /etc/systemd/system/hcr-server.service 2>/dev/null | grep -o '[0-9]*$' || true)"
    fi
    [[ -z "$p" ]] && p="8080"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) fail "HCR_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "HCR_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi
LISTEN=":$PORT"

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[hcr] Desinstalando HCR..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$BIN"
    rm -rf "$CONF_DIR" /etc/mustafa/ports/hcr
    systemctl daemon-reload 2>/dev/null || true
    echo "[hcr] HCR desinstalado (servicio, binario y /etc/hcr eliminados)."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        info "HCR ya está instalado y activo."
        info "  Escucha : $LISTEN (TLS) -> SSH $SSH_TARGET"
        systemctl --no-pager status "$SERVICE" --lines=5 || true
        exit 0
    fi
    info "Cambiando puerto HCR de $(port_actual) a $PORT_REQ ..."
fi

# --- Go ----------------------------------------------------------------------
# Devuelve 0 si el binario "go" dado es versión >= $2.$3.
go_version_ok() {
    local v major minor
    v="$("$1" version 2>/dev/null | awk '{print $3}')" || return 1
    v="${v#go}"
    major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
    case "$major$minor" in ""|*[!0-9]*) return 1 ;; esac
    [ "$major" -gt "$2" ] || { [ "$major" -eq "$2" ] && [ "$minor" -ge "$3" ]; }
}

# Deja el binario "go" a usar en la variable global GO_BIN (descarga
# Go 1.27.4 a un directorio temporal si el sistema no tiene uno suficiente).
# NO se captura con $(...) : la captura corre en un subshell, donde
# (a) los mensajes info irían mezclados en GO_BIN y (b) el trap EXIT
# borraría el Go descargado antes de compilar. Los mensajes van a stderr.
obtener_go() {
    if command -v go >/dev/null 2>&1 && go_version_ok "$(command -v go)" 1 26; then
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
    GO_TMPDIR="$(mktemp -d /tmp/hcr-go.XXXXXX)"
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
    go_version_ok "$gobin" 1 26 || { rm -rf "$GO_TMPDIR"; fail "El Go descargado no es >= 1.26."; }
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

# --- Compilación (solo si no hay binario) --------------------------------------
if [[ ! -x "$BIN" ]]; then
    for f in "$SRC_DIR/go.mod" "$SRC_DIR/go.sum" "$SRC_DIR/cmd/hcr-server/main.go"; do
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio hcr-src debe estar junto a hcr.sh)."
    done
    GO_BIN=""
    obtener_go || exit 1
    info "Compilando hcr-server desde $SRC_DIR ..."
    (cd "$SRC_DIR" && GOTOOLCHAIN=local GOFLAGS=-mod=mod CGO_ENABLED=0 \
        "$GO_BIN" build -trimpath -ldflags "-s -w" \
        -o "$BIN" ./cmd/hcr-server) ||
        fail "La compilación falló. Revisa el error de arriba."
    limpiar_go_tmp; GO_TMPDIR=""
    [ -x "$BIN" ] || fail "No quedó el binario en $BIN."
    chmod 755 "$BIN"
    info "Binario compilado: $(stat -c %s "$BIN") bytes"
else
    info "Binario ya presente en $BIN, se reutiliza (sin compilar)."
fi

# --- Certificado TLS autofirmado ----------------------------------------------
mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF_DIR/cert.pem" ]]; then
    info "Generando certificado autofirmado (CN=hcr.local, 3650 días) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
        -subj "/CN=hcr.local" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 600 "$CONF_DIR/key.pem"
else
    info "Certificado existente en $CONF_DIR, se reutiliza."
fi

# --- Servicio systemd -----------------------------------------------------------
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=HCR server (MUSTAFA, TLS -> SSH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN -listen $LISTEN -transport tls -target $SSH_TARGET -tls-cert $CONF_DIR/cert.pem -tls-key $CONF_DIR/key.pem
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
echo "$PORT" > /etc/mustafa/ports/hcr

IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
info "HCR instalado y corriendo."
info "  Escucha : $LISTEN (TLS, CN=hcr.local) -> SSH $SSH_TARGET"
info "  Servicio: $SERVICE.service"
info "  Binario : $BIN"
info "  En la app Mustafa VPN usa HCR (modo 8) con ${IP:-<IP>}:${LISTEN##*:} y un usuario SSH."
info "  Logs    : journalctl -u $SERVICE -f"
