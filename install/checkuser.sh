#!/usr/bin/env bash
# =============================================================================
#  checkUser — instalador MUSTAFA
#  Instala el servicio checkUser (verifica usuarios SSH y su vencimiento,
#  y cuenta usuarios conectados) en el puerto 80, para las tarjetas
#  "Usuarios Online" y "Vence" de la app Mustafa VPN.
#
#  Endpoints:
#    POST http://<IP>:80/checkUser    {"user": "...", "token": "..."}
#    GET  http://<IP>:80/server/online
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

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[checkuser] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash checkuser.sh)."

# --- Idempotencia: si ya está instalado y activo, no se toca nada -----------
if [[ -x "$BIN" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "checkUser ya está instalado y activo (puerto 80)."
    curl -fsS -m 5 http://127.0.0.1:80/server/online 2>/dev/null &&
        echo "  /server/online responde." || echo "  (aviso: /server/online no respondió en local)"
    systemctl --no-pager status "$SERVICE" --lines=5 || true
    exit 0
fi

# --- Instalación ---------------------------------------------------------------
for f in "$DIR/checkuser.py" "$DIR/checkuser.service"; do
    [ -f "$f" ] || fail "Falta $f (debe estar junto a checkuser.sh)."
done

command -v python3 >/dev/null 2>&1 || fail "Falta python3 (apt install python3)."

cp "$DIR/checkuser.py" "$BIN"
chmod +x "$BIN"
cp "$DIR/checkuser.service" "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable --now "$SERVICE"
sleep 1
systemctl is-active --quiet "$SERVICE" ||
    fail "El servicio no quedó activo. Revisa con: journalctl -u $SERVICE -n 50"

IP="$(curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')"
echo
info "checkUser instalado y corriendo."
info "  Puerto  : 80 (http://${IP:-<IP>}/checkUser y /server/online)"
info "  Servicio: $SERVICE.service"
info "  Prueba  : curl -s -X POST http://127.0.0.1:80/checkUser -H 'Content-Type: application/json' -d '{\"user\": \"mexico\"}'"
info "  Usuarios online: curl -s http://127.0.0.1:80/server/online"
info "  Nota: abre el puerto 80 en el firewall del proveedor si es una nube (AWS/Lightsail/etc.)."
info "  Logs  : journalctl -u $SERVICE -f"
