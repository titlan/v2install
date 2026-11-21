#!/usr/bin/env bash
# =============================================================================
#  Knightbot-MD — Bot de WhatsApp (Baileys) para administrar grupos
#  Instalador MUSTAFA. Clona el repo público mruniquehacker/Knightbot-MD
#  (MIT, ~100 comandos: .tagall, .kick, .ban, .mute, .warn, .antilink,
#  juegos, IA, stickers, descargas...) a /opt/knightbot, instala Node.js 20
#  si hace falta, instala las dependencias y lo deja como servicio systemd
#  knightbot.service.
#
#  NOMBRE DEL BOT: "Anubis Bot" (botName en settings.js; packname igual
#  para los stickers). Se aplica en cada corrida del instalador, así que
#  reinstalar también renombra un bot que todavía se llame "Knight Bot".
#
#  VINCULACIÓN: al arrancar, el bot pide un código de pareo para el número
#  del dueño (el de la SIM de prepago). El código se muestra al final de
#  esta instalación y también con: journalctl -u knightbot -n 60
#  Se mete en WhatsApp → Ajustes → Dispositivos vinculados → Vincular
#  dispositivo → introduce el código. La sesión queda en /opt/knightbot/session.
#
#  AVISO: Knightbot usa Baileys (no oficial). WhatsApp puede banear el
#  número. Usa SIEMPRE una SIM de prepago que puedas perder, NUNCA tu
#  número personal. La API oficial no administra grupos; este bot sí,
#  con ese riesgo.
#
#  Uso (desde el menú MUSTAFA [05] o directo):
#      sudo bash knightbot.sh [--number 5215500000000] [--uninstall]
#      KNIGHTBOT_NUMBER=5215500000000 sudo bash knightbot.sh
#  El número lleva código de país, sin + ni espacios (ej. 5215500000000).
#  Es idempotente: si ya está instalado y activo, no reinstala nada.
# =============================================================================

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/knightbot"
REPO="https://github.com/mruniquehacker/Knightbot-MD.git"
SERVICE="knightbot"
NODE_BIN=""

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[knightbot] $*"; }
ok()   { echo "[knightbot] [OK] $*"; }

# --- Nombre del bot: Anubis Bot ----------------------------------------------
# botName es el nombre que el bot usa en sus mensajes (menú, estado...);
# packname es el nombre del paquete de stickers. El repo trae "Knight Bot"
# en ambos; aquí se ponen a "Anubis Bot". Es idempotente: si ya es
# "Anubis Bot" no toca nada. Devuelve 0 si cambió algo, 1 si no.
aplicar_nombre_bot() {
    local f="$INSTALL_DIR/settings.js" cambio=0
    [[ -f "$f" ]] || return 1
    if grep -q 'botName:' "$f" 2>/dev/null && ! grep -q 'botName: "Anubis Bot"' "$f" 2>/dev/null; then
        sed -i -E 's/botName: "[^"]*"/botName: "Anubis Bot"/' "$f"
        cambio=1
    fi
    if grep -q "packname:" "$f" 2>/dev/null && ! grep -q "packname: 'Anubis Bot'" "$f" 2>/dev/null; then
        sed -i -E "s/packname: '[^']*'/packname: 'Anubis Bot'/" "$f"
        cambio=1
    fi
    [[ "$cambio" == 1 ]]
}

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash knightbot.sh)."

# --- Argumentos ---------------------------------------------------------------
NUMBER="${KNIGHTBOT_NUMBER:-}"
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --uninstall) UNINSTALL=1 ;;
        --number) NUMBER="${2:-}"; shift ;;
        --number=*) NUMBER="${1#--number=}" ;;
        *) fail "Argumento no conocido: $1 (usa --number N o --uninstall)." ;;
    esac
    shift
done

# --- Desinstalar ---------------------------------------------------------------
if [[ "$UNINSTALL" == 1 ]]; then
    echo "[knightbot] Desinstalando bot de WhatsApp..."
    systemctl stop "$SERVICE" 2>/dev/null || true
    systemctl disable "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/$SERVICE.service"
    rm -rf "$INSTALL_DIR"
    systemctl daemon-reload 2>/dev/null || true
    echo "[knightbot] Bot desinstalado (servicio, /opt/knightbot y la sesión eliminados)."
    echo "[knightbot] Si el número sigue vinculado en WhatsApp, desvincúlalo en"
    echo "[knightbot] Ajustes > Dispositivos vinculados."
    exit 0
fi

# --- Idempotencia: si ya está instalado y activo, solo se aplica el nombre --
if [[ -f "$INSTALL_DIR/package.json" ]] && systemctl is-active --quiet "$SERVICE" 2>/dev/null; then
    info "Knightbot ya está instalado y activo."
    if aplicar_nombre_bot; then
        info "Nombre actualizado a Anubis Bot; reiniciando el bot ..."
        systemctl restart "$SERVICE" || true
        sleep 1
    fi
    systemctl --no-pager status "$SERVICE" --lines=5 || true
    info "  Código de pareo / log: journalctl -u $SERVICE -n 60"
    exit 0
fi

# --- Node.js >= 18 + npm -------------------------------------------------------
# Knightbot necesita node >= 18 Y npm. No basta con que exista node: hay
# instalaciones (node standalone, nvm) donde npm no está en el PATH de
# root/sudo y el "npm install" fallaría. Si falta npm, se instala el
# paquete nodejs completo de NodeSource (que trae npm en /usr/bin).
# Devuelve 0 si el binario "node" dado es versión >= 18.
node_version_ok() {
    local v major
    v="$("$1" --version 2>/dev/null || true)"
    v="${v#v}"
    major="${v%%.*}"
    case "$major" in ""|*[!0-9]*) return 1 ;; esac
    [ "$major" -ge 18 ]
}

instalar_node20() {
    command -v curl >/dev/null 2>&1 || fail "Para instalar Node.js se necesita curl."
    info "Instalando Node.js 20 (NodeSource) ..."
    curl -fsSL https://deb.nodesource.com/setup_20.x -o /tmp/nodesource_setup.sh ||
        fail "No se pudo descargar el instalador de NodeSource."
    bash /tmp/nodesource_setup.sh >/dev/null 2>&1 ||
        fail "Falló el instalador de NodeSource."
    rm -f /tmp/nodesource_setup.sh
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs ||
        fail "No se pudo instalar nodejs."
    command -v node >/dev/null 2>&1 || fail "Node no quedó instalado."
    node_version_ok "$(command -v node)" || fail "El Node instalado no es >= 18: $(node --version)"
    command -v npm >/dev/null 2>&1 || fail "npm no quedó instalado."
    info "Node instalado: $(node --version), npm $(npm --version)"
}

if command -v node >/dev/null 2>&1 && node_version_ok "$(command -v node)"; then
    NODE_BIN="$(command -v node)"
    info "Usando Node del sistema: $(node --version)"
    if ! command -v npm >/dev/null 2>&1; then
        info "Node está instalado pero falta npm en el PATH; instalando el paquete nodejs completo ..."
        instalar_node20
        NODE_BIN="$(command -v node)"
    fi
else
    instalar_node20
    NODE_BIN="$(command -v node)"
fi
NPM_BIN="$(command -v npm)"
info "npm: $NPM_BIN ($(npm --version))"

# --- Dependencias del sistema --------------------------------------------------
# git para clonar, ffmpeg para stickers y conversión de medios.
for pkg in git ffmpeg; do
    if ! command -v "$pkg" >/dev/null 2>&1; then
        info "Instalando $pkg ..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" ||
            fail "No se pudo instalar $pkg."
    fi
done

# --- Código: clonar o actualizar ----------------------------------------------
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Actualizando Knightbot en $INSTALL_DIR (git pull) ..."
    git -C "$INSTALL_DIR" pull --ff-only 2>/dev/null ||
        echo "  (git pull falló, probablemente por cambios locales; se sigue con el código actual.)"
elif [[ -f "$INSTALL_DIR/package.json" ]]; then
    info "El código ya está en $INSTALL_DIR (sin .git); se reutiliza."
else
    info "Clonando Knightbot-MD a $INSTALL_DIR ..."
    git clone --depth 1 "$REPO" "$INSTALL_DIR" ||
        fail "No se pudo clonar $REPO."
fi
[[ -f "$INSTALL_DIR/package.json" ]] || fail "No quedó package.json en $INSTALL_DIR."
[[ -f "$INSTALL_DIR/index.js" ]] || fail "No quedó index.js en $INSTALL_DIR."

# --- Dependencias npm -----------------------------------------------------------
info "Instalando dependencias npm (tarda unos minutos) ..."
if ! (cd "$INSTALL_DIR" && "$NPM_BIN" install --no-audit --no-fund); then
    info "npm install falló; reintentando con --legacy-peer-deps ..."
    (cd "$INSTALL_DIR" && "$NPM_BIN" install --legacy-peer-deps --no-audit --no-fund) ||
        fail "npm install falló. Revisa el error de arriba."
fi
ok "Dependencias instaladas."

# --- Número del dueño (SIM de prepago del bot) ---------------------------------
# Solo se usa para pedir el código de pareo cuando la sesión no está
# vinculada. Si la sesión ya existe, cambiar el número NO cambia la
# cuenta vinculada; para cambiar de cuenta hay que borrar la sesión.
if [[ -z "$NUMBER" ]]; then
    if [[ -t 0 ]]; then
        echo
        echo "  Número de WhatsApp del BOT (SIM de prepago, con código de país,"
        echo "  sin + ni espacios; ej. México: 5215500000000):"
        read -rp "  Número: " NUMBER || true
    fi
fi
NUMBER="$(printf '%s' "$NUMBER" | tr -cd '0-9')"
case "$NUMBER" in
    ""|*[!0-9]*)
        fail "Falta el número del bot. Pásalo con --number N o KNIGHTBOT_NUMBER=N."
        ;;
esac
if [[ "${#NUMBER}" -lt 7 || "${#NUMBER}" -gt 15 ]]; then
    fail "El número '$NUMBER' no parece válido (debe tener 7-15 dígitos con código de país)."
fi

if [[ -d "$INSTALL_DIR/session" ]] && ls "$INSTALL_DIR/session"/creds.json >/dev/null 2>&1; then
    echo "  (Ya hay una sesión vinculada en $INSTALL_DIR/session; el número"
    echo "   solo se guarda para el dueño. Para cambiar de cuenta, borra la"
    echo "   sesión y reinicia el servicio.)"
fi
# settings.js: ownerNumber (lo usa el bot cuando no hay terminal).
if grep -q "ownerNumber:" "$INSTALL_DIR/settings.js" 2>/dev/null; then
    sed -i -E "s/ownerNumber: '[^']*'/ownerNumber: '$NUMBER'/" "$INSTALL_DIR/settings.js"
fi
# settings.js: nombre del bot "Anubis Bot" (botName + packname de stickers).
aplicar_nombre_bot || true
# data/owner.json: lista de dueños (comandos de dueño).
printf '["%s"]' "$NUMBER" > "$INSTALL_DIR/data/owner.json"
info "Número del dueño configurado: $NUMBER"
info "Nombre del bot: Anubis Bot"

# --- Servicio systemd -----------------------------------------------------------
NODE_BIN="$(command -v node)"
cat > "/etc/systemd/system/$SERVICE.service" <<EOF
[Unit]
Description=Knightbot-MD WhatsApp Bot (MUSTAFA)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$NODE_BIN --max-old-space-size=512 --optimize-for-size --gc-interval=100 index.js
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
# enable --now solo no reinicia un servicio que ya corre.
systemctl enable "$SERVICE"
systemctl restart "$SERVICE" || true
sleep 2
systemctl is-active --quiet "$SERVICE" ||
    fail "El servicio no quedó activo. Revisa con: journalctl -u $SERVICE -n 50"

# --- Código de pareo ------------------------------------------------------------
# El bot pide el código ~3 s después de arrancar, solo si la sesión no
# está vinculada. Se busca en el journal con "-o cat" (solo el mensaje,
# sin fecha ni hostname: el hostname podría contener un patrón XXXX-XXXX
# y dar un código falso). Si el bot no logra conectar con WhatsApp, el
# log dice "Failed to get pairing code" y no hay código que mostrar.
echo
info "Buscando el código de pareo en el log (hasta ~30 s) ..."
CODE=""
for _ in 1 2 3 4 5 6; do
    sleep 5
    CODE="$(journalctl -u "$SERVICE" -n 200 -o cat --no-pager 2>/dev/null |
        sed 's/\x1b\[[0-9;]*m//g' |
        grep -oE '[A-Za-z0-9]{4}-[A-Za-z0-9]{4}' | tail -n 1 || true)"
    [[ -n "$CODE" ]] && break
done

echo
if [[ -n "$CODE" ]]; then
    echo "  ===================================================="
    echo "  CÓDIGO DE PAREO: $CODE"
    echo "  ===================================================="
    echo "  En el teléfono con el número $NUMBER:"
    echo "    WhatsApp → Ajustes → Dispositivos vinculados"
    echo "    → Vincular dispositivo → introduce el código."
    echo "  El código caduca en pocos minutos; si vence, reinicia"
    echo "  el servicio y se genera otro: systemctl restart $SERVICE"
else
    if ls "$INSTALL_DIR/session"/creds.json >/dev/null 2>&1; then
        ok "Sesión ya vinculada (no se pidió código nuevo)."
    elif journalctl -u "$SERVICE" -n 100 -o cat --no-pager 2>/dev/null | grep -q "Failed to get pairing code"; then
        echo "  El bot NO pudo pedir el código: no logra conectar con WhatsApp."
        echo "  Revisa el log (journalctl -u $SERVICE -n 50) y tu internet;"
        echo "  luego reinicia el servicio y se genera el código:"
        echo "    systemctl restart $SERVICE"
    else
        echo "  No se encontró el código de pareo en el log todavía."
        echo "  Míralo con: journalctl -u $SERVICE -f"
        echo "  (o desde el menú [05] → [6] Ver código de pareo)."
    fi
fi

echo
ok "Bot WhatsApp instalado y corriendo."
info "  Código : $INSTALL_DIR (Knightbot-MD, Baileys)"
info "  Servicio: $SERVICE.service"
info "  Nombre : Anubis Bot"
info "  Número : $NUMBER (SIM de prepago; nunca tu número personal)"
info "  Comandos: .menu, .tagall, .kick, .ban, .mute, .warn, .sticker, ..."
info "  Logs   : journalctl -u $SERVICE -f"
info "  AVISO  : bot no oficial; WhatsApp puede banear el número."
