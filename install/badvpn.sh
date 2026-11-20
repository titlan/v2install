#!/usr/bin/env bash
# =============================================================================
#  MUSTAFA — Instalador de BadVPN (udpgw)
#  Compila badvpn-udpgw desde la fuente oficial (ambrop72/badvpn) y lo deja
#  como servicio systemd badvpn.service escuchando en 127.0.0.1:7300.
#
#  BadVPN-udpgw es la pasarela UDP que usan las apps tipo HTTP Custom /
#  HTTP Injector para llevar tráfico UDP (DNS, voz, juegos) por el túnel SSH.
#
#  Uso:
#      sudo bash install/badvpn.sh
#
#  - Fuente: https://github.com/ambrop72/badvpn (tag 1.999.130, BSD-3-Clause).
#    El proyecto oficial NO publica binarios precompilados: se descarga el
#    tarball del tag, se verifica su SHA-256 y se compila SOLO el
#    componente udpgw con cmake (-DBUILD_NOTHING_BY_DEFAULT=1
#    -DBUILD_UDPGW=1). Compilar desde fuente funciona igual en amd64 y arm64.
#  - Puerto: 127.0.0.1:7300 (el estándar en paneles VPN).
#  - Idempotente: si ya está instalado y activo, lo dice y sale sin tocar nada.
#  - Log: /var/log/mustafa-install.log (mismo que install.sh).
# =============================================================================

set -euo pipefail

BADVPN_VERSION="1.999.130"
BADVPN_URL="https://github.com/ambrop72/badvpn/archive/${BADVPN_VERSION}.tar.gz"
BADVPN_SHA256="bfd4bbfebd7274bcec792558c9a2fd60e39cd92e04673825ade5d04154766109"
BADVPN_BIN="/usr/local/bin/badvpn-udpgw"
LISTEN_ADDR="127.0.0.1:7300"
BUILD_DIR="/tmp/badvpn-build"
LOG_FILE="/var/log/mustafa-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()    { echo -e "[$(date '+%H:%M:%S')] [OK] $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] [AVISO] $*" >&2; }
die()   { echo -e "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

trap 'die "La instalación de BadVPN falló en la línea $LINENO. Revisa $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die "Ejecuta este script como root (sudo bash install/badvpn.sh)"

# --- Arquitectura ------------------------------------------------------------
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH_LABEL="amd64 (x86_64)" ;;
    aarch64) ARCH_LABEL="arm64 (aarch64)" ;;
    *)       ARCH_LABEL="$ARCH (se compila desde fuente, sin binario específico)" ;;
esac
log "BadVPN (udpgw) — arquitectura: $ARCH_LABEL"

# --- Puerto --------------------------------------------------------------------
# BADVPN_PORT lo fija quien llama (el menú). Sin él se mantiene el puerto
# actual (si ya está instalado) o 7300.
PORT_REQ="${BADVPN_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/badvpn ]] && p="$(cat /etc/mustafa/ports/badvpn 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep -o -- '--listen-addr 127.0.0.1:[0-9]*' /etc/systemd/system/badvpn.service 2>/dev/null | grep -o '[0-9]*$' || true)"
    fi
    [[ -z "$p" ]] && p="7300"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) die "BADVPN_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "BADVPN_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi
LISTEN_ADDR="127.0.0.1:$PORT"

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Desinstalando BadVPN..."
    systemctl stop badvpn 2>/dev/null || true
    systemctl disable badvpn 2>/dev/null || true
    rm -f /etc/systemd/system/badvpn.service "$BADVPN_BIN"
    rm -rf /etc/mustafa/ports/badvpn
    systemctl daemon-reload 2>/dev/null || true
    ok "BadVPN desinstalado (servicio y binario eliminados)."
    exit 0
fi

# --- Idempotencia: ya instalado y activo --------------------------------------
if [[ -x "$BADVPN_BIN" ]] && systemctl is-active --quiet badvpn 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        ok "BadVPN ya está instalado y activo (udpgw en $LISTEN_ADDR)."
        ss -ulnp 2>/dev/null | grep -E ":$PORT" || true
        exit 0
    fi
    log "Cambiando puerto BadVPN de $(port_actual) a $PORT_REQ ..."
fi

# --- Dependencias de compilación ---------------------------------------------
log "Instalando dependencias de compilación (build-essential, cmake, curl)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y build-essential cmake curl iproute2

# --- Descarga + verificación + compilación ------------------------------------
if [[ -x "$BADVPN_BIN" ]]; then
    ok "badvpn-udpgw ya existe en $BADVPN_BIN — no se vuelve a compilar."
else
    log "Descargando fuente oficial: $BADVPN_URL"
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"
    curl -fsSL -o "badvpn-${BADVPN_VERSION}.tar.gz" "$BADVPN_URL"
    echo "${BADVPN_SHA256}  badvpn-${BADVPN_VERSION}.tar.gz" | sha256sum -c -
    ok "SHA-256 del tarball verificado."
    tar xzf "badvpn-${BADVPN_VERSION}.tar.gz"
    cd "badvpn-${BADVPN_VERSION}"
    log "Compilando solo udpgw (cmake + make)..."
    cmake -S . -B build -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1
    cmake --build build -j"$(nproc)"
    install -m 755 build/udpgw/badvpn-udpgw "$BADVPN_BIN"
    ok "badvpn-udpgw instalado en $BADVPN_BIN"
    cd /
    rm -rf "$BUILD_DIR"
fi

# --- Servicio systemd ----------------------------------------------------------
log "Creando servicio systemd badvpn.service ($LISTEN_ADDR)..."
cat > /etc/systemd/system/badvpn.service <<EOF
[Unit]
Description=BadVPN UDP Gateway (udpgw)
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr $LISTEN_ADDR --max-clients 1000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# enable --now solo no reinicia un servicio que ya corre: un cambio
# de puerto exige reiniciar para que tome la nueva config.
systemctl enable badvpn
systemctl restart badvpn || true

# --- Estado final ---------------------------------------------------------------
systemctl is-active --quiet badvpn || die "El servicio badvpn no quedó activo. Revisa: journalctl -u badvpn -n 50"
ss -uln 2>/dev/null | grep -q ":$PORT " ||
    die "El servicio está activo pero no escucha en el puerto UDP $PORT. Revisa: journalctl -u badvpn -n 50"
mkdir -p /etc/mustafa/ports
echo "$PORT" > /etc/mustafa/ports/badvpn
ok "BadVPN activo."
echo
echo "  BadVPN (udpgw) : $LISTEN_ADDR"
echo "  Binario        : $BADVPN_BIN"
echo "  Servicio       : badvpn.service"
ss -ulnp 2>/dev/null | grep -E ":$PORT" || true
echo
echo "  Las apps (HTTP Custom / HTTP Injector) usan $LISTEN_ADDR como"
echo "  pasarela UDP dentro del túnel SSH."
