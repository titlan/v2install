#!/usr/bin/env bash
# =============================================================================
#  Panel Web MUSTAFA — instalador
#  Instala el panel web (Flask, glass + tarjetas) en el puerto 9090.
#  El panel es la cara gráfica del menú MUSTAFA: Dashboard, SSH, V2Ray,
#  Protocolos y Herramientas, con login por contraseña.
#
#  Archivos: el panel vive en /opt/mustafa-panel/ (app.py + index.html),
#  copiados desde install/panel-web/ junto a este script.
#  Config: /etc/mustafa/panel/ (password.hash, secret.key).
#  Servicio: panel-web.service (0.0.0.0:9090).
#
#  Uso:
#      sudo bash panel-web.sh              # instalar (pide contraseña si no hay)
#      sudo bash panel-web.sh --uninstall  # desinstalar (conserva la contraseña)
#      sudo bash panel-web.sh --password   # cambiar contraseña
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PANEL_DIR="/opt/mustafa-panel"
PANEL_SRC="$DIR/panel-web"
CONF_DIR="/etc/mustafa/panel"
HASH_FILE="$CONF_DIR/password.hash"
SECRET_FILE="$CONF_DIR/secret.key"
SERVICE="panel-web"
PORT=9090

fail() { echo "[panel-web] Error: $*" >&2; exit 1; }
info() { echo "[panel-web] $*"; }
warn() { echo "[panel-web] [AVISO] $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash panel-web.sh)."

# Genera el hash de una contraseña: formato sha256$<salt>$<hex>
# (es el formato que verifica app.py).
hash_password() {
    local pass="$1"
    python3 - "$pass" <<'PYEOF'
import hashlib, secrets, sys
password = sys.argv[1]
salt = secrets.token_hex(8)
h = hashlib.sha256((salt + password).encode()).hexdigest()
print(f"sha256${salt}${h}")
PYEOF
}

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    echo "[panel-web] Desinstalando panel web..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service"
    rm -rf "$PANEL_DIR" /etc/mustafa/ports/panel-web
    systemctl daemon-reload 2>/dev/null || true
    echo "[panel-web] Panel web desinstalado (servicio y archivos eliminados; la contraseña en $CONF_DIR se conserva)."
    exit 0
fi

# --- Cambiar contraseña ---------------------------------------------------------
if [[ "${1:-}" == "--password" ]]; then
    read -rsp "  Nueva contraseña del panel: " pass1; echo
    read -rsp "  Repite la contraseña: " pass2; echo
    [[ "$pass1" == "$pass2" ]] || fail "Las contraseñas no coinciden."
    [[ -n "$pass1" ]] || fail "La contraseña no puede estar vacía."
    mkdir -p "$CONF_DIR"
    hash_password "$pass1" > "$HASH_FILE"
    chmod 600 "$HASH_FILE"
    systemctl restart "$SERVICE" 2>/dev/null || true
    echo "[panel-web] Contraseña actualizada."
    exit 0
fi

# --- Instalación ---------------------------------------------------------------
for f in "$PANEL_SRC/app.py" "$PANEL_SRC/index.html"; do
    [ -f "$f" ] || fail "Falta $f (debe estar en $PANEL_SRC junto a panel-web.sh)."
done
command -v python3 >/dev/null 2>&1 || fail "Falta python3 (apt install python3)."

# Flask (si no está)
if ! python3 -c "import flask" 2>/dev/null; then
    info "Instalando Flask..."
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get update -y >/dev/null 2>&1; then
        warn "apt-get update falló; se intenta instalar Flask de todos modos."
    fi
    if ! apt-get install -y python3-flask 2>/dev/null; then
        warn "No se pudo instalar python3-flask con apt; probando con pip..."
        python3 -m pip install --break-system-packages flask 2>/dev/null \
            || fail "No se pudo instalar Flask (ni apt ni pip). Instálalo a mano: apt install python3-flask"
    fi
    python3 -c "import flask" 2>/dev/null || fail "Flask no quedó instalado."
    info "Flask instalado."
fi

# Archivos del panel
mkdir -p "$PANEL_DIR"
cp "$PANEL_SRC/app.py" "$PANEL_SRC/index.html" "$PANEL_DIR/"
chmod 644 "$PANEL_DIR/app.py" "$PANEL_DIR/index.html"

# Config: secret key + contraseña
mkdir -p "$CONF_DIR"
if [[ ! -f "$SECRET_FILE" ]]; then
    python3 -c "import secrets; print(secrets.token_hex(32))" > "$SECRET_FILE"
    chmod 600 "$SECRET_FILE"
fi
PASS_GENERATED=""
if [[ ! -f "$HASH_FILE" ]]; then
    read -rp "  Contraseña del panel (vacía = aleatoria): " pass || true
    if [[ -z "${pass:-}" ]]; then
        pass="$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)"
        PASS_GENERATED="$pass"
    fi
    hash_password "$pass" > "$HASH_FILE"
    chmod 600 "$HASH_FILE"
    info "Contraseña del panel guardada."
fi

# Servicio systemd
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Panel Web MUSTAFA (glass + tarjetas, :$PORT)
After=network.target

[Service]
Type=simple
WorkingDirectory=$PANEL_DIR
Environment=PANEL_PORT=$PORT
ExecStart=/usr/bin/python3 $PANEL_DIR/app.py
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE"
systemctl restart "$SERVICE" || true
sleep 2

if ! systemctl is-active --quiet "$SERVICE"; then
    echo "  --- journal de $SERVICE ---"
    journalctl -u "$SERVICE" -n 30 --no-pager 2>/dev/null | sed 's/^/  /' || true
    fail "El servicio $SERVICE no quedó activo. Revisa: journalctl -u $SERVICE -n 50"
fi
ss -tln 2>/dev/null | grep -q ":$PORT " ||
    fail "El servicio está activo pero no escucha en el puerto $PORT. Revisa: journalctl -u $SERVICE -n 50"
mkdir -p /etc/mustafa/ports
echo "$PORT" > /etc/mustafa/ports/panel-web

IP="$(curl -4 -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | tr ' ' '\n' | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')"
echo
info "Panel web instalado y corriendo."
info "  URL      : http://${IP:-<IP>}:$PORT"
info "  Servicio : $SERVICE.service"
if [[ -n "$PASS_GENERATED" ]]; then
    info "  Contraseña (generada, guárdala): $PASS_GENERATED"
else
    info "  Contraseña: la que pusiste al instalar (cámbiala en el menú [06] -> [4])."
fi
info "  Logs     : journalctl -u $SERVICE -f"
