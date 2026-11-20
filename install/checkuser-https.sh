#!/usr/bin/env bash
# =============================================================================
#  checkUser por HTTPS — sidecar MUSTAFA
#  Pone checkUser detrás de TLS en el puerto 8443 (stunnel -> Nginx :80 ->
#  checkUser 127.0.0.1:8888), para que la app Mustafa VPN pueda consultar
#  /checkUser y /server/online por HTTPS. En datos móviles (Telcel) el HTTP
#  plano es interceptado y la app marca "(no disponible)"; por HTTPS no.
#
#  Es un sidecar aparte del Stunnel4 de SSH ([03] -> [2]): usa su propio
#  config (/etc/stunnel/checkuser-https.conf) y su propio servicio
#  (checkuser-https.service), así no se pisan.
#
#  Certificado: usa el de Let's Encrypt del dominio, guardado por
#  install.sh en /etc/mustafa/ssl/ (fullchain.pem + privkey.pem). Un
#  certificado autofirmado NO sirve: la app (Android) no lo confía y
#  rechazaría el HTTPS. Si no hay certificado, el script lo dice y no
#  instala nada (hay que emitirlo primero con el dominio apuntando al VPS).
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash checkuser-https.sh            # instalar
#      sudo bash checkuser-https.sh --uninstall
# =============================================================================

set -euo pipefail

CONF="/etc/stunnel/checkuser-https.conf"
SERVICE="checkuser-https"
PIDFILE="/run/checkuser-https.pid"
PORT=8443
CERT="/etc/mustafa/ssl/fullchain.pem"
KEY="/etc/mustafa/ssl/privkey.pem"
DOMAIN_FILE="/etc/mustafa/domain"

fail() { echo "[checkuser-https] Error: $*" >&2; exit 1; }
info() { echo "[checkuser-https] $*"; }
warn() { echo "[checkuser-https] [AVISO] $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash checkuser-https.sh)."

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[checkuser-https] Desinstalando CheckUser por HTTPS :$PORT..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$CONF"
    rm -rf /etc/mustafa/ports/checkuser-https
    systemctl daemon-reload 2>/dev/null || true
    echo "[checkuser-https] CheckUser por HTTPS desinstalado (servicio y config eliminados)."
    exit 0
fi

# --- Certificado (obligatorio: Let's Encrypt del dominio) -----------------------
if [[ ! -f "$CERT" || ! -f "$KEY" ]]; then
    echo "[checkuser-https] No hay certificado TLS en /etc/mustafa/ssl/ (falta fullchain.pem o privkey.pem)."
    echo "[checkuser-https] El HTTPS de checkUser necesita un dominio con certificado Let's Encrypt."
    echo "[checkuser-https] Para emitirlo, apunta un dominio a este VPS y corre:"
    echo "[checkuser-https]   ~/.acme.sh/acme.sh --issue -d TU-DOMINIO -w /var/www/html"
    echo "[checkuser-https]   ~/.acme.sh/acme.sh --install-cert -d TU-DOMINIO --key-file /etc/mustafa/ssl/privkey.pem --fullchain-file /etc/mustafa/ssl/fullchain.pem --reloadcmd \"systemctl reload nginx\""
    echo "[checkuser-https] (O reinstala con: sudo bash install.sh TU-DOMINIO)"
    echo "[checkuser-https] Sin certificado no se instala el sidecar: un certificado autofirmado no lo confía la app."
    exit 1
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -f "$CONF" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    if ss -tln 2>/dev/null | grep -q ":$PORT "; then
        info "CheckUser por HTTPS ya está activo (https://$(cat "$DOMAIN_FILE" 2>/dev/null || echo "<dominio>"):$PORT/checkUser)."
        exit 0
    fi
    info "El servicio está activo pero no escucha en :$PORT; se reconfigura..."
fi

# --- stunnel4 (si no está) ------------------------------------------------------
if ! command -v stunnel4 >/dev/null 2>&1; then
    info "Instalando stunnel4..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y stunnel4 openssl iproute2
fi
command -v stunnel4 >/dev/null 2>&1 || fail "No se pudo instalar stunnel4."

# --- Configuración -------------------------------------------------------------
mkdir -p /etc/stunnel
DOMAIN="$(cat "$DOMAIN_FILE" 2>/dev/null || echo "")"
[[ "$DOMAIN" == "sin-dominio" ]] && DOMAIN=""
info "Escribiendo $CONF (accept $PORT -> 127.0.0.1:80, cert $CERT)..."
cat > "$CONF" <<EOF
# MUSTAFA checkuser-https — gestionado por el instalador MUSTAFA
# CheckUser por HTTPS: acepta TLS en :$PORT y lo pasa a Nginx :80
# (que ya publica /checkUser y /server/online -> 127.0.0.1:8888).
# Certificado Let's Encrypt del dominio: $CERT
cert = $CERT
key = $KEY
pid = $PIDFILE

[checkuser-https]
accept = $PORT
connect = 127.0.0.1:80
EOF
chmod 644 "$CONF"

# --- Servicio systemd propio (como stunnel4.sh: Type=forking + PIDFile) --------
STUNNEL_BIN="$(command -v stunnel4)"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=checkuser-https (MUSTAFA, CheckUser por HTTPS :$PORT)
After=network.target

[Service]
Type=forking
PIDFile=$PIDFILE
ExecStart=$STUNNEL_BIN $CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE" || true
sleep 1

# --- Estado final ---------------------------------------------------------------
if ! systemctl is-active --quiet "$SERVICE"; then
    echo "  --- journal de $SERVICE ---"
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null | sed 's/^/  /' || true
    fail "El servicio $SERVICE no quedó activo. Revisa: journalctl -u $SERVICE -n 50"
fi
ss -tln 2>/dev/null | grep -q ":$PORT " ||
    fail "El servicio está activo pero no escucha en el puerto $PORT. Revisa: journalctl -u $SERVICE -n 50"
mkdir -p /etc/mustafa/ports
echo "$PORT" > /etc/mustafa/ports/checkuser-https

# --- Renovación del certificado: que acme.sh también reinicie el sidecar -------
# Si no, al renovarse el cert el sidecar seguiría sirviendo el viejo hasta
# que caduque. Se actualiza el reloadcmd de acme.sh (best-effort).
if [[ -n "$DOMAIN" && -x "$HOME/.acme.sh/acme.sh" ]]; then
    if "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
            --key-file "$KEY" \
            --fullchain-file "$CERT" \
            --reloadcmd "systemctl reload nginx; systemctl restart mustafa-ws 2>/dev/null || true; systemctl restart $SERVICE 2>/dev/null || true" \
            >/dev/null 2>&1; then
        info "Renovación de acme.sh actualizada: al renovar el cert también reinicia $SERVICE."
    else
        warn "No se pudo actualizar el reloadcmd de acme.sh; al renovar el certificado reinicia el sidecar a mano: systemctl restart $SERVICE"
    fi
fi

echo
info "CheckUser por HTTPS activo."
info "  Escucha : 0.0.0.0:$PORT (TLS, stunnel -> Nginx :80 -> checkUser 127.0.0.1:8888)"
if [[ -n "$DOMAIN" ]]; then
    info "  Público : https://$DOMAIN:$PORT/checkUser y /server/online"
    info "  Prueba  : curl -sk https://$DOMAIN:$PORT/server/online"
else
    info "  Público : https://<IP-del-VPS>:$PORT/checkUser (ojo: el cert es del dominio, no de la IP; la app debe usar el dominio)"
fi
info "  Servicio: $SERVICE.service"
info "  Logs    : journalctl -u $SERVICE -f"
