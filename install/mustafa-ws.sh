#!/usr/bin/env bash
# =============================================================================
#  mustafa-ws — instalador MUSTAFA
#  Instala el proxy WebSocket -> SSH de MUSTAFA (RFC 6455 + HTTP CONNECT,
#  con TOKEN, WSS opcional, límites por IP y log por conexión) como servicio
#  systemd. Escucha en :444 y tuneliza a SSH 127.0.0.1:22.
#
#  EL CÓDIGO: se compila desde la fuente que viene junto a este script, en
#  el directorio "ws-src" (main.go + go.mod, solo librería estándar de Go,
#  sin dependencias externas). No descarga binarios ni usa GitHub.
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash mustafa-ws.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$DIR/ws-src"
BIN="/usr/local/bin/mustafa-ws"
CONF_DIR="/etc/mustafa-ws"
SERVICE="mustafa-ws"

# Go 1.27.4 oficial (go.dev/dl) — SHA-256 verificado en go.dev/dl/?mode=json.
GO_VERSION="go1.27.4"
GO_SHA256_AMD64="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"
GO_SHA256_ARM64="3392582988a273a87ab5043ee1b2c9c17a2c3c00580bf9326c47a2e0aaaeac92"

GO_TMPDIR=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[mustafa-ws] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash mustafa-ws.sh)."

# --- Puerto --------------------------------------------------------------------
# WS_PORT lo fija quien llama (el menú). Sin él se mantiene el puerto
# actual (si ya está instalado) o 444.
PORT_REQ="${WS_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/mustafa-ws ]] && p="$(cat /etc/mustafa/ports/mustafa-ws 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep '^LISTEN=' /etc/mustafa-ws/config 2>/dev/null | cut -d: -f2- || true)"
    fi
    [[ -z "$p" ]] && p="444"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) fail "WS_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "WS_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[mustafa-ws] Desinstalando mustafa-ws..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$BIN"
    rm -rf "$CONF_DIR" /etc/mustafa/ports/mustafa-ws /var/log/mustafa-ws.log
    systemctl daemon-reload 2>/dev/null || true
    echo "[mustafa-ws] mustafa-ws desinstalado (servicio, binario y /etc/mustafa-ws eliminados)."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        info "mustafa-ws ya está instalado y activo."
        if [[ -f "$CONF_DIR/config" ]]; then
            info "  Escucha : $(grep '^LISTEN=' "$CONF_DIR/config" | cut -d= -f2) -> $(grep '^TARGET=' "$CONF_DIR/config" | cut -d= -f2)"
            info "  TOKEN   : $(grep '^TOKEN=' "$CONF_DIR/config" | cut -d= -f2)"
        fi
        systemctl --no-pager status "$SERVICE" --lines=5 || true
        exit 0
    fi
    info "Cambiando puerto mustafa-ws de $(port_actual) a $PORT_REQ ..."
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
    GO_TMPDIR="$(mktemp -d /tmp/mustafa-ws-go.XXXXXX)"
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
        [ -f "$f" ] || fail "Falta el código fuente: $f (el directorio ws-src debe estar junto a mustafa-ws.sh)."
    done
    GO_BIN=""
    obtener_go || exit 1
    info "Compilando mustafa-ws desde $SRC_DIR ..."
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

# --- Configuración (TOKEN aleatorio solo en la primera instalación) ------------
mkdir -p "$CONF_DIR"
if [[ ! -f "$CONF_DIR/config" ]]; then
    [ -f "$SRC_DIR/config.example" ] ||
        fail "Falta $SRC_DIR/config.example (debe estar junto a mustafa-ws.sh)."
    cp "$SRC_DIR/config.example" "$CONF_DIR/config"
    TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    sed -i "s/^TOKEN=.*/TOKEN=$TOKEN/" "$CONF_DIR/config"
    chmod 600 "$CONF_DIR/config"
    info "Config creada en $CONF_DIR/config"
    info "TOKEN generado: $TOKEN  (guárdalo, es el que usan los clientes)"
else
    info "Config existente en $CONF_DIR/config, no se toca."
    TOKEN="$(grep '^TOKEN=' "$CONF_DIR/config" | cut -d= -f2)"
fi

# Puerto: se aplica el pedido (WS_PORT) o se mantiene el actual.
# El TOKEN no se toca nunca en un cambio de puerto.
sed -i "s/^LISTEN=.*/LISTEN=0.0.0.0:$PORT/" "$CONF_DIR/config"

touch /var/log/mustafa-ws.log
chmod 644 /var/log/mustafa-ws.log

# --- Servicio systemd -----------------------------------------------------------
[ -f "$SRC_DIR/mustafa-ws.service" ] ||
    fail "Falta $SRC_DIR/mustafa-ws.service (debe estar junto a mustafa-ws.sh)."
cp "$SRC_DIR/mustafa-ws.service" "/etc/systemd/system/$SERVICE.service"
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
echo "$PORT" > /etc/mustafa/ports/mustafa-ws

echo
info "mustafa-ws instalado y corriendo."
info "  Escucha : $(grep '^LISTEN=' "$CONF_DIR/config" | cut -d= -f2) -> $(grep '^TARGET=' "$CONF_DIR/config" | cut -d= -f2)"
info "  TOKEN   : $TOKEN"
info "  Uso en HTTP Custom: SSH + WebSocket, puerto $PORT, payload GET /$TOKEN"
info "  Logs    : journalctl -u $SERVICE -f  y  /var/log/mustafa-ws.log"
