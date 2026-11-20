#!/usr/bin/env bash
# =============================================================================
#  MUSTAFA — Instalador de Stunnel4 (SSH sobre TLS)
#  Instala stunnel4 y lo configura para aceptar conexiones TLS y pasarlas
#  a SSH local (127.0.0.1:22), con certificado autofirmado.
#
#  Uso:
#      sudo bash install/stunnel4.sh
#
#  - Puerto: 443 si está libre; 4443 si el 443 ya está ocupado. En este
#    instalador Xray ocupa el 443 (VLESS + Reality), así que en una VPS
#    MUSTAFA normal Stunnel4 queda en 4443. El script detecta el puerto
#    con ss y avisa claramente cuál usa y por qué.
#  - Certificado: /etc/stunnel/stunnel.pem (autofirmado, RSA 2048,
#    3650 días). Si ya existe, se reutiliza (no se regenera).
#  - Idempotente: si ya está instalado y activo, lo dice y sale sin tocar nada.
#  - Log: /var/log/mustafa-install.log (mismo que install.sh).
# =============================================================================

set -euo pipefail

STUNNEL_CONF="/etc/stunnel/stunnel.conf"
STUNNEL_PEM="/etc/stunnel/stunnel.pem"
MARKER="# MUSTAFA stunnel4"
LOG_FILE="/var/log/mustafa-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()    { echo -e "[$(date '+%H:%M:%S')] [OK] $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] [AVISO] $*" >&2; }
die()   { echo -e "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

trap 'die "La instalación de Stunnel4 falló en la línea $LINENO. Revisa $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die "Ejecuta este script como root (sudo bash install/stunnel4.sh)"

# --- Idempotencia: ya instalado y activo --------------------------------------
if grep -q "$MARKER" "$STUNNEL_CONF" 2>/dev/null && systemctl is-active --quiet stunnel4 2>/dev/null; then
    PORT_ACTUAL="$(awk -F'=' '/^accept[[:space:]]*=/{gsub(/ /,"",$2); print $2; exit}' "$STUNNEL_CONF")"
    ok "Stunnel4 ya está instalado y activo (SSH sobre TLS en el puerto ${PORT_ACTUAL:-?})."
    ss -tlnp 2>/dev/null | grep -E "stunnel|:${PORT_ACTUAL:-0} " || true
    exit 0
fi

# --- Paquetes ------------------------------------------------------------------
log "Instalando stunnel4 y openssl..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y stunnel4 openssl iproute2

# --- Puerto: reutilizar el de una instalación previa, o detectar --------------
if grep -q "$MARKER" "$STUNNEL_CONF" 2>/dev/null; then
    STUNNEL_PORT="$(awk -F'=' '/^accept[[:space:]]*=/{gsub(/ /,"",$2); print $2; exit}' "$STUNNEL_CONF")"
    PORT_NOTE="se mantiene el puerto de la instalación anterior ($STUNNEL_PORT)"
elif ss -tln 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit !found}'; then
    STUNNEL_PORT=4443
    PORT_NOTE="el puerto 443 ya está ocupado (normalmente Xray — VLESS Reality), por eso Stunnel4 usa 4443"
else
    STUNNEL_PORT=443
    PORT_NOTE="el puerto 443 está libre"
fi
log "Puerto Stunnel4: $STUNNEL_PORT ($PORT_NOTE)"

# --- Certificado autofirmado (reutilizar si ya existe) -------------------------
mkdir -p /etc/stunnel
if [[ -f "$STUNNEL_PEM" ]]; then
    ok "Certificado existente reutilizado: $STUNNEL_PEM"
else
    CN="$(hostname -f 2>/dev/null || hostname)"
    log "Creando certificado autofirmado (3650 días, CN=$CN)..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "$STUNNEL_PEM" -out "$STUNNEL_PEM" \
        -subj "/CN=${CN}/O=MUSTAFA"
    chmod 600 "$STUNNEL_PEM"
    ok "Certificado creado: $STUNNEL_PEM"
fi

# --- Configuración -------------------------------------------------------------
if [[ -f "$STUNNEL_CONF" ]] && ! grep -q "$MARKER" "$STUNNEL_CONF"; then
    cp "$STUNNEL_CONF" "${STUNNEL_CONF}.bak"
    warn "Configuración previa de Stunnel guardada en ${STUNNEL_CONF}.bak"
fi

log "Escribiendo $STUNNEL_CONF ([ssh] accept $STUNNEL_PORT -> 127.0.0.1:22)..."
cat > "$STUNNEL_CONF" <<EOF
$MARKER — gestionado por el instalador MUSTAFA
# SSH sobre TLS: acepta conexiones TLS en el puerto $STUNNEL_PORT y las pasa
# a SSH local (127.0.0.1:22). $PORT_NOTE.
cert = $STUNNEL_PEM
pid = /run/stunnel.pid

[ssh]
accept = $STUNNEL_PORT
connect = 127.0.0.1:22
EOF
chmod 644 "$STUNNEL_CONF"

# --- Habilitar y arrancar --------------------------------------------------------
# El paquete Debian/Ubuntu trae ENABLED=0 en /etc/default/stunnel4; sin
# ponerlo en 1 el servicio no arranca con el script init clásico.
if [[ -f /etc/default/stunnel4 ]]; then
    if grep -q '^ENABLED=' /etc/default/stunnel4; then
        sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
    else
        echo 'ENABLED=1' >> /etc/default/stunnel4
    fi
fi

systemctl daemon-reload
systemctl enable --now stunnel4

# --- Estado final ---------------------------------------------------------------
systemctl is-active --quiet stunnel4 || die "El servicio stunnel4 no quedó activo. Revisa: journalctl -u stunnel4 -n 50"
ok "Stunnel4 activo."
echo
echo "  Stunnel4 (SSH sobre TLS) : puerto $STUNNEL_PORT -> 127.0.0.1:22"
echo "  Certificado                : $STUNNEL_PEM (autofirmado)"
echo "  Servicio                   : stunnel4.service"
if [[ "$STUNNEL_PORT" == "4443" ]]; then
    echo "  [AVISO] El puerto 443 lo usa Xray (VLESS Reality); por eso SSH"
    echo "          sobre TLS quedó en 4443. Las apps deben apuntar a :4443."
fi
ss -tlnp 2>/dev/null | grep -E "stunnel|:${STUNNEL_PORT} " || true
