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

# --- Idempotencia: ya instalado y activo --------------------------------------
if [[ -x "$BADVPN_BIN" ]] && systemctl is-active --quiet badvpn 2>/dev/null; then
    ok "BadVPN ya está instalado y activo (udpgw en $LISTEN_ADDR)."
    ss -ulnp 2>/dev/null | grep -E ':7300' || true
    exit 0
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
cat > /etc/systemd/system/badvpn.service <<'EOF'
[Unit]
Description=BadVPN UDP Gateway (udpgw)
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:7300 --max-clients 1000
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now badvpn

# --- Estado final ---------------------------------------------------------------
systemctl is-active --quiet badvpn || die "El servicio badvpn no quedó activo. Revisa: journalctl -u badvpn -n 50"
ok "BadVPN activo."
echo
echo "  BadVPN (udpgw) : $LISTEN_ADDR"
echo "  Binario        : $BADVPN_BIN"
echo "  Servicio       : badvpn.service"
ss -ulnp 2>/dev/null | grep -E ':7300' || true
echo
echo "  Las apps (HTTP Custom / HTTP Injector) usan 127.0.0.1:7300 como"
echo "  pasarela UDP dentro del túnel SSH."
