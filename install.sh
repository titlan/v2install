#!/usr/bin/env bash
# =============================================================================
#  MUSTAFA — Instalador v1.0 (titlan/v2install)
#  Instala la base: dependencias, Xray-core, Nginx (proxy WebSocket),
#  OpenSSH, mustafa-ws (proxy WebSocket -> SSH, puerto 444) y el menú MUSTAFA.
#
#  Menú (comando `mustafa`):
#    [01] MENU SSH             — administrar usuarios SSH
#    [02] MENU V2RAY           — cuentas UUID de Xray + enlaces
#    [03] INSTALAR PROTOCOLOS  — BadVPN, Stunnel4, HCR, CHTTP,
#                                V2SOCKS, mustafa-ws, CheckUser, Monitor App
#    [04] GENERADOR DE KEY     — generar/revocar keys de instalación
#
#  Instalación con KEY: pide una KEY generada con el menú [04] y la valida
#  contra el registro de hashes (keys.sha256 en titlan/v2install).
#  También acepta MUSTAFA_KEY=<key> como variable de entorno.
#
#  Uso:
#      bash install.sh [dominio]
#      bash install.sh mustafaejemplo.com
#
#  - El dominio es opcional. Sin dominio la instalación igual se completa
#    (VLESS + Reality funciona sin dominio).
#  - Con dominio se emite un certificado TLS con acme.sh (webroot) y se
#    guarda en /etc/mustafa/ssl/ (mustafa-ws lo usa para WSS).
#  - Log de la instalación: /var/log/mustafa-install.log
#  - Estado: /etc/mustafa/ (instaladores de protocolos en /etc/mustafa/install/)
# =============================================================================

set -euo pipefail

VERSION="1.0"
STATE_DIR="/etc/mustafa"
LOG_FILE="/var/log/mustafa-install.log"
XRAY_DIR="/usr/local/bin/xray"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_CONF="$XRAY_CONF_DIR/config.json"
NGINX_SITE="/etc/nginx/sites-available/mustafa"
DOMAIN="${1:-}"

# --- Log: todo lo que se imprime también queda en el archivo de log --------
exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "[$(date '+%H:%M:%S')] $*"; }
ok()    { echo -e "[$(date '+%H:%M:%S')] [OK] $*"; }
warn()  { echo -e "[$(date '+%H:%M:%S')] [AVISO] $*" >&2; }
die()   { echo -e "[$(date '+%H:%M:%S')] [ERROR] $*" >&2; exit 1; }

trap 'die "La instalación falló en la línea $LINENO. Revisa $LOG_FILE"' ERR

# =============================================================================
#  1. Comprobaciones previas
# =============================================================================
[[ $EUID -eq 0 ]] || die "Ejecuta el instalador como root (sudo bash install.sh)"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_NAME="${NAME:-Ubuntu} ${VERSION_ID:-?}"
else
    OS_NAME="desconocido"
fi

case "${ID:-} ${VERSION_ID:-}" in
    "ubuntu 22.04"|"ubuntu 24.04") ok "Sistema: $OS_NAME (soportado)" ;;
    *) warn "Sistema: $OS_NAME — el instalador está probado en Ubuntu 22.04/24.04. Continúo de todos modos." ;;
esac

# --- Dominio: argumento, o pregunta interactiva ------------------------------
if [[ -z "$DOMAIN" ]]; then
    echo
    echo "Dominio para el panel (opcional, Enter para omitir)."
    echo "Sin dominio se instala VLESS + Reality, que no lo necesita."
    read -rp "Dominio: " DOMAIN || true
fi
DOMAIN="$(echo "$DOMAIN" | tr -d '[:space:]')"
if [[ -n "$DOMAIN" ]]; then
    ok "Dominio: $DOMAIN"
else
    log "Sin dominio — modo Reality (sin certificado TLS)."
fi

mkdir -p "$STATE_DIR"
echo "$VERSION" > "$STATE_DIR/version"
echo "${DOMAIN:-sin-dominio}" > "$STATE_DIR/domain"
date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/installed"

echo
echo "============================== MUSTAFA $VERSION =============================="
echo "  Instalando base: deps, Xray, Nginx, SSH, mustafa-ws, menú"
echo "  Log: $LOG_FILE"
echo "=============================================================================="
echo

# =============================================================================
#  2. Dependencias
# =============================================================================
log "Actualizando paquetes e instalando dependencias..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl wget unzip nginx socat jq openssl \
    openssh-server ca-certificates gnupg procps iproute2
ok "Dependencias instaladas."

# =============================================================================
#  2.5 Validación de KEY de instalación
# =============================================================================
# La KEY se genera con el menú MUSTAFA [04] GENERADOR DE KEY. Aquí solo se
# valida su SHA-256 contra el registro publicado (keys.sha256 en el repo);
# la KEY en claro nunca se escribe en el log (read -s) ni se guarda.
# Primero se descarga el registro: si todavía no hay ninguna key publicada,
# la instalación continúa sin verificar (modo prueba) y NO se exige KEY.
KEYS_URL="${MUSTAFA_KEYS_URL:-https://raw.githubusercontent.com/titlan/v2install/main/keys.sha256}"
INSTALL_KEY="${MUSTAFA_KEY:-}"
KEYS_TMP="$(mktemp)"
if curl -fsSL -m 15 "$KEYS_URL" -o "$KEYS_TMP" 2>/dev/null \
    && grep -v '^#' "$KEYS_TMP" | grep -q .; then
    # Registro con keys publicadas: la KEY es obligatoria.
    if [[ -z "$INSTALL_KEY" ]]; then
        if [[ -t 0 ]]; then
            echo
            echo "  Instalación con KEY (generada en el menú MUSTAFA [04])."
            read -rsp "  KEY de instalación: " INSTALL_KEY || true
            echo
        else
            rm -f "$KEYS_TMP"
            die "Falta la KEY de instalación. Pásala con MUSTAFA_KEY=<key> bash install.sh"
        fi
    fi
    [[ "$INSTALL_KEY" =~ ^MUSTAFA-[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$ ]] \
        || die "Formato de KEY no válido (debe ser MUSTAFA-XXXX-XXXX-XXXX-XXXX)."
    KEY_HASH="$(printf '%s' "$INSTALL_KEY" | sha256sum | awk '{print $1}')"
    unset INSTALL_KEY
    if grep -qx "$KEY_HASH" "$KEYS_TMP"; then
        ok "KEY válida."
    else
        rm -f "$KEYS_TMP"
        die "KEY no válida o revocada. Pide una KEY nueva a quien te la dio."
    fi
    printf '%s\n' "$KEY_HASH" > "$STATE_DIR/installed-key"
    chmod 600 "$STATE_DIR/installed-key"
else
    warn "Sin registro de keys publicado ($KEYS_URL) — instalación sin verificación (modo prueba)."
    warn "En cuanto se publique la primera key, la KEY pasará a ser obligatoria."
    unset INSTALL_KEY
fi
rm -f "$KEYS_TMP"

# =============================================================================
#  3. Xray-core (última versión oficial de GitHub)
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

# --- Claves Reality + UUID del usuario base ----------------------------------
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

cat > "$STATE_DIR/info" <<EOF
version=$VERSION
domain=${DOMAIN:-sin-dominio}
xray_tag=$XRAY_TAG
xray_uuid=$USER_UUID
reality_public=$REALITY_PUB
reality_shortid=$SHORT_ID
EOF
chmod 600 "$STATE_DIR/info"
ok "Claves Reality generadas (pública guardada en $STATE_DIR/info)."

# --- Configuración base de Xray ----------------------------------------------
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
systemctl enable --now xray.service
sleep 2
systemctl is-active --quiet xray.service || die "Xray no arrancó. Revisa: journalctl -u xray -n 50"
ok "Xray activo (VLESS Reality :443, VMess WS :10086, VLESS WS :10087, VLESS XHTTP :10088)."

# =============================================================================
#  4. Nginx — proxy WebSocket + reto ACME + página base
# =============================================================================
log "Configurando Nginx..."
mkdir -p /var/www/html
cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html>
<html lang="es"><head><meta charset="utf-8"><title>MUSTAFA</title></head>
<body style="background:#0a0e27;color:#00ff88;font-family:monospace;text-align:center;padding-top:20vh">
<h1>MUSTAFA</h1><p>Servidor activo.</p>
</body></html>
EOF

cat > "$NGINX_SITE" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/html;
    index index.html;

    # Reto HTTP-01 de Let's Encrypt (acme.sh)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # WebSocket -> Xray (VMess)
    location /vmess {
        proxy_pass http://127.0.0.1:10086;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # WebSocket -> Xray (VLESS)
    location /vless {
        proxy_pass http://127.0.0.1:10087;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # XHTTP -> Xray (VLESS)
    location /xhttp {
        proxy_pass http://127.0.0.1:10088;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # checkUser (MUSTAFA) -> 127.0.0.1:8888 (tarjetas Online/Vence de la app)
    location /checkUser {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /server/online {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/mustafa
nginx -t || die "La configuración de Nginx tiene errores."
systemctl enable --now nginx
systemctl reload nginx
systemctl is-active --quiet nginx || die "Nginx no arrancó."
ok "Nginx activo (proxy WS/XHTTP en :80, rutas /vmess, /vless y /xhttp)."

# =============================================================================
#  5. OpenSSH (puerto 22)
# =============================================================================
log "Comprobando OpenSSH..."
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd
systemctl is-active --quiet ssh || systemctl is-active --quiet sshd \
    || warn "sshd no aparece activo; revísalo con: systemctl status ssh"
ok "SSH en el puerto 22."

# =============================================================================
#  6. mustafa-ws — proxy WebSocket -> SSH (puerto 444, protocolo SSH/WS)
# =============================================================================
# Binario precompilado en dist/ (amd64/arm64, estático). Si no hay binario
# para esta arquitectura, se compila desde install/ws-src/ con Go (se instala
# Go 1.27.4 si hace falta). Si nada funciona, se avisa y la instalación CONTINÚA.
log "Instalando mustafa-ws (SSH/WS en el puerto 444)..."
WS_SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
WS_ARCH="$(uname -m)"
WS_BIN=""
case "$WS_ARCH" in
    x86_64)  WS_BIN="mustafa-ws-linux-amd64" ;;
    aarch64) WS_BIN="mustafa-ws-linux-arm64" ;;
    *) warn "Arquitectura $WS_ARCH sin binario de mustafa-ws; SSH/WS queda pendiente." ;;
esac

WS_OK=0
WS_TOKEN=""
if [[ -n "$WS_BIN" && -f "$WS_SRC_DIR/dist/$WS_BIN" ]]; then
    if install -m 755 "$WS_SRC_DIR/dist/$WS_BIN" /usr/local/bin/mustafa-ws; then
        ok "mustafa-ws instalado desde dist/$WS_BIN"
        WS_OK=1
    else
        warn "No se pudo instalar el binario dist/$WS_BIN; SSH/WS queda pendiente."
    fi
elif [[ -f "$WS_SRC_DIR/install/ws-src/main.go" ]]; then
    log "Sin binario precompilado para $WS_ARCH; compilando mustafa-ws desde install/ws-src/..."
    GO_TAR="go1.27.4.linux-amd64.tar.gz"
    [[ "$WS_ARCH" == "aarch64" ]] && GO_TAR="go1.27.4.linux-arm64.tar.gz"
    if ! command -v go >/dev/null 2>&1; then
        log "Go no encontrado, descargando Go 1.27.4..."
        if curl -fsSL -o "/tmp/$GO_TAR" "https://go.dev/dl/$GO_TAR"; then
            rm -rf /tmp/go /usr/local/go
            if tar -C /usr/local -xzf "/tmp/$GO_TAR"; then
                export PATH="/usr/local/go/bin:$PATH"
            else
                warn "No se pudo descomprimir Go; SSH/WS queda pendiente."
            fi
        else
            warn "No se pudo descargar Go; SSH/WS queda pendiente."
        fi
    fi
    if command -v go >/dev/null 2>&1; then
        if (cd "$WS_SRC_DIR/install/ws-src" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o /tmp/mustafa-ws .) \
            && install -m 755 /tmp/mustafa-ws /usr/local/bin/mustafa-ws; then
            ok "mustafa-ws compilado desde install/ws-src/ e instalado"
            WS_OK=1
        else
            warn "Falló la compilación de mustafa-ws; SSH/WS queda pendiente."
        fi
        rm -f /tmp/mustafa-ws
    fi
fi

if [[ "$WS_OK" -eq 1 ]]; then
    mkdir -p /etc/mustafa-ws
    if [[ ! -f /etc/mustafa-ws/config ]]; then
        cp "$WS_SRC_DIR/install/ws-src/config.example" /etc/mustafa-ws/config
        WS_TOKEN="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
        sed -i "s/^TOKEN=.*/TOKEN=$WS_TOKEN/" /etc/mustafa-ws/config
        chmod 600 /etc/mustafa-ws/config
        ok "Config de mustafa-ws creada (TOKEN generado)."
    else
        WS_TOKEN="$(grep '^TOKEN=' /etc/mustafa-ws/config 2>/dev/null | cut -d= -f2 || true)"
        log "Config de mustafa-ws ya existía; se conserva (mismo TOKEN)."
    fi
    # WSS si ya existe un certificado (reinstalación con dominio). En una
    # instalación nueva el cert se emite en la sección 7 y ahí se activa
    # WSS para mustafa-ws (ver el gancho tras --install-cert).
    if [[ -f /etc/mustafa/ssl/fullchain.pem && -f /etc/mustafa/ssl/privkey.pem ]]; then
        sed -i "s|^TLS_CERT=.*|TLS_CERT=/etc/mustafa/ssl/fullchain.pem|" /etc/mustafa-ws/config
        sed -i "s|^TLS_KEY=.*|TLS_KEY=/etc/mustafa/ssl/privkey.pem|" /etc/mustafa-ws/config
        ok "mustafa-ws con WSS (certificado /etc/mustafa/ssl/)."
    else
        log "mustafa-ws sin certificado: sirve WS plano (sin TLS)."
    fi
    touch /var/log/mustafa-ws.log
    chmod 644 /var/log/mustafa-ws.log
    if cp "$WS_SRC_DIR/install/ws-src/mustafa-ws.service" /etc/systemd/system/mustafa-ws.service; then
        systemctl daemon-reload || warn "systemctl daemon-reload falló."
        systemctl enable mustafa-ws.service || warn "No se pudo habilitar mustafa-ws."
        systemctl restart mustafa-ws.service || warn "mustafa-ws no arrancó. Revisa: journalctl -u mustafa-ws -n 50"
        sleep 1
        if systemctl is-active --quiet mustafa-ws.service; then
            ok "mustafa-ws activo (:444 -> 127.0.0.1:22)."
        else
            warn "mustafa-ws no aparece activo. Revisa: journalctl -u mustafa-ws -n 50"
        fi
    else
        warn "No se pudo instalar mustafa-ws.service; SSH/WS queda pendiente."
    fi
    WS_LISTEN="$(grep '^LISTEN=' /etc/mustafa-ws/config 2>/dev/null | cut -d= -f2 || true)"
    {
        echo "ws_listen=${WS_LISTEN:-0.0.0.0:444}"
        echo "ws_token=${WS_TOKEN:-}"
    } >> "$STATE_DIR/info"
    chmod 600 "$STATE_DIR/info"
else
    warn "SSH/WS quedó pendiente (mustafa-ws no se pudo instalar)."
fi

# =============================================================================
#  7. Certificado TLS (solo si hay dominio)
# =============================================================================
if [[ -n "$DOMAIN" ]]; then
    log "Emitiendo certificado TLS para $DOMAIN con acme.sh..."
    mkdir -p /etc/mustafa/ssl
    if [[ ! -x "$HOME/.acme.sh/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email=admin@"$DOMAIN" >/dev/null 2>&1 \
            || warn "No se pudo instalar acme.sh; el certificado queda pendiente."
    fi
    if [[ -x "$HOME/.acme.sh/acme.sh" ]]; then
        if "$HOME/.acme.sh/acme.sh" --issue -d "$DOMAIN" -w /var/www/html --force; then
            "$HOME/.acme.sh/acme.sh" --install-cert -d "$DOMAIN" \
                --key-file /etc/mustafa/ssl/privkey.pem \
                --fullchain-file /etc/mustafa/ssl/fullchain.pem \
                --reloadcmd "systemctl reload nginx; systemctl restart mustafa-ws 2>/dev/null || true"
            ok "Certificado TLS emitido y guardado en /etc/mustafa/ssl/ (renovación automática por cron de acme.sh)."
            # Si mustafa-ws ya está instalado, actívale WSS con este cert.
            if [[ -x /usr/local/bin/mustafa-ws && -f /etc/mustafa-ws/config ]]; then
                sed -i "s|^TLS_CERT=.*|TLS_CERT=/etc/mustafa/ssl/fullchain.pem|" /etc/mustafa-ws/config
                sed -i "s|^TLS_KEY=.*|TLS_KEY=/etc/mustafa/ssl/privkey.pem|" /etc/mustafa-ws/config
                systemctl restart mustafa-ws.service 2>/dev/null || true
                ok "mustafa-ws actualizado a WSS con el certificado de $DOMAIN."
            fi
        else
            warn "No se pudo emitir el certificado para $DOMAIN."
            warn "Posibles causas: el dominio no apunta a este VPS, o el puerto 80 está cerrado en el firewall del proveedor."
            warn "El certificado se puede emitir luego con: ~/.acme.sh/acme.sh --issue -d $DOMAIN -w /var/www/html"
        fi
    fi
else
    log "Sin dominio: se omite el certificado TLS (se puede emitir luego con acme.sh)."
fi

# =============================================================================
#  8. Menú MUSTAFA
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/mustafa" ]]; then
    install -m 755 "$SCRIPT_DIR/mustafa" /usr/local/bin/mustafa
    ok "Menú instalado: ejecuta 'mustafa'"
else
    warn "No se encontró el archivo 'mustafa' junto a install.sh; el menú no se instaló."
fi

# Instaladores de protocolos para el menú [03] (se copian a /etc/mustafa/install/)
if [[ -d "$SCRIPT_DIR/install" ]]; then
    mkdir -p "$STATE_DIR/install"
    cp -r "$SCRIPT_DIR/install/." "$STATE_DIR/install/"
    chmod +x "$STATE_DIR/install/"*.sh 2>/dev/null || true
    ok "Instaladores de protocolos copiados a $STATE_DIR/install/"
else
    warn "No se encontró el directorio 'install/' junto a install.sh; el menú [03] no tendrá instaladores."
fi

# =============================================================================
#  Resumen
# =============================================================================
IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================== MUSTAFA INSTALADO =============================="
echo "  Versión : $VERSION"
echo "  Sistema : $OS_NAME"
echo "  IPv4    : ${IPV4:-?}"
echo "  Dominio : ${DOMAIN:-sin dominio}"
echo "  Xray    : $XRAY_TAG — VLESS Reality :443, VMess WS :10086, VLESS WS :10087, VLESS XHTTP :10088"
echo "  Nginx   : proxy WS/XHTTP :80 (/vmess, /vless, /xhttp)"
echo "  SSH     : puerto 22"
echo "  SSH/WS  : mustafa-ws en :444 -> 127.0.0.1:22 (TOKEN: ${WS_TOKEN:-pendiente})"
echo "  UUID    : $USER_UUID"
echo "  Reality : publicKey $REALITY_PUB  shortId $SHORT_ID"
echo "  Menú    : mustafa"
echo "  Log     : $LOG_FILE"
echo "=============================================================================="
echo "  En el menú 'mustafa': [01] usuarios SSH, [02] cuentas V2Ray,"
echo "  [03] instalar protocolos, [04] generar keys de instalación."
echo
ok "Instalación completada."
