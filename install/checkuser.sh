#!/usr/bin/env bash
# =============================================================================
#  checkUser — instalador MUSTAFA
#  Instala el servicio checkUser (verifica usuarios SSH y su vencimiento,
#  y cuenta usuarios conectados). Escucha en loopback 127.0.0.1:8888 y
#  Nginx lo publica en el puerto 80 (/checkUser y /server/online), para
#  las tarjetas "Usuarios Online" y "Vence" de la app Mustafa VPN.
#  NO puede ir directo en el :80: en una VPS MUSTAFA Nginx ya ocupa el
#  80 y el servicio no arrancaría (Address already in use).
#
#  Endpoints (públicos, vía Nginx :80):
#    POST http://<IP>/checkUser    {"user": "...", "token": "..."}
#    GET  http://<IP>/server/online
#  Directos (solo loopback):
#    http://127.0.0.1:8888/checkUser y /server/online
#
#  Los archivos checkuser.py y checkuser.service deben estar junto a este
#  script (se copian desde su propio directorio, no desde el actual).
#
#  Uso (desde el menú MUSTAFA o directo):
#      sudo bash checkuser.sh
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="/usr/local/bin/checkuser.py"
SERVICE="checkuser"
NGINX_SITE="/etc/nginx/sites-available/mustafa"

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[checkuser] $*"; }
warn() { echo "[checkuser] [AVISO] $*" >&2; }

# Quita el bloque de checkUser del site de Nginx (si existe).
remove_nginx_proxy() {
    [[ -f "$NGINX_SITE" ]] || return 0
    grep -q "checkUser (MUSTAFA)" "$NGINX_SITE" 2>/dev/null || return 0
    CHECKUSER_NGINX_SITE="$NGINX_SITE" python3 - <<'PYEOF' || return 0
import os
site = os.environ["CHECKUSER_NGINX_SITE"]
with open(site) as f:
    lines = f.readlines()
start = end = None
for i, line in enumerate(lines):
    if "# checkUser (MUSTAFA)" in line:
        start = i
    if "# /checkUser (MUSTAFA)" in line:
        end = i
        break
if start is not None and end is not None and end >= start:
    del lines[start:end + 1]
    with open(site, "w") as f:
        f.writelines(lines)
PYEOF
}

# Publica checkUser en el :80 de Nginx (/checkUser y /server/online).
# Sin esto el servicio solo escucha en loopback.
ensure_nginx_proxy() {
    if ! command -v nginx >/dev/null 2>&1 || [[ ! -f "$NGINX_SITE" ]]; then
        info "Sin Nginx en este VPS: checkUser solo escucha en 127.0.0.1:$PORT."
        return 0
    fi
    remove_nginx_proxy
    CHECKUSER_NGINX_SITE="$NGINX_SITE" CHECKUSER_NGINX_PORT="$PORT" python3 - <<'PYEOF' || { warn "No se pudo parchear $NGINX_SITE; checkUser solo en :$PORT."; return 0; }
import os
site = os.environ["CHECKUSER_NGINX_SITE"]
port = os.environ["CHECKUSER_NGINX_PORT"]
block = """    # checkUser (MUSTAFA) -> 127.0.0.1:__PORT__
    location /checkUser {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /server/online {
        proxy_pass http://127.0.0.1:__PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
    # /checkUser (MUSTAFA)

""".replace("__PORT__", port)
with open(site) as f:
    content = f.read()
marker = "    location / {"
assert marker in content, "sin location / en el site de Nginx"
content = content.replace(marker, block + marker, 1)
with open(site, "w") as f:
    f.write(content)
PYEOF
    if nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null; then
        info "Nginx publica checkUser en :80 (/checkUser y /server/online)."
    else
        warn "Nginx no aceptó el cambio (nginx -t falló); checkUser solo en :$PORT."
    fi
}

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash checkuser.sh)."

# --- Puerto --------------------------------------------------------------------
# CHECKUSER_PORT lo fija quien llama (el menú) y es el puerto de LOOPBACK
# (Nginx lo publica en el :80). Sin él se mantiene el actual o 8888.
PORT_REQ="${CHECKUSER_PORT:-}"
port_actual() {
    local p=""
    [[ -f /etc/mustafa/ports/checkuser ]] && p="$(cat /etc/mustafa/ports/checkuser 2>/dev/null || true)"
    if [[ -z "$p" ]]; then
        p="$(grep -o -- '^Environment=CHECKUSER_PORT=[0-9]*' /etc/systemd/system/checkuser.service 2>/dev/null | grep -o '[0-9]*$' || true)"
    fi
    [[ -z "$p" ]] && p="8888"
    printf '%s' "$p"
}
if [[ -n "$PORT_REQ" ]]; then
    case "$PORT_REQ" in ""|*[!0-9]*) fail "CHECKUSER_PORT debe ser un número entre 1 y 65535." ;; esac
    PORT="$((10#$PORT_REQ))"
    [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "CHECKUSER_PORT debe ser entre 1 y 65535."
else
    PORT="$(port_actual)"
fi

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[checkuser] Desinstalando checkUser..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service" "$BIN"
    rm -rf /etc/mustafa/ports/checkuser
    remove_nginx_proxy
    if command -v nginx >/dev/null 2>&1; then
        nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    fi
    systemctl daemon-reload 2>/dev/null || true
    echo "[checkuser] checkUser desinstalado (servicio, binario y rutas de Nginx eliminados)."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    # Si se pidió otro puerto, no salir: reconfigurar y reiniciar abajo.
    if [[ -z "$PORT_REQ" || "$(port_actual)" == "$PORT_REQ" ]]; then
        info "checkUser ya está instalado y activo (127.0.0.1:$PORT, vía Nginx :80)."
        curl -fsS -m 5 "http://127.0.0.1:$PORT/server/online" 2>/dev/null &&
            echo "  /server/online responde." || echo "  (aviso: /server/online no respondió en local)"
        ensure_nginx_proxy
        systemctl --no-pager status "$SERVICE" --lines=5 || true
        exit 0
    fi
    info "Cambiando puerto checkUser de $(port_actual) a $PORT_REQ ..."
fi

# --- Instalación ---------------------------------------------------------------
for f in "$DIR/checkuser.py" "$DIR/checkuser.service"; do
    [ -f "$f" ] || fail "Falta $f (debe estar junto a checkuser.sh)."
done

command -v python3 >/dev/null 2>&1 || fail "Falta python3 (apt install python3)."

cp "$DIR/checkuser.py" "$BIN"
chmod +x "$BIN"
cp "$DIR/checkuser.service" "/etc/systemd/system/$SERVICE.service"
sed -i "s/^Environment=CHECKUSER_PORT=.*/Environment=CHECKUSER_PORT=$PORT/" "/etc/systemd/system/$SERVICE.service"
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
echo "$PORT" > /etc/mustafa/ports/checkuser
ensure_nginx_proxy

IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
info "checkUser instalado y corriendo."
info "  Escucha : 127.0.0.1:$PORT (vía Nginx :80 -> /checkUser y /server/online)"
info "  Público : http://${IP:-<IP>}/checkUser y /server/online"
info "  Servicio: $SERVICE.service"
info "  Prueba  : curl -s -X POST http://127.0.0.1:$PORT/checkUser -H 'Content-Type: application/json' -d '{\"user\": \"mexico\"}'"
info "  Usuarios online: curl -s http://127.0.0.1:$PORT/server/online"
info "  Nota: abre el puerto 80 en el firewall del proveedor si es una nube (AWS/Lightsail/etc.)."
info "  Logs  : journalctl -u $SERVICE -f"
