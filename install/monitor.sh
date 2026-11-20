#!/usr/bin/env bash
# =============================================================================
#  MUSTAFA — Instalador de la Monitor App
#  Instala el vigilante de servicios MUSTAFA (código original, escrito
#  desde cero para este instalador):
#
#    - Motor /usr/local/bin/monitor-mustafa.sh, ejecutado por un timer
#      systemd cada 60 s: revisa los servicios MUSTAFA instalados, reinicia
#      los que están caídos, registra eventos y regenera el panel web.
#    - Panel web en /var/www/html/monitor.html (lo sirve Nginx en el
#      puerto 80): CPU/RAM/disco, tabla de servicios y últimos eventos.
#
#  Uso: sudo bash monitor.sh
#  Idempotente: se puede volver a ejecutar; actualiza archivos y timer
#  sin duplicar nada.
# =============================================================================

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[ERROR] Ejecuta como root (sudo bash monitor.sh)"; exit 1; }
command -v systemctl >/dev/null 2>&1 || { echo "[ERROR] Este instalador necesita systemd (systemctl no encontrado)"; exit 1; }

ENGINE="/usr/local/bin/monitor-mustafa.sh"
SERVICE="/etc/systemd/system/monitor-mustafa.service"
TIMER="/etc/systemd/system/monitor-mustafa.timer"
LOG_FILE="/var/log/monitor-mustafa.log"
HTML_FILE="/var/www/html/monitor.html"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
ok()   { echo "[$(date '+%H:%M:%S')] [OK] $*"; }
warn() { echo "[$(date '+%H:%M:%S')] [AVISO] $*" >&2; }

# --- Desinstalar ---------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Desinstalando Monitor App..."
    systemctl stop monitor-mustafa.timer monitor-mustafa.service 2>/dev/null || true
    systemctl disable monitor-mustafa.timer monitor-mustafa.service 2>/dev/null || true
    rm -f "$SERVICE" "$TIMER" "$ENGINE" "$HTML_FILE"
    systemctl daemon-reload 2>/dev/null || true
    ok "Monitor App desinstalada (timer, motor y panel eliminados; el log $LOG_FILE se conserva)."
    exit 0
fi

# Servicios que vigila el motor, con su puerto informativo.
# (stunnel4 usa 443 si está libre y 4443 si Xray ya ocupa el 443.)
SERVICES=(
    "nginx:80"
    "xray:443"
    "ssh:22"
    "mustafa-ws:444"
    "badvpn:7300 UDP"
    "stunnel4:443/4443"
    "hcr-server:8080"
    "chttp:8445"
    "v2socks-server:8444"
    "checkuser:80"
)

# =============================================================================
#  1. Motor de supervisión
# =============================================================================
log "Escribiendo el motor en $ENGINE ..."
cat > "$ENGINE" <<'MONITOR_EOF'
#!/usr/bin/env bash
# =============================================================================
#  Monitor MUSTAFA — motor de supervisión (código original MUSTAFA)
#  Lo ejecuta el timer monitor-mustafa.timer cada 60 s.
#    - Revisa los servicios MUSTAFA instalados; reinicia los caídos y
#      registra el resultado en /var/log/monitor-mustafa.log.
#    - Nunca toca servicios que no están instalados.
#    - Guarda CPU/RAM/disco/uptime y regenera /var/www/html/monitor.html.
# =============================================================================

set -u

LOG_FILE="/var/log/monitor-mustafa.log"
HTML_FILE="/var/www/html/monitor.html"
HTML_DIR="$(dirname "$HTML_FILE")"

# servicio:puerto (el puerto es informativo; stunnel4 usa 443 o 4443)
SERVICES=(
    "nginx:80"
    "xray:443"
    "ssh:22"
    "mustafa-ws:444"
    "badvpn:7300 UDP"
    "stunnel4:443/4443"
    "hcr-server:8080"
    "chttp:8445"
    "v2socks-server:8444"
    "checkuser:80"
)

log_event() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

esc_html() {
    sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Uso de CPU en % (dos lecturas de /proc/stat con 0.5 s de diferencia)
get_cpu_pct() {
    local total_a idle_a total_b idle_b total_d idle_d
    read -r total_a idle_a < <(awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat) \
        || { echo 0; return; }
    sleep 0.5
    read -r total_b idle_b < <(awk '/^cpu / {t=0; for(i=2;i<=NF;i++) t+=$i; print t, $5}' /proc/stat) \
        || { echo 0; return; }
    total_d=$((total_b - total_a)); idle_d=$((idle_b - idle_a))
    [[ $total_d -gt 0 ]] || { echo 0; return; }
    echo $(( (100 * (total_d - idle_d)) / total_d ))
}

mkdir -p "$HTML_DIR"
touch "$LOG_FILE"

CPU_PCT="$(get_cpu_pct)"
RAM_PCT="$(free 2>/dev/null | awk '/^Mem:/ {printf "%.0f", $3/$2*100}')"
RAM_PCT="${RAM_PCT:-0}"
DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
DISK_PCT="${DISK_PCT:-0}"
UPTIME="$(uptime -p 2>/dev/null | sed 's/^up //' || echo "?")"
NOW="$(date '+%Y-%m-%d %H:%M:%S')"

# --- Revisión de servicios ----------------------------------------------------
ROWS=""
WATCHED=0
for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    port="${entry#*:}"
    if ! command -v systemctl >/dev/null 2>&1; then
        status="—"; cls="off"
    elif ! systemctl cat "$svc" >/dev/null 2>&1; then
        # Unidad inexistente = servicio no instalado: no se toca ni se muestra.
        continue
    else
        WATCHED=$((WATCHED + 1))
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="ON"; cls="on"
        else
            log_event "Servicio caído: $svc — intentando reiniciar..."
            if systemctl restart "$svc" 2>/dev/null \
                && systemctl is-active --quiet "$svc" 2>/dev/null; then
                status="ON"; cls="on"
                log_event "Servicio recuperado: $svc"
            else
                status="OFF"; cls="off"
                log_event "Servicio NO recuperado: $svc (sigue inactivo tras reiniciar)"
            fi
        fi
    fi
    ROWS+="        <tr><td>${svc}</td><td class=\"${cls}\">${status}</td><td>${port}</td></tr>"$'\n'
done

log_event "Revisión completada: $WATCHED servicios vigilados, CPU ${CPU_PCT}%, RAM ${RAM_PCT}%, disco ${DISK_PCT}%."

# El log no crece sin límite: se recorta a las últimas 500 líneas
# (se reescribe en el mismo archivo para no romper el descriptor que
# systemd tiene abierto).
if [[ -f "$LOG_FILE" ]] && [[ "$(wc -l < "$LOG_FILE")" -gt 1000 ]]; then
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && cat "${LOG_FILE}.tmp" > "$LOG_FILE"
    rm -f "${LOG_FILE}.tmp"
fi

EVENTS="$(tail -n 20 "$LOG_FILE" 2>/dev/null | esc_html)"

# --- Panel web ----------------------------------------------------------------
TMP_HTML="${HTML_FILE}.tmp"
cat > "$TMP_HTML" <<HTML
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>Monitor MUSTAFA</title>
<style>
* {box-sizing:border-box}
body {margin:0;padding:18px;background:#0b1220;color:#e5edf7;font-family:Arial,sans-serif}
header {background:#152238;padding:20px;border-radius:14px;border-left:5px solid #00c8ff;margin-bottom:20px}
h1 {margin:0;color:#00c8ff}
h2 {color:#62d9ff;font-size:18px}
.fecha {color:#9fb2c9;font-size:13px}
.grid {display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:14px}
.card {background:#152238;padding:18px;border-radius:12px;border:1px solid #253851}
.card h3 {margin-top:0;color:#9fb2c9;font-size:14px}
.valor {font-size:27px;font-weight:bold;color:#fff}
.sub {color:#8da4bd;font-size:13px;margin-top:8px}
.barra {height:9px;background:#26364c;border-radius:10px;overflow:hidden;margin-top:12px}
.progreso {height:100%;background:#00c8ff}
.seccion {background:#152238;padding:18px;border-radius:12px;margin-top:18px;overflow:hidden}
table {width:100%;border-collapse:collapse}
td,th {padding:11px 8px;border-bottom:1px solid #293c54;text-align:left;font-size:14px}
.on {color:#3ddc84;font-weight:bold}
.off {color:#ff5c5c;font-weight:bold}
pre {background:#0b1220;border:1px solid #253851;border-radius:8px;padding:12px;overflow:auto;font-size:13px;color:#c7d6e8}
</style>
</head>
<body>
<header>
<h1>Monitor MUSTAFA</h1>
<p class="fecha">Última revisión: ${NOW} — revisión cada 60 s</p>
</header>
<div class="grid">
<div class="card"><h3>CPU</h3><div class="valor">${CPU_PCT}%</div><div class="barra"><div class="progreso" style="width:${CPU_PCT}%"></div></div></div>
<div class="card"><h3>RAM</h3><div class="valor">${RAM_PCT}%</div><div class="barra"><div class="progreso" style="width:${RAM_PCT}%"></div></div></div>
<div class="card"><h3>Disco</h3><div class="valor">${DISK_PCT}%</div><div class="barra"><div class="progreso" style="width:${DISK_PCT}%"></div></div></div>
<div class="card"><h3>Uptime</h3><div class="valor" style="font-size:20px">${UPTIME}</div><div class="sub">Servicios vigilados: ${WATCHED}</div></div>
</div>
<div class="seccion">
<h2>Servicios</h2>
<table>
<tr><th>Servicio</th><th>Estado</th><th>Puerto</th></tr>
${ROWS}</table>
</div>
<div class="seccion">
<h2>Últimos eventos</h2>
<pre>${EVENTS}</pre>
</div>
</body>
</html>
HTML
mv "$TMP_HTML" "$HTML_FILE"

echo "Monitor MUSTAFA: revisión $NOW — $WATCHED servicios vigilados."
MONITOR_EOF
chmod 755 "$ENGINE"
ok "Motor instalado en $ENGINE"

# =============================================================================
#  2. Unidades systemd (servicio oneshot + timer cada 60 s)
# =============================================================================
log "Escribiendo unidades systemd ..."
cat > "$SERVICE" <<'EOF'
[Unit]
Description=Monitor MUSTAFA - Motor de supervision
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/monitor-mustafa.sh
StandardOutput=append:/var/log/monitor-mustafa.log
StandardError=append:/var/log/monitor-mustafa.log
TimeoutStartSec=120
Nice=10
EOF

cat > "$TIMER" <<'EOF'
[Unit]
Description=Temporizador de Monitor MUSTAFA

[Timer]
OnBootSec=30s
OnUnitInactiveSec=60s
AccuracySec=5s
Unit=monitor-mustafa.service

[Install]
WantedBy=timers.target
EOF
ok "Unidades escritas: $SERVICE y $TIMER"

systemctl daemon-reload
systemctl enable --now monitor-mustafa.timer
ok "Timer activado (revisión cada 60 s)"

# =============================================================================
#  3. Primera ejecución del motor
# =============================================================================
mkdir -p "$(dirname "$HTML_FILE")"
touch "$LOG_FILE"
if "$ENGINE"; then
    ok "Primera revisión completada, panel generado en $HTML_FILE"
else
    warn "La primera ejecución del motor devolvió un error; revisa $LOG_FILE (el timer reintentará en 60 s)."
fi

if ! systemctl cat nginx >/dev/null 2>&1; then
    warn "Nginx no está instalado en este VPS: el archivo $HTML_FILE existe, pero no se sirve por web hasta instalar Nginx."
fi

# =============================================================================
#  Resumen
# =============================================================================
IPV4="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo
echo "============================== MONITOR MUSTAFA =============================="
echo "  Panel   : http://${IPV4:-<IP>}/monitor.html"
echo "  Timer   : $(systemctl is-active monitor-mustafa.timer 2>/dev/null || echo "desconocido") (cada 60 s)"
echo "  Motor   : $ENGINE"
echo "  Log     : $LOG_FILE"
echo "  Servicios vigilados:"
for entry in "${SERVICES[@]}"; do
    svc="${entry%%:*}"
    port="${entry#*:}"
    if systemctl cat "$svc" >/dev/null 2>&1; then
        echo "    - $svc (puerto $port) : $(systemctl is-active "$svc" 2>/dev/null || echo "inactivo")"
    fi
done
echo "=============================================================================="
ok "Monitor App instalada."
