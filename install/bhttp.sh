#!/bin/bash
# BHTTP Server para MUSTAFA (titlan/v2install)
# Instala el servidor BHTTP (lacasitamx/CoreSSH, "DragonCoreSSH V40")
# como servicio systemd. Escucha en un puerto (por defecto 8087) y
# reenvia al SSH local (127.0.0.1:22). La app Mustafa VPN (Enigma) se
# conecta a este puerto con transporte BHTTP (modo 9).
#
# Uso interactivo (menu):
#   sudo bash bhttp.sh
# Uso directo:
#   sudo bash bhttp.sh --install [--port 8087] [--go /ruta/go]
#   sudo bash bhttp.sh --status
#   sudo bash bhttp.sh --stop
#   sudo bash bhttp.sh --uninstall
#
# EL CODIGO: el servidor se COMPILA desde el codigo fuente que viene
# junto a este script, en el directorio "bhttp-src" (copia congelada
# de lacasitamx/CoreSSH, commit 2b5a8c44, solo el paquete internal/bhttp
# y cmd/bhttp-standalone, que solo usan la libreria estandar de Go).
# Por eso este instalador NO depende del script ni del repo de La
# Casita: aunque lo cambien o lo borren, el instalador sigue igual.
# Ver install/bhttp-src/README.md para la procedencia exacta.
#
# EL TOOLCHAIN: para compilar se necesita Go >= 1.21. Si la maquina ya
# tiene un "go" usable, se usa ese. Si no, se descarga el toolchain
# oficial Go 1.27.4 de go.dev (SHA-256 verificado) a un directorio
# temporal, se compila y se borra. Con --go se puede pasar un binario
# "go" propio.
#
# El servicio escucha en TCP plano (SIN TLS), como el original de
# La Casita (puerto 8087). El protocolo BHTTP es binario propio, NO
# es el RFC 9292: header 29B, modos Probe/Upload/Download/Batch/ACK/
# Lane, payload XOR con keystream SHA-256. Verificado en vivo contra
# el servidor real con la sonda ~/workspace/bhttp-probe.py.

BHTTP_DIR="${BHTTP_DIR:-/opt/bhttp}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_NAME="bhttp-server"
PORT="8087"
GO_ARG=""
ACTION="menu"
GO_TMPDIR=""

# Toolchain oficial Go (go.dev/dl), version fijada y SHA-256 verificado.
GO_VERSION="go1.27.4"
GO_TARBALL="go1.27.4.linux-amd64.tar.gz"
GO_URL="https://go.dev/dl/$GO_TARBALL"
GO_SHA256="7226736c2339719cda28fbf3a54d71aa63bcefe376e98cef00034268dab24840"

fail() { echo "Error: $*" >&2; exit 1; }
# info va a stderr: obtener_go devuelve la ruta por stdout y un
# mensaje de progreso no debe mezclarse con ella.
info() { echo "[bhttp] $*" >&2; }

usage() {
  cat <<'EOF'
BHTTP Server para MUSTAFA.

Uso:
  sudo bash bhttp.sh                       Menu interactivo
  sudo bash bhttp.sh --install [--port N] [--go /ruta/go]
  sudo bash bhttp.sh --status
  sudo bash bhttp.sh --stop
  sudo bash bhttp.sh --uninstall
  sudo bash bhttp.sh --help

Opciones:
  --port N      Puerto donde escucha BHTTP. Por defecto: 8087
  --go RUTA     Binario "go" a usar para compilar (por defecto: el del
                sistema si es >= 1.21, si no se descarga Go 1.27.4 de go.dev)
  --status      Muestra si el servicio corre y en que puerto escucha
  --stop        Detiene el servicio (no borra nada)
  --uninstall   Quita el servicio (conserva /opt/bhttp)

El codigo fuente se compila desde "bhttp-src" junto a este script.
EOF
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install)   ACTION="install"; shift ;;
      --status)    ACTION="status"; shift ;;
      --stop)      ACTION="stop"; shift ;;
      --uninstall) ACTION="uninstall"; shift ;;
      --help|-h)   usage; exit 0 ;;
      --port)
        [ "$#" -ge 2 ] || fail "--port necesita un numero."
        PORT="$2"; shift 2 ;;
      --go)
        [ "$#" -ge 2 ] || fail "--go necesita la ruta del binario go."
        GO_ARG="$2"; shift 2 ;;
      *) fail "Opcion desconocida: $1 (usa --help)." ;;
    esac
  done
  case "$PORT" in ""|*[!0-9]*) fail "--port debe ser un numero entre 1 y 65535." ;; esac
  PORT="$((10#$PORT))"
  [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || fail "--port debe ser entre 1 y 65535."
}

require_root() {
  [ "$(id -u)" -eq 0 ] || fail "Corre esto como root (sudo bash bhttp.sh)."
  [ "$(uname -s)" = "Linux" ] || fail "Solo Linux."
  for c in systemctl ss tar sha256sum; do
    command -v "$c" >/dev/null 2>&1 || fail "Falta el comando: $c"
  done
  systemctl show --property=Version --value >/dev/null 2>&1 ||
    fail "systemd no esta disponible en esta maquina."
  [ "$(uname -m)" = "x86_64" ] || fail "Este instalador es x86_64; esta maquina es $(uname -m)."
}

# --- toolchain Go ----------------------------------------------------------
# Devuelve 0 si el binario "go" dado es version >= 1.21.
go_version_ok() {
  local v
  v="$("$1" version 2>/dev/null | awk '{print $3}')" || return 1
  v="${v#go}"
  local major minor
  major="${v%%.*}"; minor="${v#*.}"; minor="${minor%%.*}"
  case "$major$minor" in ""|*[!0-9]*) return 1 ;; esac
  [ "$major" -gt 1 ] || { [ "$major" -eq 1 ] && [ "$minor" -ge 21 ]; }
}

# Deja el binario "go" a usar en la variable global GO_BIN.
# NO se captura con $(...) : la captura corre en un subshell, donde el
# trap EXIT borraría el Go descargado antes de compilar (y GO_TMPDIR no
# sobreviviría al subshell). Los mensajes ya van a stderr (ver info).
obtener_go() {
  if [ -n "$GO_ARG" ]; then
    [ -x "$GO_ARG" ] || fail "No existe o no es ejecutable: $GO_ARG"
    go_version_ok "$GO_ARG" || fail "El go de $GO_ARG es menor que 1.21."
    info "Usando Go de $GO_ARG: $("$GO_ARG" version)"
    GO_BIN="$GO_ARG"
    return
  fi
  if command -v go >/dev/null 2>&1 && go_version_ok "$(command -v go)"; then
    info "Usando Go del sistema: $(go version)"
    GO_BIN="$(command -v go)"
    return
  fi
  command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 ||
    fail "Para descargar Go se necesita curl o wget."
  GO_TMPDIR="$(mktemp -d /tmp/bhttp-go.XXXXXX)"
  local tgz="$GO_TMPDIR/$GO_TARBALL"
  info "Descargando Go $GO_VERSION de go.dev ..."
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$tgz" "$GO_URL" || { rm -rf "$GO_TMPDIR"; fail "No se pudo descargar Go."; }
  else
    wget -qO "$tgz" "$GO_URL" || { rm -rf "$GO_TMPDIR"; fail "No se pudo descargar Go."; }
  fi
  local sha
  sha="$(sha256sum "$tgz" | awk '{print $1}')"
  [ "$sha" = "$GO_SHA256" ] || { rm -rf "$GO_TMPDIR"; fail "El SHA-256 de Go no coincide (descarga corrupta). Esperado: $GO_SHA256 Recibido: $sha"; }
  tar -xzf "$tgz" -C "$GO_TMPDIR" || { rm -rf "$GO_TMPDIR"; fail "No se pudo descomprimir Go."; }
  local gobin="$GO_TMPDIR/go/bin/go"
  [ -x "$gobin" ] || { rm -rf "$GO_TMPDIR"; fail "El toolchain descargado no trae el binario go."; }
  go_version_ok "$gobin" || { rm -rf "$GO_TMPDIR"; fail "El Go descargado no es >= 1.21."; }
  info "Go $GO_VERSION listo: $($gobin version)"
  GO_BIN="$gobin"
}

limpiar_go_tmp() {
  [ -n "$GO_TMPDIR" ] && [ -d "$GO_TMPDIR" ] && rm -rf "$GO_TMPDIR"
  # Siempre 0: con set -e, si esta función (trap EXIT) devuelve 1
  # el script terminaría con exit 1 aunque todo haya ido bien.
  return 0
}

# --- compilacion -----------------------------------------------------------
compilar() {
  local go="$1"
  local script_dir src_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  src_dir="$script_dir/bhttp-src"
  for f in "$src_dir/go.mod" "$src_dir/internal/bhttp/protocol.go" \
           "$src_dir/internal/bhttp/server.go" "$src_dir/internal/bhttp/session.go" \
           "$src_dir/internal/bhttp/sniff.go" "$src_dir/cmd/bhttp-standalone/main.go"; do
    [ -f "$f" ] || fail "Falta el codigo fuente: $f (el directorio bhttp-src debe estar junto a bhttp.sh)."
  done
  mkdir -p "$BHTTP_DIR"
  chmod 755 "$BHTTP_DIR"
  info "Compilando bhttp-server desde $src_dir ..."
  (cd "$src_dir" && GOTOOLCHAIN=local GOPROXY=off CGO_ENABLED=0 \
    "$go" build -trimpath -ldflags "-s -w" \
    -o "$BHTTP_DIR/bhttp-server" ./cmd/bhttp-standalone) ||
    fail "La compilacion fallo. Revisa el error de arriba."
  [ -x "$BHTTP_DIR/bhttp-server" ] || fail "No quedo el binario en $BHTTP_DIR/bhttp-server."
  chmod 755 "$BHTTP_DIR/bhttp-server"
  info "Binario compilado: $(stat -c %s "$BHTTP_DIR/bhttp-server") bytes, SHA-256 $(sha256sum "$BHTTP_DIR/bhttp-server" | awk '{print $1}')"
}

# --- servicio --------------------------------------------------------------
render_unit() {
  cat > "$BHTTP_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=BHTTP server
Wants=network-online.target
After=network-online.target ssh.service sshd.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=exec
User=root
Group=root
WorkingDirectory=$BHTTP_DIR
ExecStart=$BHTTP_DIR/bhttp-server -listen 0.0.0.0:$PORT -target 127.0.0.1:22 -session-timeout 2m -dial-timeout 10s -max-v2-lanes 128 -max-connections 1024 -max-sessions 1024 -log-connections=true
Restart=on-failure
RestartSec=3s
TimeoutStopSec=15s
KillSignal=SIGTERM
UMask=0077
NoNewPrivileges=true
CapabilityBoundingSet=
AmbientCapabilities=
PrivateTmp=true
PrivateDevices=true
ProtectSystem=full
ProtectHome=read-only
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
MemoryDenyWriteExecute=false
LimitNOFILE=65535
LimitCORE=0
TasksMax=512
MemoryMax=384M
StandardOutput=journal
StandardError=journal
SyslogIdentifier=bhttp-server

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$BHTTP_DIR/$SERVICE_NAME.service"
  systemd-analyze verify "$BHTTP_DIR/$SERVICE_NAME.service" 2>/dev/null || true
}

do_install() {
  require_root
  # Puerto libre (salvo que ya sea el propio BHTTP corriendo).
  if ss -tlnp 2>/dev/null | grep -q ":$PORT " && ! systemctl is-active --quiet "$SERVICE_NAME.service"; then
    fail "El puerto $PORT ya esta ocupado por otro servicio."
  fi
  # obtener_go deja el binario en la global GO_BIN (sin subshell: con
  # $(...) el trap EXIT borraría el Go descargado antes de compilar).
  GO_BIN=""
  obtener_go || exit 1
  compilar "$GO_BIN"
  limpiar_go_tmp
  render_unit
  [ -L "$SYSTEMD_DIR/$SERVICE_NAME.service" ] ||
    ln -s "$BHTTP_DIR/$SERVICE_NAME.service" "$SYSTEMD_DIR/$SERVICE_NAME.service"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME.service"
  systemctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  if ! systemctl restart "$SERVICE_NAME.service"; then
    systemctl status --no-pager --full "$SERVICE_NAME.service" || true
    fail "El servicio no arranco. Revisa el log con: journalctl -u $SERVICE_NAME -n 50"
  fi
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME.service" ||
    fail "El servicio no quedo activo."
  ss -tlnp 2>/dev/null | grep -q ":$PORT " ||
    fail "El servicio esta activo pero no escucha en el puerto $PORT."
  echo
  info "BHTTP instalado y corriendo."
  info "  Puerto:      $PORT  (TCP plano, sin TLS; destino SSH: 127.0.0.1:22)"
  info "  Directorio:  $BHTTP_DIR"
  info "  Servicio:    $SERVICE_NAME.service"
  info "  Estado:      $(systemctl is-active $SERVICE_NAME.service)"
  info "  Binario:     $BHTTP_DIR/bhttp-server ($(stat -c %s "$BHTTP_DIR/bhttp-server") bytes)"
  info "En la app Mustafa VPN usa BHTTP (modo 9) con la IP de esta VPS y el puerto $PORT."
  info "Recuerda crear usuarios SSH en el menú MUSTAFA para poder entrar."
}

do_status() {
  if systemctl is-active --quiet "$SERVICE_NAME.service" 2>/dev/null; then
    echo "BHTTP: ON"
    systemctl status --no-pager -l "$SERVICE_NAME.service" 2>/dev/null | head -n 8
    ss -tlnp 2>/dev/null | grep -E "bhttp-server" || true
    [ -f "$BHTTP_DIR/bhttp-server" ] && echo "Binario: $BHTTP_DIR/bhttp-server ($(stat -c %s "$BHTTP_DIR/bhttp-server") bytes)"
  else
    echo "BHTTP: OFF (servicio $SERVICE_NAME no activo)"
    [ -f "$BHTTP_DIR/bhttp-server" ] && echo "Binario presente en $BHTTP_DIR (sin correr)." ||
      echo "Sin instalar en $BHTTP_DIR."
  fi
}

do_stop() {
  require_root
  systemctl stop "$SERVICE_NAME.service" 2>/dev/null || fail "No se pudo detener el servicio."
  info "BHTTP detenido (archivos conservados)."
}

do_uninstall() {
  require_root
  systemctl disable --now "$SERVICE_NAME.service" 2>/dev/null || true
  rm -f "$SYSTEMD_DIR/$SERVICE_NAME.service"
  systemctl daemon-reload
  systemctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  info "BHTTP desinstalado del sistema. Archivos conservados en $BHTTP_DIR."
}

menu() {
  while true; do
    clear 2>/dev/null || true
    echo "———————————— BHTTP Server — MUSTAFA ————————————"
    do_status
    echo "—————————————————————————————————————————————"
    echo "[1] Instalar / Iniciar BHTTP"
    echo "[2] Ver estado"
    echo "[3] Detener BHTTP"
    echo "[4] Desinstalar BHTTP"
    echo "[0] Salir"
    echo "—————————————————————————————————————————————"
    read -rp "Elige una opcion: " op
    case "$op" in
      1) read -rp "Puerto [8087]: " p; [ -n "$p" ] && PORT="$p"
         do_install; read -rp "Enter para seguir..." _ ;;
      2) do_status; read -rp "Enter para seguir..." _ ;;
      3) do_stop; read -rp "Enter para seguir..." _ ;;
      4) do_uninstall; read -rp "Enter para seguir..." _ ;;
      0) exit 0 ;;
      *) echo "Opcion no valida."; sleep 1 ;;
    esac
  done
}

trap limpiar_go_tmp EXIT
parse_args "$@"
case "$ACTION" in
  install)   do_install ;;
  status)    do_status ;;
  stop)      do_stop ;;
  uninstall) do_uninstall ;;
  menu)      menu ;;
esac
