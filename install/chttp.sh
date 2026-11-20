#!/usr/bin/env bash
# =============================================================================
#  CHTTP Server — instalador MUSTAFA
#  Instala el servidor CHTTP (protocolo binario propio, TLS obligatorio,
#  AES-256-GCM, token por contraseña) como servicio systemd. Escucha en
#  :8445 (TLS) y reenvía al SSH local (127.0.0.1:22).
#  La app Mustafa VPN se conecta con el modo CHTTP (modo 10).
#
#  EL CÓDIGO: se compila desde la fuente que viene junto a este script, en
#  el directorio "chttp-src" (main.go + go.mod, solo librería estándar de
#  Go, sin dependencias externas). No descarga binarios ni usa GitHub.
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash chttp.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/chttp-src"
BIN="/usr/local/bin/chttp-server"
CONF_DIR="/etc/chttp"
SERVICE="chttp"
ADDR=":8445"
SSH_ADDR="127.0.0.1:22"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[chttp] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash chttp.sh)."

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "CHTTP ya está instalado y activo."
    info "  Escucha : $ADDR (TLS) -> SSH $SSH_ADDR"
    if [[ -f "$CONF_DIR/password" ]]; then
        IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
        info "  Enlace: chttp://$(cat "$CONF_DIR/password")@${IP:-<IP>}:${ADDR##*:}?insecure=1"
    fi
    systemctl --no-pager status "$SERVICE" --lines=5 || true
    exit 0
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
    if command -v go >/dev/null 2>&1 && go_version_ok "$(command -v go)" 1 23; then
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
    GO_TMPDIR="$(mktemp -d /tmp/chttp-go.XXXXXX)"
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
    go_version_ok "$gobin" 1 23 || { rm -rf "$GO_TMPDIR"; fail "El Go descargado no es >= 1.23."; }
    info "Go $GO_VERSION listo: $($gobin version)"
    echo "$gobin"
}

limpiar_go_tmp() {
    [ -n "$GO_TMPDIR" ] && [ -d "$GO_TMPDIR" ] && rm -rf "$GO_TMPDIR"
}
trap limpiar_go_tmp EXIT

# --- Compilación (solo si no hay binario; solo stdlib, sin red) ---------------
if [[ ! -x "$BIN" ]]; then
    for f in "$SRC_DIR/go.mod" "$SRC_DIR/main.go"; do
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio chttp-src debe estar junto a chttp.sh)."
    done
    GO_BIN="$(obtener_go)" || exit 1
    info "Compilando chttp-server desde $SRC_DIR ..."
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
if [[ -n "${CHTTP_PASSWORD:-}" ]]; then
    PASSWORD="$CHTTP_PASSWORD"
elif [[ -f "$CONF_DIR/password" ]]; then
    PASSWORD="$(cat "$CONF_DIR/password")"
    info "Reutilizando contraseña existente en $CONF_DIR/password"
else
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
fi
printf '%s' "$PASSWORD" > "$CONF_DIR/password"
chmod 600 "$CONF_DIR/password"

# --- Certificado TLS autofirmado ----------------------------------------------
if [[ ! -f "$CONF_DIR/cert.pem" ]]; then
    info "Generando certificado autofirmado (CN=chttp, 3650 días) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
        -subj "/CN=chttp" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 600 "$CONF_DIR/key.pem"
else
    info "Certificado existente en $CONF_DIR, se reutiliza."
fi

# --- Servicio systemd -----------------------------------------------------------
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=chttp server (MUSTAFA, TLS + AES-256-GCM -> SSH)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN --password-file $CONF_DIR/password --addr $ADDR --cert $CONF_DIR/cert.pem --key $CONF_DIR/key.pem --ssh-addr $SSH_ADDR --allow 127.0.0.1:* --allow ::1:*
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
info "CHTTP instalado y corriendo."
info "  Escucha : $ADDR (TLS) -> SSH $SSH_ADDR"
info "  Servicio: $SERVICE.service"
info "  Enlace para pegar en la app (modo CHTTP):"
info "    chttp://$PASSWORD@${IP:-<IP>}:${ADDR##*:}?insecure=1"
info "  La contraseña también está en $CONF_DIR/password"
info "  Logs    : journalctl -u $SERVICE -f"
