#!/usr/bin/env bash
# =============================================================================
#  MUSTAFA — Instalador standalone de Xray-core (V2Ray)
#  Es la sección 3 de install.sh, como script independiente, para el menú
#  [02] MENU V2RAY -> [6] Instalar V2Ray. Instala la última versión oficial
#  de Xray-core desde GitHub (XTLS/Xray-core) con:
#    :443   VLESS + Reality (sin dominio)
#    :10086 VMess + WebSocket /vmess  (lo sirve Nginx en el :80)
#    :10087 VLESS + WebSocket /vless  (lo sirve Nginx en el :80)
#    :10088 VLESS + XHTTP /xhttp      (lo sirve Nginx en el :80)
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash install/xray.sh
#      sudo bash install/xray.sh --uninstall
#
#  - Idempotente: si Xray ya está instalado y activo, lo dice y sale.
#  - Si ya existe una config (/usr/local/etc/xray/config.json), NO se
#    toca: se reutilizan sus claves Reality y sus UUID (reinstalar no
#    debe romper los enlaces de los clientes). Solo se actualiza el
#    binario, el servicio y la versión en /etc/mustafa/info.
#  - /etc/mustafa/info: se conservan version y domain; solo se actualizan
#    xray_tag, xray_uuid, reality_public y reality_shortid.
#  - Log: /var/log/mustafa-install.log (mismo que install.sh).
# =============================================================================

set -euo pipefail

STATE_DIR="/etc/mustafa"
VERSION="${VERSION:-1.0}"
XRAY_DIR="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
LOG_FILE="/var/log/mustafa-install.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()    { echo -e "[$(date '+%H:%M:%S')] [OK] $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] [AVISO] $*" >&2; }
die()   { echo -e "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

trap 'die "La instalación de Xray falló en la línea $LINENO. Revisa $LOG_FILE"' ERR

[[ $EUID -eq 0 ]] || die "Ejecuta este script como root (sudo bash install/xray.sh)"

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Desinstalando Xray..."
    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    rm -f /etc/systemd/system/xray.service
    rm -rf "$XRAY_DIR" "$XRAY_CONF_DIR" /usr/local/share/xray /var/log/xray
    sed -i '/^xray_tag=/d; /^xray_uuid=/d; /^reality_public=/d; /^reality_shortid=/d' "$STATE_DIR/info" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    ok "Xray desinstalado (binario, config y cuentas UUID eliminados)."
    exit 0
fi

# --- Idempotencia: ya instalado y activo --------------------------------------
if [[ -x "$XRAY_DIR/xray" ]] && systemctl is-active --quiet xray 2>/dev/null; then
    ok "Xray ya está instalado y activo ($("$XRAY_DIR/xray" version 2>/dev/null | head -n 1))."
    exit 0
fi

command -v curl >/dev/null 2>&1 || die "Falta curl."
command -v jq >/dev/null 2>&1 || die "Falta jq (apt install jq)."
command -v unzip >/dev/null 2>&1 || die "Falta unzip (apt install unzip)."
command -v openssl >/dev/null 2>&1 || die "Falta openssl."

# =============================================================================
#  Xray-core (última versión oficial de GitHub)
# =============================================================================
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    armv7l)  XRAY_ARCH="arm32-v7a" ;;
    *) die "Arquitectura no soportada: $ARCH" ;;
esac

log "Buscando la última versión de Xray-core..."
XRAY_TAG="$(curl -fsSL -m 20 https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r '.tag_name // empty')"
[[ -n "$XRAY_TAG" ]] || die "No se pudo obtener la versión de Xray desde GitHub. Revisa la conexión a internet."
ok "Xray-core $XRAY_TAG"

TMPDIR_XRAY="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_XRAY"' EXIT
XRAY_ZIP="$TMPDIR_XRAY/Xray-linux-$XRAY_ARCH.zip"
log "Descargando Xray-linux-$XRAY_ARCH.zip..."
curl -fsSL -o "$XRAY_ZIP" \
    "https://github.com/XTLS/Xray-core/releases/download/$XRAY_TAG/Xray-linux-$XRAY_ARCH.zip"
unzip -o -q "$XRAY_ZIP" -d "$TMPDIR_XRAY"

mkdir -p "$XRAY_DIR" /usr/local/share/xray "$XRAY_CONF_DIR" /var/log/xray
install -m 755 "$TMPDIR_XRAY/xray" "$XRAY_DIR/xray"
install -m 644 "$TMPDIR_XRAY/geoip.dat" /usr/local/share/xray/geoip.dat
install -m 644 "$TMPDIR_XRAY/geosite.dat" /usr/local/share/xray/geosite.dat
ok "Xray instalado en $XRAY_DIR/xray"
"$XRAY_DIR/xray" version 2>/dev/null | head -n 1 || true  # head puede cerrar el pipe (SIGPIPE); no es error

# --- Config existente: reutilizar claves y UUID (no romper enlaces) -----------
KEEP_CONFIG=0
if [[ -f "$XRAY_CONF" ]] && jq empty "$XRAY_CONF" 2>/dev/null; then
    KEEP_CONFIG=1
    USER_UUID="$(jq -r '.inbounds[0].settings.clients[0].id // empty' "$XRAY_CONF" 2>/dev/null || true)"
    REALITY_PUB="$(grep '^reality_public=' "$STATE_DIR/info" 2>/dev/null | cut -d= -f2- || true)"
    SHORT_ID="$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0] // empty' "$XRAY_CONF" 2>/dev/null || true)"
    [[ -n "$USER_UUID" ]] || KEEP_CONFIG=0
    if [[ "$KEEP_CONFIG" == 1 ]]; then
        ok "Config existente reutilizada (claves Reality y UUID se mantienen)."
    fi
fi

if [[ "$KEEP_CONFIG" == 0 ]]; then
    # --- Claves Reality + UUID del usuario base ------------------------------
    # 'xray x25519' cambió de formato en las versiones nuevas (v26.x):
    #   nuevo:  PrivateKey: <clave> / Password (PublicKey): <clave> / Hash32: ...
    #   viejo:  Private key: <clave> / Public key: <clave>
    # Se aceptan los dos formatos.
    log "Generando claves Reality y UUID..."
    X25519_OUT="$("$XRAY_DIR/xray" x25519)"
    REALITY_PRIV="$(echo "$X25519_OUT" | sed -n 's/^PrivateKey: *//p; s/^Private key: *//p' | tr -d '[:space:]')"
    REALITY_PUB="$(echo "$X25519_OUT" | sed -n 's/^Password (PublicKey): *//p; s/^Public key: *//p' | tr -d '[:space:]')"
    [[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]] || die "No se pudieron generar las claves Reality (formato de 'xray x25519' no reconocido en Xray $XRAY_TAG)."
    USER_UUID="$(cat /proc/sys/kernel/random/uuid)"
    SHORT_ID="$(openssl rand -hex 4)"

    # --- Configuración base de Xray ------------------------------------------
    #  :443   VLESS + Reality (sin dominio) — el tráfico que no es Reality
    #         se reenvía al sitio real de destino (camuflaje).
    #  :10086 VMess + WebSocket (ruta /vmess) — lo sirve Nginx en el puerto 80.
    #  :10087 VLESS + WebSocket (ruta /vless) — lo sirve Nginx en el puerto 80.
    #  :10088 VLESS + XHTTP (ruta /xhttp) — lo sirve Nginx en el puerto 80.
    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "$USER_UUID", "flow": "xtls-rprx-vision" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "xver": 0,
          "serverNames": ["www.microsoft.com"],
          "privateKey": "$REALITY_PRIV",
          "shortIds": ["$SHORT_ID"]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "listen": "127.0.0.1",
      "port": 10086,
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "$USER_UUID" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vmess" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "listen": "127.0.0.1",
      "port": 10087,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$USER_UUID", "flow": "xtls-rprx-vision" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/vless" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    },
    {
      "listen": "127.0.0.1",
      "port": 10088,
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "$USER_UUID" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": { "path": "/xhttp" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls"] }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "block" }
    ]
  }
}
EOF
    ok "Claves Reality generadas (pública guardada en $STATE_DIR/info)."
fi

# --- Migrar config existente: agregar entrada XHTTP si falta ------------------
# (las instalaciones hechas antes de XHTTP no la tienen; se agrega sin tocar
#  las entradas existentes ni los UUID, y se valida antes de reiniciar)
if [[ "$KEEP_CONFIG" == 1 ]]; then
    if ! jq -e '.inbounds[] | select(.streamSettings.network == "xhttp")' "$XRAY_CONF" >/dev/null 2>&1; then
        XHTTP_CLIENTS="$(jq -c '[.inbounds[].settings.clients[]?.id] | unique | map({id:.})' "$XRAY_CONF" 2>/dev/null || true)"
        if [[ -n "$XHTTP_CLIENTS" && "$XHTTP_CLIENTS" != "[]" ]]; then
            tmp="$(mktemp)"
            if jq --argjson clients "$XHTTP_CLIENTS" \
                '.inbounds += [{"listen":"127.0.0.1","port":10088,"protocol":"vless","settings":{"clients":$clients,"decryption":"none"},"streamSettings":{"network":"xhttp","xhttpSettings":{"path":"/xhttp"}},"sniffing":{"enabled":true,"destOverride":["http","tls"]}}]' \
                "$XRAY_CONF" > "$tmp" 2>/dev/null; then
                cp "$XRAY_CONF" "$XRAY_CONF.bak"
                mv "$tmp" "$XRAY_CONF"
                if "$XRAY_DIR/xray" run -test -config "$XRAY_CONF" >/dev/null 2>&1; then
                    ok "Entrada XHTTP agregada a la config existente (:10088 /xhttp)."
                else
                    mv "$XRAY_CONF.bak" "$XRAY_CONF"
                    echo "  (la config con XHTTP no pasó la prueba; se restauró la anterior)"
                fi
            else
                rm -f "$tmp"
                echo "  (no se pudo agregar XHTTP a la config; se deja como está)"
            fi
        fi
    fi
fi

# --- /etc/mustafa/info: conservar version/domain, actualizar solo Xray --------
mkdir -p "$STATE_DIR"
touch "$STATE_DIR/info"
for k in xray_tag xray_uuid reality_public reality_shortid; do
    sed -i "/^$k=/d" "$STATE_DIR/info"
done
{
    echo "xray_tag=$XRAY_TAG"
    echo "xray_uuid=$USER_UUID"
    echo "reality_public=$REALITY_PUB"
    echo "reality_shortid=$SHORT_ID"
} >> "$STATE_DIR/info"
if ! grep -q '^version=' "$STATE_DIR/info" 2>/dev/null; then
    echo "version=$VERSION" >> "$STATE_DIR/info"
fi
if ! grep -q '^domain=' "$STATE_DIR/info" 2>/dev/null; then
    echo "domain=sin-dominio" >> "$STATE_DIR/info"
fi
chmod 600 "$STATE_DIR/info"

# --- Servicio systemd de Xray -------------------------------------------------
cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (MUSTAFA)
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$XRAY_DIR/xray run -config $XRAY_CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable xray
# restart (no --now): si xray ya corría con una config vieja, --now no lo
# reinicia y la migración de XHTTP no surtiría efecto.
systemctl restart xray
sleep 2
systemctl is-active --quiet xray || die "Xray no arrancó. Revisa: journalctl -u xray -n 50"
ok "Xray activo."

# --- Nginx: asegurar proxy /xhttp (migración de instalaciones viejas) ---------
# (install.sh ya escribe el bloque en instalaciones nuevas; aquí solo se
#  agrega si el sitio existe y no lo tiene)
NGINX_SITE="/etc/nginx/sites-available/mustafa"
if [[ -f "$NGINX_SITE" ]] && ! grep -q 'location /xhttp' "$NGINX_SITE"; then
    python3 - "$NGINX_SITE" <<'PYEOF'
import sys
site = sys.argv[1]
block = """    # XHTTP -> Xray (VLESS)
    location /xhttp {
        proxy_pass http://127.0.0.1:10088;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

"""
text = open(site).read()
marker = "    location / {"
if "location /xhttp" not in text and marker in text:
    text = text.replace(marker, block + marker, 1)
    open(site, "w").write(text)
PYEOF
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || true
        ok "Proxy Nginx /xhttp agregado."
    else
        echo "  (no se pudo agregar el proxy /xhttp a Nginx; revisa $NGINX_SITE)"
    fi
fi
echo
echo "  Xray      : $XRAY_TAG (VLESS Reality :443, VMess WS :10086, VLESS WS :10087, VLESS XHTTP :10088)"
echo "  UUID base : $USER_UUID"
echo "  Servicio  : xray.service"
echo "  Config    : $XRAY_CONF"
echo "  Usa el menú [02] para ver cuentas y enlaces."
