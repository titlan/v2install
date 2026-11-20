#!/usr/bin/env bash
# =============================================================================
#  HERRAMIENTAS MUSTAFA — Fail2Ban + BBR + vnStat + Respaldo
#  Instala herramientas útiles para un VPS de VPN, todas ligeras:
#    - Fail2Ban: bloquea IPs tras varios intentos fallidos de SSH.
#    - BBR: control de congestión TCP del kernel (más velocidad y
#      estabilidad para el VPN). Solo si el kernel lo soporta.
#    - vnStat: mide el tráfico por día/mes (para saber cuánto usan
#      los usuarios).
#    - Respaldo: script /usr/local/bin/mustafa-backup que guarda
#      usuarios SSH, keys y configuraciones en /root/mustafa-backup-*.tar.gz
#
#  Uso (desde el menú MUSTAFA [05] o directo):
#      sudo bash herramientas.sh
#  Es idempotente: se puede correr de nuevo sin romper nada.
# =============================================================================

set -euo pipefail

fail() { echo "Error: $*" >&2; exit 1; }
info() { echo "[herramientas] $*"; }
ok()   { echo "[herramientas] [OK] $*"; }

[[ "$(id -u)" -eq 0 ]] || fail "Ejecuta como root (sudo bash herramientas.sh)."
command -v apt-get >/dev/null 2>&1 || fail "Se necesita apt (Ubuntu/Debian)."

BACKUP_BIN="/usr/local/bin/mustafa-backup"

# --- Fail2Ban ------------------------------------------------------------------
echo
info "=== Fail2Ban (protege SSH de fuerza bruta) ==="
if ! dpkg -s fail2ban >/dev/null 2>&1; then
    info "Instalando fail2ban ..."
    apt-get update -qq 2>&1 | tail -n 1 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban ||
        fail "No se pudo instalar fail2ban."
else
    info "fail2ban ya está instalado."
fi
# Jail local: solo SSH, 5 intentos fallidos en 10 min -> baneo 1 hora.
mkdir -p /etc/fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
maxretry = 5
findtime = 600
bantime = 3600
EOF
systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || systemctl start fail2ban 2>/dev/null || true
sleep 1
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "Fail2Ban activo. Estado SSH:"
    fail2ban-client status sshd 2>/dev/null | sed 's/^/  /' || true
else
    echo "  (Fail2Ban no quedó activo; revisa: journalctl -u fail2ban -n 30)"
fi

# --- BBR -----------------------------------------------------------------------
echo
info "=== BBR (control de congestión TCP, más velocidad) ==="
BBR_OK=0
if modprobe tcp_bbr 2>/dev/null; then
    BBR_OK=1
elif grep -q "tcp_bbr" /lib/modules/"$(uname -r)"/modules.builtin 2>/dev/null; then
    BBR_OK=1
fi
if [[ "$BBR_OK" == 1 ]]; then
    cat > /etc/sysctl.d/99-mustafa-bbr.conf <<'EOF'
# MUSTAFA: BBR para más velocidad y estabilidad del VPN.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p /etc/sysctl.d/99-mustafa-bbr.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true
    CUR="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    if [[ "$CUR" == "bbr" ]]; then
        ok "BBR activo (tcp_congestion_control=bbr, qdisc=fq)."
    else
        echo "  (BBR configurado en /etc/sysctl.d/99-mustafa-bbr.conf, pero el control actual es '$CUR'; se aplicará al reiniciar.)"
    fi
else
    echo "  Este kernel no trae el módulo tcp_bbr (pasa en contenedores y en"
    echo "  algunos kernels de VM). BBR NO se activó aquí; en un VPS Ubuntu"
    echo "  normal (AWS, etc.) sí está disponible y el instalador lo activa."
fi

# --- vnStat --------------------------------------------------------------------
echo
info "=== vnStat (tráfico por día/mes) ==="
if ! dpkg -s vnstat >/dev/null 2>&1; then
    info "Instalando vnstat ..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq vnstat ||
        fail "No se pudo instalar vnstat."
else
    info "vnstat ya está instalado."
fi
systemctl enable vnstat 2>/dev/null || true
systemctl restart vnstat 2>/dev/null || systemctl start vnstat 2>/dev/null || true
sleep 1
if systemctl is-active --quiet vnstat 2>/dev/null; then
    ok "vnStat activo. (Los datos empiezan a acumularse; consulta con: vnstat)"
else
    echo "  (vnStat no quedó activo; revisa: journalctl -u vnstat -n 30)"
fi

# --- Respaldo ------------------------------------------------------------------
echo
info "=== Respaldo (usuarios, keys y configuraciones) ==="
cat > "$BACKUP_BIN" <<'BACKUP_EOF'
#!/usr/bin/env bash
# MUSTAFA — Respaldo de usuarios SSH, keys y configuraciones.
# Uso: sudo mustafa-backup
# Guarda en /root/mustafa-backup-AAAAMMDD-HHMMSS.tar.gz (solo quedan los 5 últimos).
set -euo pipefail
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="/root/mustafa-backup-$STAMP.tar.gz"
PATHS=()
for p in /etc/mustafa /etc/passwd /etc/shadow /etc/group /etc/gshadow \
         /etc/ssh/sshd_config /usr/local/etc/xray \
         /etc/nginx/sites-available/mustafa /etc/nginx/sites-enabled/mustafa \
         /etc/hysteria2 /etc/chttp /etc/v2socks /etc/hcr \
         /etc/mustafa-ws /etc/stunnel /etc/fail2ban/jail.local \
         /etc/sysctl.d/99-mustafa-bbr.conf /opt/knightbot/session; do
    [[ -e "$p" ]] && PATHS+=("$p")
done
[[ "${#PATHS[@]}" -gt 0 ]] || { echo "Nada que respaldar."; exit 1; }
tar -czf "$OUT" "${PATHS[@]}" 2>/dev/null
chmod 600 "$OUT"
# Conservar solo los 5 respaldos más recientes.
ls -t /root/mustafa-backup-*.tar.gz 2>/dev/null | tail -n +6 | xargs -r rm -f
echo "Respaldo creado: $OUT ($(stat -c %s "$OUT") bytes)"
echo "Para descargarlo: scp root@<IP>:$OUT ."
BACKUP_EOF
chmod 755 "$BACKUP_BIN"
ok "Script de respaldo instalado en $BACKUP_BIN"
info "Creando el primer respaldo ..."
"$BACKUP_BIN" || echo "  (el respaldo falló; revisa el mensaje de arriba)"

echo
ok "Herramientas listas: Fail2Ban, BBR (si el kernel lo soporta), vnStat y respaldo."
info "  Ver baneos   : fail2ban-client status sshd"
info "  Ver BBR      : sysctl net.ipv4.tcp_congestion_control"
info "  Ver tráfico  : vnstat  (vnstat -d para diario, vnstat -m mensual)"
info "  Respaldar    : mustafa-backup"
