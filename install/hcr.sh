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
LISTEN=":8080"
SSH_TARGET="127.0.0.1:22"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[hcr] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash hcr.sh)."

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "HCR ya está instalado y activo."
    info "  Escucha : $LISTEN (TLS) -> SSH $SSH_TARGET"
    systemctl --no-pager status "$SERVICE" --lines=5 || true
    exit 0
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

# Devuelve por stdout la ruta del binario "go" a usar (descarga Go 1.27.4
# a un directorio temporal si el sistema no tiene uno suficiente).
obtener_go() {
    if command -v go >/dev/null 2>&1 && go_version_ok "$(command -v go)" 1 26; then
        info "Usando Go del sistema: $(go version)"
        command -v go
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
    info "Descargando Go $GO_VERSION ($arch) de go.dev ..."
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
    info "Go $GO_VERSION listo: $($gobin version)"
    echo "$gobin"
}

limpiar_go_tmp() {
    [ -n "$GO_TMPDIR" ] && [ -d "$GO_TMPDIR" ] && rm -rf "$GO_TMPDIR"
}
trap limpiar_go_tmp EXIT

# --- Compilación (solo si no hay binario) --------------------------------------
if [[ ! -x "$BIN" ]]; then
    for f in "$SRC_DIR/go.mod" "$SRC_DIR/go.sum" "$SRC_DIR/cmd/hcr-server/main.go"; do
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio hcr-src debe estar junto a hcr.sh)."
    done
    GO_BIN="$(obtener_go)" || exit 1
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
systemctl enable --now "$SERVICE"
sleep 1
systemctl is-active --quiet "$SERVICE" ||
    fail "El servicio no quedó activo. Revisa con: journalctl -u $SERVICE -n 50"

IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
info "HCR instalado y corriendo."
info "  Escucha : $LISTEN (TLS, CN=hcr.local) -> SSH $SSH_TARGET"
info "  Servicio: $SERVICE.service"
info "  Binario : $BIN"
info "  En la app Mustafa VPN usa HCR (modo 8) con ${IP:-<IP>}:8080 y un usuario SSH."
info "  Logs    : journalctl -u $SERVICE -f"
