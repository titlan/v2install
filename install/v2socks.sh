#!/usr/bin/env bash
# =============================================================================
#  V2SOCKS Server — instalador MUSTAFA
#  Instala el servidor V2SOCKS (TCP dentro de un canal de datos WebRTC,
#  DTLS+SCTP por UDP; se ve como una videollamada, sin SNI ni HTTP) como
#  servicio systemd. Señalización HTTPS en :8444, WebRTC por UDP :3478,
#  destino solo loopback (SSH 127.0.0.1:22).
#  La app Mustafa VPN se conecta con el modo V2SOCKS (modo 12).
#
#  EL CÓDIGO: se compila desde la fuente que viene junto a este script, en
#  el directorio "v2socks-src" (main.go + go.mod + go.sum, módulos
#  pion/webrtc). No descarga binarios ni usa GitHub: los módulos Go se
#  descargan del proxy oficial de Go al compilar (se necesita internet).
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash v2socks.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/v2socks-src"
BIN="/usr/local/bin/v2socks-server"
CONF_DIR="/etc/v2socks"
SERVICE="v2socks"
SIGNAL_PORT="8444"
UDP_PORT="3478"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[v2socks] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash v2socks.sh)."

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "V2SOCKS ya está instalado y activo."
    info "  Señalización :$SIGNAL_PORT (HTTPS) + WebRTC UDP :$UDP_PORT"
    if [[ -f "$CONF_DIR/password" ]]; then
        IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
        info "  Enlace: v2socks://$(cat "$CONF_DIR/password")@${IP:-<IP>}:$SIGNAL_PORT?udp-port=$UDP_PORT&insecure=1"
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
    GO_TMPDIR="$(mktemp -d /tmp/v2socks-go.XXXXXX)"
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

# --- Compilación (solo si no hay binario; descarga módulos pion) --------------
if [[ ! -x "$BIN" ]]; then
    for f in "$SRC_DIR/go.mod" "$SRC_DIR/go.sum" "$SRC_DIR/main.go"; do
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio v2socks-src debe estar junto a v2socks.sh)."
    done
    GO_BIN="$(obtener_go)" || exit 1
    info "Compilando v2socks-server desde $SRC_DIR (descarga módulos pion/webrtc) ..."
    (cd "$SRC_DIR" && GOTOOLCHAIN=local GOFLAGS=-mod=mod CGO_ENABLED=0 \
        "$GO_BIN" build -trimpath -ldflags "-s -w" \
        -o "$BIN" .) ||
        fail "La compilación falló. Revisa el error de arriba (puede ser falta de internet para los módulos Go)."
    limpiar_go_tmp; GO_TMPDIR=""
    [ -x "$BIN" ] || fail "No quedó el binario en $BIN."
    chmod 755 "$BIN"
    info "Binario compilado: $(stat -c %s "$BIN") bytes"
else
    info "Binario ya presente en $BIN, se reutiliza (sin compilar)."
fi

# --- Contraseña (se reutiliza si ya existe) ------------------------------------
mkdir -p "$CONF_DIR"
if [[ -n "${V2SOCKS_PASSWORD:-}" ]]; then
    PASSWORD="$V2SOCKS_PASSWORD"
elif [[ -f "$CONF_DIR/password" ]]; then
    PASSWORD="$(cat "$CONF_DIR/password")"
    info "Reutilizando contraseña existente en $CONF_DIR/password"
else
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
fi
printf '%s' "$PASSWORD" > "$CONF_DIR/password"
chmod 600 "$CONF_DIR/password"

# --- Certificado TLS autofirmado (señalización HTTPS) --------------------------
if [[ ! -f "$CONF_DIR/cert.pem" ]]; then
    info "Generando certificado autofirmado (CN=v2socks, 3650 días) ..."
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$CONF_DIR/key.pem" -out "$CONF_DIR/cert.pem" \
        -subj "/CN=v2socks" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" 2>/dev/null
    chmod 600 "$CONF_DIR/key.pem"
else
    info "Certificado existente en $CONF_DIR, se reutiliza."
fi

# --- Servicio systemd -----------------------------------------------------------
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=v2socks server (MUSTAFA, WebRTC data channel -> TCP)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN --password-file $CONF_DIR/password --signal-addr :$SIGNAL_PORT --udp-port $UDP_PORT --cert $CONF_DIR/cert.pem --key $CONF_DIR/key.pem --allow 127.0.0.1:* --allow ::1:*
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
info "V2SOCKS instalado y corriendo."
info "  Señalización :$SIGNAL_PORT (HTTPS) + WebRTC UDP :$UDP_PORT"
info "  Servicio: $SERVICE.service"
info "  Enlace para pegar en la app (modo V2SOCKS):"
info "    v2socks://$PASSWORD@${IP:-<IP>}:$SIGNAL_PORT?udp-port=$UDP_PORT&insecure=1"
info "  La contraseña también está en $CONF_DIR/password"
info "  Nota: el VPS necesita IP pública (sin STUN/TURN)."
info "  Logs: journalctl -u $SERVICE -f"
