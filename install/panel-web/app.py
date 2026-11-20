#!/usr/bin/env python3
# =============================================================================
#  Panel web MUSTAFA — backend Flask
#  Cara web (glass + tarjetas) del instalador MUSTAFA (titlan/v2install).
#  Replica la lógica del menú bash `mustafa` y de los instaladores de
#  install/ — no inventa rutas ni comandos:
#    - SSH: usuarios uid>=1000, vencimiento con chage, bloqueo con passwd,
#      conectados con ps (sshd:), crear con useradd + chpasswd + chage.
#    - V2Ray: lee /usr/local/etc/xray/config.json; agregar UUID solo a los
#      inbounds del protocolo elegido; valida con `xray run -test` y
#      reinicia xray. Enlaces Reality/VMess-WS/VLESS-WS/XHTTP como en
#      v2ray_links del menú.
#    - Protocolos: ejecuta /etc/mustafa/install/<script>.sh (con la env
#      var de puerto) y --uninstall para quitar. CheckUser activa solo
#      su sidecar HTTPS :8443 (checkuser.sh ya lo hace).
#    - Herramientas: mismo mecanismo que herramientas_menu (respaldo
#      /usr/local/bin/mustafa-backup, vnstat, fail2ban-client, knightbot).
#
#  Sin base de datos. Solo Flask + stdlib. La contraseña del panel se
#  guarda como hash "sha256$<salt>$<hex>" en /etc/mustafa/panel/password.hash
#  (la crea el instalador; si no existe, el panel NO arranca). La clave
#  secreta de sesión está en /etc/mustafa/panel/secret.key (se genera
#  sola si no existe).
#
#  Uso:
#      PANEL_PORT=9090 python3 app.py
#  Variables de entorno (para pruebas; en producción usan el default):
#      PANEL_DIR, INSTALL_DIR, STATE_DIR, XRAY_CONF, XRAY_BIN, INFO_FILE
# =============================================================================

import base64
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import threading
import uuid as uuid_mod
from datetime import datetime
from functools import wraps

from flask import Flask, jsonify, request, send_file, session

# --- Rutas (con overrides por entorno para poder probar sin tocar el VPS) ---
PANEL_DIR = os.environ.get("PANEL_DIR", "/etc/mustafa/panel")
INSTALL_DIR = os.environ.get("INSTALL_DIR", "/etc/mustafa/install")
STATE_DIR = os.environ.get("STATE_DIR", "/etc/mustafa")
XRAY_CONF = os.environ.get("XRAY_CONF", "/usr/local/etc/xray/config.json")
XRAY_BIN = os.environ.get("XRAY_BIN", "/usr/local/bin/xray/xray")
INFO_FILE = os.environ.get("INFO_FILE", "/etc/mustafa/info")
PANEL_PORT = int(os.environ.get("PANEL_PORT", "9090"))
HERE = os.path.dirname(os.path.abspath(__file__))

PASSWORD_HASH_FILE = os.path.join(PANEL_DIR, "password.hash")
SECRET_KEY_FILE = os.path.join(PANEL_DIR, "secret.key")

# --- Contraseña del panel (hash "sha256$<salt>$<hex>") -------------------------
# hex = sha256(salt + password). El salt es aleatorio por contraseña.


def hash_password(password):
    """Devuelve el hash a guardar: sha256$<salt>$<hex>."""
    salt = secrets.token_hex(8)
    digest = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    return "sha256$%s$%s" % (salt, digest)


def verify_password(password, stored):
    """Comprueba una contraseña contra el hash guardado."""
    try:
        algo, salt, digest = stored.strip().split("$")
    except ValueError:
        return False
    if algo != "sha256":
        return False
    calc = hashlib.sha256((salt + password).encode("utf-8")).hexdigest()
    # Comparación en tiempo constante para no filtrar por timing.
    return secrets.compare_digest(calc, digest)


def load_password_hash():
    try:
        with open(PASSWORD_HASH_FILE) as f:
            return f.read().strip()
    except OSError:
        return None


def load_or_create_secret():
    """Lee la clave secreta de sesión; si no existe, la genera y la guarda."""
    try:
        with open(SECRET_KEY_FILE) as f:
            key = f.read().strip()
        if key:
            return key
    except OSError:
        pass
    key = secrets.token_hex(32)
    os.makedirs(PANEL_DIR, exist_ok=True)
    with open(SECRET_KEY_FILE, "w") as f:
        f.write(key)
    os.chmod(SECRET_KEY_FILE, 0o600)
    return key


# --- Utilidades de sistema ------------------------------------------------------


def run(cmd, timeout=30, input_text=None, env_extra=None):
    """Corre un comando y devuelve (rc, stdout, stderr). Nunca lanza excepción.

    Asegura que /usr/sbin y /sbin estén en el PATH (ahí viven useradd,
    chpasswd, chage, passwd, systemctl...), por si el panel se arranca
    con un PATH recortado.
    """
    env = dict(os.environ)
    path = env.get("PATH", "")
    for d in ("/usr/local/sbin", "/usr/sbin", "/sbin"):
        if d not in path.split(":"):
            path = d + ":" + path if path else d
    env["PATH"] = path
    if env_extra:
        env.update(env_extra)
    try:
        p = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout,
            input=input_text, env=env)
        return p.returncode, p.stdout or "", p.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", "tiempo agotado (%ss)" % timeout
    except FileNotFoundError:
        return 127, "", "comando no encontrado: %s" % cmd[0]
    except OSError as e:
        return 1, "", str(e)


def service_active(unit):
    """True si systemctl dice que la unidad está activa."""
    rc, _, _ = run(["systemctl", "is-active", "--quiet", unit], timeout=10)
    return rc == 0


def service_state(unit):
    """on / off / absent (igual que unit_state del menú: [ON]/[OFF]/[--])."""
    if service_active(unit):
        return "on"
    for base in ("/etc/systemd/system", "/lib/systemd/system",
                 "/usr/lib/systemd/system"):
        if (os.path.exists(os.path.join(base, unit + ".service")) or
                os.path.exists(os.path.join(base, unit + ".timer"))):
            return "off"
    return "absent"


def read_info(key):
    """Lee un valor de /etc/mustafa/info (formato clave=valor)."""
    try:
        with open(INFO_FILE) as f:
            for line in f:
                line = line.strip()
                if line.startswith(key + "="):
                    return line.split("=", 1)[1]
    except OSError:
        pass
    return ""


def get_domain():
    """Dominio de /etc/mustafo/domain; None si no hay o es sin-dominio."""
    try:
        with open(os.path.join(STATE_DIR, "domain")) as f:
            d = f.read().strip()
    except OSError:
        return None
    if not d or d in ("sin-dominio", "sin configurar"):
        return None
    return d


def get_ipv4():
    """IPv4 del VPS: hostname -I primero, si no curl -4 a ifconfig.me."""
    rc, out, _ = run(["hostname", "-I"], timeout=10)
    if rc == 0:
        for tok in out.split():
            # Solo IPv4 (con puntos, sin dos puntos).
            if "." in tok and ":" not in tok:
                return tok
    rc, out, _ = run(["curl", "-4", "-fsSL", "--max-time", "5",
                      "https://ifconfig.me"], timeout=10)
    if rc == 0 and out.strip():
        return out.strip()
    return "?"


def get_host():
    """Host para los enlaces: el dominio si hay, si no la IPv4."""
    return get_domain() or get_ipv4()


def uptime_str():
    """Tiempo encendido, legible (ej. 2d 3h 15m)."""
    try:
        with open("/proc/uptime") as f:
            secs = int(float(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        return "?"
    days, secs = divmod(secs, 86400)
    hours, secs = divmod(secs, 3600)
    mins, _ = divmod(secs, 60)
    if days:
        return "%dd %dh %dm" % (days, hours, mins)
    if hours:
        return "%dh %dm" % (hours, mins)
    return "%dm" % mins


# --- SSH (misma lógica que ssh_* del menú) --------------------------------------

USER_RE = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
PROTECTED_USERS = ("root", "ubuntu", "")


def ssh_users():
    """Usuarios del sistema con uid>=1000 (sin nobody, uid 65534)."""
    users = []
    try:
        with open("/etc/passwd") as f:
            for line in f:
                parts = line.rstrip("\n").split(":")
                if len(parts) < 3:
                    continue
                try:
                    uid = int(parts[2])
                except ValueError:
                    continue
                if uid >= 1000 and uid != 65534:
                    users.append(parts[0])
    except OSError:
        pass
    return sorted(users)


def user_exists(user):
    rc, _, _ = run(["id", user], timeout=10)
    return rc == 0


def ssh_expiry(user):
    """Vencimiento con chage -l (campo Account expires); 'nunca' si no tiene."""
    rc, out, _ = run(["chage", "-l", user], timeout=10)
    if rc != 0:
        return "nunca"
    for line in out.splitlines():
        if "Account expires" in line:
            val = line.split(":", 1)[1].strip()
            if not val or val.lower() == "never":
                return "nunca"
            return val
    return "nunca"


def ssh_locked(user):
    """True si passwd -S dice L (bloqueado)."""
    rc, out, _ = run(["passwd", "-S", user], timeout=10)
    if rc != 0:
        return False
    fields = out.split()
    return len(fields) >= 2 and fields[1] == "L"


def ssh_connected_set():
    """Usuarios distintos con sesión sshd: activa (sin root)."""
    rc, out, _ = run(["ps", "-eo", "user,comm"], timeout=10)
    connected = set()
    if rc == 0:
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 2 and parts[1].startswith("sshd:"):
                if parts[0] != "root":
                    connected.add(parts[0])
    return connected


def random_password():
    """12 caracteres hex, como el menú (9 bytes de /dev/urandom en hex)."""
    return secrets.token_hex(6)


def date_cmd(args):
    """Corre `date` con los argumentos dados; devuelve (rc, salida)."""
    return run(["date"] + args, timeout=10)


def ssh_create(user, password, days):
    """Crea el usuario: useradd + chpasswd + chage -E. Devuelve dict o error."""
    if not USER_RE.match(user):
        return None, "Nombre no válido (minúsculas, sin espacios, empieza con letra)."
    if user in PROTECTED_USERS:
        return None, "No se puede crear ese usuario."
    if user_exists(user):
        return None, "El usuario '%s' ya existe." % user
    if not password:
        password = random_password()
    if not isinstance(days, int) or days < 1 or days > 3650:
        return None, "Días no válidos (1-3650)."
    rc, exp, _ = date_cmd(["-d", "+%d days" % days, "+%Y-%m-%d"])
    if rc != 0:
        return None, "No se pudo calcular la fecha de vencimiento."
    exp = exp.strip()
    rc, _, err = run(["useradd", "-m", "-s", "/bin/bash", user], timeout=30)
    if rc != 0:
        return None, "No se pudo crear el usuario. %s" % err.strip()
    rc, _, err = run(["chpasswd"], timeout=15,
                     input_text="%s:%s\n" % (user, password))
    if rc != 0:
        return None, "No se pudo poner la contraseña. %s" % err.strip()
    rc, _, err = run(["chage", "-E", exp, user], timeout=15)
    if rc != 0:
        return None, "No se pudo poner el vencimiento. %s" % err.strip()
    return {"user": user, "password": password, "expiry": exp}, None


def ssh_delete(user):
    """Borra el usuario (pkill + userdel -r, o userdel si falla)."""
    if user in PROTECTED_USERS:
        return "No se puede remover ese usuario."
    if not user_exists(user):
        return "El usuario '%s' no existe." % user
    run(["pkill", "-u", user], timeout=10)
    rc, _, err = run(["userdel", "-r", user], timeout=30)
    if rc != 0:
        rc, _, err = run(["userdel", user], timeout=30)
        if rc != 0:
            return "No se pudo remover el usuario. %s" % err.strip()
    return None


def ssh_lock(user, action):
    """Bloquea (passwd -l) o desbloquea (passwd -u)."""
    if user in PROTECTED_USERS:
        return "No se puede modificar ese usuario."
    if not user_exists(user):
        return "El usuario '%s' no existe." % user
    if action == "lock":
        rc, _, err = run(["passwd", "-l", user], timeout=15)
        if rc != 0:
            return "No se pudo bloquear. %s" % err.strip()
    elif action == "unlock":
        rc, _, err = run(["passwd", "-u", user], timeout=15)
        if rc != 0:
            return "No se pudo desbloquear. %s" % err.strip()
    else:
        return "Acción no válida (lock|unlock)."
    return None


def ssh_renew(user, days):
    """Suma días al vencimiento (desde hoy si ya venció o no tenía)."""
    if user in PROTECTED_USERS:
        return None, "No se puede modificar ese usuario."
    if not user_exists(user):
        return None, "El usuario '%s' no existe." % user
    if not isinstance(days, int) or days < 1 or days > 3650:
        return None, "Días no válidos (1-3650)."
    cur = ssh_expiry(user)
    # Base: hoy si no tenía vencimiento o ya venció; si no, su vencimiento.
    base = None
    if cur in ("nunca", "never", ""):
        base = None
    else:
        rc, epoch, _ = date_cmd(["-d", cur, "+%s"])
        rc2, now, _ = date_cmd(["+%s"])
        if rc == 0 and rc2 == 0 and int(epoch.strip()) >= int(now.strip()):
            base = cur
    if base is None:
        rc, base, _ = date_cmd(["+%Y-%m-%d"])
        base = base.strip()
    rc, new, _ = date_cmd(["-d", "%s +%d days" % (base, days), "+%Y-%m-%d"])
    if rc != 0:
        return None, "No se pudo calcular el nuevo vencimiento."
    new = new.strip()
    rc, _, err = run(["chage", "-E", new, user], timeout=15)
    if rc != 0:
        return None, "No se pudo renovar. %s" % err.strip()
    return {"user": user, "expiry": new, "previous": cur}, None


def ssh_change_password(user, password):
    """Cambia la contraseña (vacía = aleatoria, como ssh_edit del menú)."""
    if user in PROTECTED_USERS:
        return None, "No se puede modificar ese usuario."
    if not user_exists(user):
        return None, "El usuario '%s' no existe." % user
    if not password:
        password = random_password()
    rc, _, err = run(["chpasswd"], timeout=15,
                     input_text="%s:%s\n" % (user, password))
    if rc != 0:
        return None, "No se pudo cambiar la contraseña. %s" % err.strip()
    return {"user": user, "password": password}, None


# --- V2Ray / Xray (misma lógica que v2ray_* del menú) ----------------------------

UUID_RE = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
    r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


def xray_load():
    """Carga la config de Xray; devuelve dict o None si no está instalado."""
    try:
        with open(XRAY_CONF) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def xray_save(cfg):
    """Guarda la config (con .bak previo) de forma atómica."""
    bak = XRAY_CONF + ".bak"
    try:
        shutil.copyfile(XRAY_CONF, bak)
    except OSError:
        pass
    tmp = XRAY_CONF + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
    os.replace(tmp, XRAY_CONF)


def xray_restore_backup():
    bak = XRAY_CONF + ".bak"
    if os.path.exists(bak):
        shutil.copyfile(bak, XRAY_CONF)


def xray_test():
    """`xray run -test -config <conf>`; True si la config es válida."""
    if not (XRAY_BIN and os.path.isfile(XRAY_BIN) and os.access(XRAY_BIN, os.X_OK)):
        return True  # Sin binario no se puede probar; no bloquear.
    rc, _, _ = run([XRAY_BIN, "run", "-test", "-config", XRAY_CONF], timeout=30)
    return rc == 0


def xray_restart():
    rc, _, err = run(["systemctl", "restart", "xray"], timeout=30)
    return rc == 0, err.strip()


def xray_uuids(cfg):
    """Todos los UUID (sin repetir) de los inbounds."""
    out = []
    for inbound in cfg.get("inbounds", []):
        for client in inbound.get("settings", {}).get("clients", []) or []:
            cid = client.get("id")
            if cid and cid not in out:
                out.append(cid)
    return out


def xray_uuid_protocols(cfg, target):
    """Protocolos donde existe un UUID: reality, ws, xhttp (como el menú)."""
    found = set()
    for inbound in cfg.get("inbounds", []):
        clients = inbound.get("settings", {}).get("clients", []) or []
        if not any(c.get("id") == target for c in clients):
            continue
        stream = inbound.get("streamSettings", {}) or {}
        if stream.get("security") == "reality":
            found.add("reality")
        elif stream.get("network") == "ws":
            found.add("ws")
        elif stream.get("network") == "xhttp":
            found.add("xhttp")
    return sorted(found)


def xray_reality_port(cfg):
    """Puerto del inbound VLESS + Reality (default 443)."""
    for inbound in cfg.get("inbounds", []):
        stream = inbound.get("streamSettings", {}) or {}
        if stream.get("security") == "reality":
            port = inbound.get("port")
            if port:
                return int(port)
    return 443


def build_links(target, host, cfg):
    """Enlaces del UUID, solo para los protocolos donde existe de verdad."""
    protocols = xray_uuid_protocols(cfg, target)
    links = {}
    if "reality" in protocols:
        pub = read_info("reality_public")
        sid = read_info("reality_shortid")
        # Sin claves Reality no se inventa el enlace: se omite.
        if pub and sid:
            rport = xray_reality_port(cfg)
            links["reality"] = (
                "vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision"
                "&security=reality&sni=www.microsoft.com&fp=chrome"
                "&pbk=%s&sid=%s#MUSTAFA-Reality"
                % (target, host, rport, pub, sid))
    if "ws" in protocols:
        vmess = {
            "v": "2", "ps": "MUSTAFA", "add": host, "port": "80",
            "id": target, "aid": "0", "net": "ws", "type": "none",
            "host": host, "path": "/vmess", "tls": "",
        }
        encoded = base64.b64encode(
            json.dumps(vmess, separators=(",", ":")).encode()).decode()
        links["vmess_ws"] = "vmess://" + encoded
        links["vless_ws"] = (
            "vless://%s@%s:80?encryption=none&security=none"
            "&type=ws&host=%s&path=%%2Fvless#MUSTAFA-WS"
            % (target, host, host))
    if "xhttp" in protocols:
        links["xhttp"] = (
            "vless://%s@%s:80?encryption=none&security=none"
            "&type=xhttp&host=%s&path=%%2Fxhttp#MUSTAFA-XHTTP"
            % (target, host, host))
    return protocols, links


def xray_add_uuid(cfg, target, protocol):
    """Agrega el UUID solo a los inbounds del protocolo elegido.

    Copia el primer cliente del inbound como plantilla (así el de Reality
    conserva su flow xtls-rprx-vision) y solo cambia el id; en Reality
    además fuerza el flow. Igual que los filtros jq de v2ray_add.
    """
    added = False
    for inbound in cfg.get("inbounds", []):
        stream = inbound.get("streamSettings", {}) or {}
        settings = inbound.setdefault("settings", {})
        clients = settings.setdefault("clients", [])
        if protocol == "reality":
            match = stream.get("security") == "reality"
        elif protocol == "ws":
            match = stream.get("network") == "ws"
        elif protocol == "xhttp":
            match = stream.get("network") == "xhttp"
        else:  # todos: cualquier inbound que ya tenga clientes
            match = len(clients) > 0
        if not match:
            continue
        template = dict(clients[0]) if clients else {}
        new_client = dict(template)
        new_client["id"] = target
        if protocol == "reality":
            new_client["flow"] = "xtls-rprx-vision"
        clients.append(new_client)
        added = True
    return added


def xray_del_uuid(cfg, target):
    """Quita el UUID de todos los inbounds."""
    for inbound in cfg.get("inbounds", []):
        clients = inbound.get("settings", {}).get("clients", []) or []
        inbound["settings"]["clients"] = [
            c for c in clients if c.get("id") != target]


# --- Protocolos (misma tabla que proto_menu del menú) -----------------------------

PROTOCOLS = [
    # key, nombre, script, unidad systemd, puerto default, env var, tiene puerto
    ("badvpn", "BadVPN", "badvpn.sh", "badvpn", 7300, "BADVPN_PORT", True),
    ("stunnel4", "Stunnel4", "stunnel4.sh", "stunnel4", 443, "STUNNEL_PORT", True),
    ("hcr", "HCR", "hcr.sh", "hcr-server", 8080, "HCR_PORT", True),
    ("chttp", "CHTTP", "chttp.sh", "chttp", 8445, "CHTTP_PORT", True),
    ("v2socks", "V2SOCKS", "v2socks.sh", "v2socks", 8444, "V2SOCKS_PORT", True),
    ("mustafa-ws", "mustafa-ws", "mustafa-ws.sh", "mustafa-ws", 444, "WS_PORT", True),
    ("checkuser", "CheckUser", "checkuser.sh", "checkuser", 8888, "CHECKUSER_PORT", True),
    ("monitor", "Monitor App", "monitor.sh", "monitor-mustafa.timer", None, None, False),
    ("hysteria2", "Hysteria2", "hysteria2.sh", "hysteria2", 443, "HYSTERIA2_PORT", True),
    ("wsplus", "WSPLUS", "wsplus.sh", "wsplus", 8081, "WSPLUS_PORT", True),
    ("doh", "DOH", "doh.sh", "doh", 8053, "DOH_PORT", True),
]
PROTO_BY_KEY = {p[0]: p for p in PROTOCOLS}

# Expresiones para leer el puerto de la config/servicio de cada protocolo
# (mismo orden que proto_port del menú: primero /etc/mustafa/ports/<clave>).
PROTO_PORT_PATTERNS = {
    "badvpn": ("/etc/systemd/system/badvpn.service",
               r"--listen-addr 127\.0\.0\.1:(\d+)"),
    "stunnel4": ("/etc/stunnel/stunnel.conf", r"^accept\s*=\s*(\d+)"),
    "hcr": ("/etc/systemd/system/hcr-server.service", r"-listen :(\d+)"),
    "chttp": ("/etc/systemd/system/chttp.service", r"--addr :(\d+)"),
    "v2socks": ("/etc/systemd/system/v2socks.service",
                r"--signal-addr :(\d+)"),
    "mustafa-ws": ("/etc/mustafa-ws/config", r"^LISTEN=.*:(\d+)\s*$"),
    "checkuser": ("/etc/systemd/system/checkuser.service",
                  r"^Environment=CHECKUSER_PORT=(\d+)"),
    "hysteria2": ("/etc/hysteria2/config.yaml", r"^listen: :(\d+)"),
    "wsplus": ("/etc/systemd/system/wsplus.service", r"--listen :(\d+)"),
    "doh": ("/etc/systemd/system/doh.service", r"--listen :(\d+)"),
}


def proto_port(key, default):
    """Puerto actual del protocolo (archivo de estado, config o default)."""
    state_file = os.path.join(STATE_DIR, "ports", key)
    try:
        with open(state_file) as f:
            val = f.read().strip()
        if val.isdigit():
            return int(val)
    except OSError:
        pass
    pattern = PROTO_PORT_PATTERNS.get(key)
    if pattern:
        path, regex = pattern
        try:
            with open(path) as f:
                content = f.read()
            m = re.search(regex, content, re.MULTILINE)
            if m:
                return int(m.group(1))
        except OSError:
            pass
    if key == "stunnel4":
        # Sin nada instalado: 443 libre / 4443 si Xray lo ocupa (como el menú).
        rc, out, _ = run(["ss", "-tln"], timeout=10)
        if rc == 0:
            for line in out.splitlines():
                fields = line.split()
                if len(fields) >= 4 and fields[3].endswith(":443"):
                    return 4443
        return 443
    return default


def run_installer(script, args=None, env_extra=None, timeout=180):
    """Corre un instalador de /etc/mustafa/install/ y devuelve (rc, salida)."""
    path = os.path.join(INSTALL_DIR, script)
    if not os.path.isfile(path):
        return None, ("No está el instalador %s.\nReinstala el menú con "
                      "install.sh (copia install/ a /etc/mustafa/install/)."
                      % path)
    cmd = ["bash", path] + (args or [])
    rc, out, err = run(cmd, timeout=timeout, env_extra=env_extra)
    output = (out or "") + (("\n" + err) if err else "")
    return rc, output


# --- Respaldo (mismo mecanismo que herramientas.sh) -------------------------------
# /usr/local/bin/mustafa-backup guarda en /root/mustafa-backup-*.tar.gz y
# conserva solo los 5 últimos. Si no está instalado, se hace el tar aquí
# con la misma lista de rutas.
BACKUP_BIN = "/usr/local/bin/mustafa-backup"
BACKUP_PATHS = [
    "/etc/mustafa", "/etc/passwd", "/etc/shadow", "/etc/group",
    "/etc/gshadow", "/etc/ssh/sshd_config", "/usr/local/etc/xray",
    "/etc/nginx/sites-available/mustafa", "/etc/nginx/sites-enabled/mustafa",
    "/etc/hysteria2", "/etc/chttp", "/etc/v2socks", "/etc/hcr",
    "/etc/mustafa-ws", "/etc/stunnel", "/etc/fail2ban/jail.local",
    "/etc/sysctl.d/99-mustafa-bbr.conf", "/opt/knightbot/session",
]


def do_backup():
    """Crea el respaldo; devuelve (ok, mensaje)."""
    if os.path.isfile(BACKUP_BIN) and os.access(BACKUP_BIN, os.X_OK):
        rc, out, err = run([BACKUP_BIN], timeout=120)
        msg = (out or "") + (("\n" + err) if err else "")
        return rc == 0, msg.strip() or "Respaldo creado."
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    out_path = "/root/mustafa-backup-%s.tar.gz" % stamp
    paths = [p for p in BACKUP_PATHS if os.path.exists(p)]
    if not paths:
        return False, "Nada que respaldar."
    rc, _, err = run(["tar", "-czf", out_path] + paths, timeout=120)
    if rc != 0:
        return False, "El respaldo falló. %s" % err.strip()
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    # Conservar solo los 5 respaldos más recientes.
    try:
        backups = sorted(
            (os.path.join("/root", f) for f in os.listdir("/root")
             if f.startswith("mustafa-backup-") and f.endswith(".tar.gz")),
            key=lambda p: os.path.getmtime(p), reverse=True)
        for old in backups[5:]:
            os.remove(old)
    except OSError:
        pass
    size = os.path.getsize(out_path) if os.path.exists(out_path) else 0
    return True, "Respaldo creado: %s (%d bytes)" % (out_path, size)


def last_backup():
    """Nombre del último respaldo, o None si no hay ninguno."""
    try:
        backups = sorted(
            (f for f in os.listdir("/root")
             if f.startswith("mustafa-backup-") and f.endswith(".tar.gz")),
            key=lambda f: os.path.getmtime(os.path.join("/root", f)),
            reverse=True)
        return backups[0] if backups else None
    except OSError:
        return None


# --- Flask ------------------------------------------------------------------------

app = Flask(__name__)
app.config["JSON_AS_ASCII"] = False


def login_required(f):
    """Todos los /api/* salvo /api/login exigen sesión."""
    @wraps(f)
    def wrapper(*args, **kwargs):
        if not session.get("logged_in"):
            return jsonify({"error": "No has iniciado sesión."}), 401
        return f(*args, **kwargs)
    return wrapper


def err(message, code=400):
    return jsonify({"error": message}), code


@app.route("/")
def index():
    return send_file(os.path.join(HERE, "index.html"))


@app.route("/api/login", methods=["POST"])
def api_login():
    data = request.get_json(silent=True) or {}
    password = data.get("password", "")
    stored = load_password_hash()
    if stored is None:
        return err("El panel no tiene contraseña configurada "
                   "(falta /etc/mustafa/panel/password.hash).", 500)
    if not password or not verify_password(password, stored):
        return err("Contraseña incorrecta.", 401)
    session["logged_in"] = True
    return jsonify({"ok": True})


@app.route("/api/logout", methods=["POST"])
@login_required
def api_logout():
    session.clear()
    return jsonify({"ok": True})


@app.route("/api/status", methods=["GET"])
@login_required
def api_status():
    users = ssh_users()
    connected = ssh_connected_set()
    return jsonify({
        "users_total": len(users),
        "users_connected": len(connected),
        "services": {
            "nginx": service_state("nginx"),
            "xray": service_state("xray"),
            "checkuser": service_state("checkuser"),
            "panel": service_state("panel-web"),
        },
        "uptime": uptime_str(),
        "domain": get_domain() or "sin dominio",
        "ipv4": get_ipv4(),
        "https8443": service_state("checkuser-https"),
    })


# --- SSH --------------------------------------------------------------------------


@app.route("/api/ssh/users", methods=["GET"])
@login_required
def api_ssh_users():
    connected = ssh_connected_set()
    out = []
    for user in ssh_users():
        out.append({
            "user": user,
            "expiry": ssh_expiry(user),
            "locked": ssh_locked(user),
            "connected": user in connected,
        })
    return jsonify(out)


@app.route("/api/ssh/create", methods=["POST"])
@login_required
def api_ssh_create():
    data = request.get_json(silent=True) or {}
    user = (data.get("user") or "").strip()
    password = data.get("password") or ""
    days = data.get("days", 30)
    try:
        days = int(days)
    except (TypeError, ValueError):
        return err("Días no válidos.")
    result, error = ssh_create(user, password, days)
    if error:
        return err(error)
    return jsonify(result)


@app.route("/api/ssh/delete", methods=["POST"])
@login_required
def api_ssh_delete():
    data = request.get_json(silent=True) or {}
    user = (data.get("user") or "").strip()
    if not user:
        return err("Falta el usuario.")
    error = ssh_delete(user)
    if error:
        return err(error)
    return jsonify({"ok": True, "user": user})


@app.route("/api/ssh/lock", methods=["POST"])
@login_required
def api_ssh_lock():
    data = request.get_json(silent=True) or {}
    user = (data.get("user") or "").strip()
    action = (data.get("action") or "").strip()
    if not user:
        return err("Falta el usuario.")
    error = ssh_lock(user, action)
    if error:
        return err(error)
    return jsonify({"ok": True, "user": user,
                    "locked": action == "lock"})


@app.route("/api/ssh/renew", methods=["POST"])
@login_required
def api_ssh_renew():
    data = request.get_json(silent=True) or {}
    user = (data.get("user") or "").strip()
    days = data.get("days")
    try:
        days = int(days)
    except (TypeError, ValueError):
        return err("Días no válidos.")
    result, error = ssh_renew(user, days)
    if error:
        return err(error)
    return jsonify(result)


@app.route("/api/ssh/password", methods=["POST"])
@login_required
def api_ssh_password():
    data = request.get_json(silent=True) or {}
    user = (data.get("user") or "").strip()
    password = data.get("password") or ""
    result, error = ssh_change_password(user, password)
    if error:
        return err(error)
    return jsonify(result)


# --- V2Ray ------------------------------------------------------------------------


@app.route("/api/v2ray/accounts", methods=["GET"])
@login_required
def api_v2ray_accounts():
    cfg = xray_load()
    if cfg is None:
        return err("Xray no está instalado (falta %s)." % XRAY_CONF, 404)
    host = get_host()
    principal = read_info("xray_uuid")
    out = []
    for target in xray_uuids(cfg):
        protocols, links = build_links(target, host, cfg)
        out.append({
            "uuid": target,
            "principal": target == principal,
            "protocols": protocols,
            "links": links,
        })
    return jsonify(out)


@app.route("/api/v2ray/add", methods=["POST"])
@login_required
def api_v2ray_add():
    data = request.get_json(silent=True) or {}
    protocol = (data.get("protocol") or "todos").strip()
    if protocol not in ("todos", "reality", "ws", "xhttp"):
        return err("Protocolo no válido (todos|reality|ws|xhttp).")
    cfg = xray_load()
    if cfg is None:
        return err("Xray no está instalado (falta %s)." % XRAY_CONF, 404)
    target = str(uuid_mod.uuid4())
    if not xray_add_uuid(cfg, target, protocol):
        return err("El usuario no se agregó: el inbound de %s no existe "
                   "en la config. (Si falta XHTTP, instala V2Ray de nuevo "
                   "para migrar la config.)" % protocol)
    xray_save(cfg)
    if not xray_test():
        xray_restore_backup()
        return err("La configuración nueva no pasó la prueba de Xray; "
                   "se restauró la anterior.", 500)
    ok, err_restart = xray_restart()
    if not ok:
        return err("El usuario se agregó pero no se pudo reiniciar xray: %s"
                   % err_restart, 500)
    host = get_host()
    protocols, links = build_links(target, host, cfg)
    return jsonify({"uuid": target, "protocol": protocol,
                    "protocols": protocols, "links": links})


@app.route("/api/v2ray/delete", methods=["POST"])
@login_required
def api_v2ray_delete():
    data = request.get_json(silent=True) or {}
    target = (data.get("uuid") or "").strip()
    if not UUID_RE.match(target):
        return err("UUID no válido.")
    cfg = xray_load()
    if cfg is None:
        return err("Xray no está instalado (falta %s)." % XRAY_CONF, 404)
    if target not in xray_uuids(cfg):
        return err("Ese UUID no existe en la configuración.")
    xray_del_uuid(cfg, target)
    xray_save(cfg)
    if not xray_test():
        xray_restore_backup()
        return err("La configuración nueva no pasó la prueba de Xray; "
                   "se restauró la anterior.", 500)
    ok, err_restart = xray_restart()
    if not ok:
        return err("El UUID se eliminó pero no se pudo reiniciar xray: %s"
                   % err_restart, 500)
    return jsonify({"ok": True, "uuid": target})


@app.route("/api/v2ray/restart", methods=["POST"])
@login_required
def api_v2ray_restart():
    ok, err_restart = xray_restart()
    if not ok:
        return err("No se pudo reiniciar xray. %s" % err_restart, 500)
    return jsonify({"ok": True, "active": service_active("xray")})


@app.route("/api/v2ray/status", methods=["GET"])
@login_required
def api_v2ray_status():
    cfg = xray_load()
    if cfg is None:
        return jsonify({"active": False, "reality_port": 443,
                        "installed": False})
    return jsonify({"active": service_active("xray"),
                    "reality_port": xray_reality_port(cfg),
                    "installed": True})


# --- Protocolos -------------------------------------------------------------------


@app.route("/api/protocols", methods=["GET"])
@login_required
def api_protocols():
    out = []
    for key, name, script, unit, default, envvar, has_port in PROTOCOLS:
        item = {
            "key": key,
            "name": name,
            "port": proto_port(key, default) if has_port else None,
            "active": service_state(unit),
        }
        if key == "checkuser":
            item["https8443"] = service_state("checkuser-https")
        out.append(item)
    return jsonify(out)


@app.route("/api/protocols/install", methods=["POST"])
@login_required
def api_protocols_install():
    data = request.get_json(silent=True) or {}
    key = (data.get("key") or "").strip()
    proto = PROTO_BY_KEY.get(key)
    if proto is None:
        return err("Protocolo desconocido: %s" % key)
    _, name, script, _, default, envvar, has_port = proto
    port = data.get("port")
    if has_port:
        if port is None or port == "":
            port = proto_port(key, default)
        try:
            port = int(port)
        except (TypeError, ValueError):
            return err("Puerto no válido.")
        if port < 1 or port > 65535:
            return err("Puerto no válido (1-65535).")
    env_extra = None
    args = []
    if has_port and envvar:
        env_extra = {envvar: str(port)}
    rc, output = run_installer(script, args=args, env_extra=env_extra)
    if rc is None:
        return err(output, 404)
    return jsonify({"ok": rc == 0, "output": output})


@app.route("/api/protocols/uninstall", methods=["POST"])
@login_required
def api_protocols_uninstall():
    data = request.get_json(silent=True) or {}
    key = (data.get("key") or "").strip()
    proto = PROTO_BY_KEY.get(key)
    if proto is None:
        return err("Protocolo desconocido: %s" % key)
    _, name, script, _, _, _, _ = proto
    rc, output = run_installer(script, args=["--uninstall"])
    if rc is None:
        return err(output, 404)
    try:
        os.remove(os.path.join(STATE_DIR, "ports", key))
    except OSError:
        pass
    return jsonify({"ok": rc == 0, "output": output})


# --- Herramientas -----------------------------------------------------------------


@app.route("/api/tools/status", methods=["GET"])
@login_required
def api_tools_status():
    rc, bbr, _ = run(["sysctl", "-n", "net.ipv4.tcp_congestion_control"],
                     timeout=10)
    return jsonify({
        "fail2ban": service_state("fail2ban"),
        "bbr": bbr.strip() if rc == 0 and bbr.strip() else "?",
        "vnstat": service_state("vnstat"),
        "backup": last_backup(),
        "bot": service_state("knightbot"),
    })


@app.route("/api/tools/backup", methods=["POST"])
@login_required
def api_tools_backup():
    ok, msg = do_backup()
    if not ok:
        return err(msg, 500)
    return jsonify({"ok": True, "output": msg})


@app.route("/api/tools/traffic", methods=["GET"])
@login_required
def api_tools_traffic():
    rc, out, stderr = run(["vnstat"], timeout=30)
    if rc != 0:
        return err("vnStat no está instalado o no respondió. %s"
                   % stderr.strip(), 404)
    return jsonify({"output": out})


@app.route("/api/tools/bans", methods=["GET"])
@login_required
def api_tools_bans():
    rc, out, stderr = run(["fail2ban-client", "status", "sshd"], timeout=30)
    if rc != 0:
        return err("Fail2Ban no está instalado o no respondió. %s"
                   % stderr.strip(), 404)
    return jsonify({"output": out})


@app.route("/api/panel/change-password", methods=["POST"])
@login_required
def api_panel_change_password():
    data = request.get_json(silent=True) or {}
    password = data.get("password") or ""
    if len(password) < 4:
        return err("La contraseña debe tener al menos 4 caracteres.")
    new_hash = hash_password(password)
    try:
        os.makedirs(PANEL_DIR, exist_ok=True)
        tmp = PASSWORD_HASH_FILE + ".tmp"
        with open(tmp, "w") as f:
            f.write(new_hash + "\n")
        os.replace(tmp, PASSWORD_HASH_FILE)
        os.chmod(PASSWORD_HASH_FILE, 0o600)
    except OSError as e:
        return err("No se pudo guardar la contraseña. %s" % e, 500)
    return jsonify({"ok": True})


@app.route("/api/panel/restart", methods=["POST"])
@login_required
def api_panel_restart():
    # Reiniciar con un pequeño retraso para que la respuesta llegue antes
    # de que systemd mate este proceso.
    def _restart():
        run(["systemctl", "restart", "panel-web"], timeout=30)
    threading.Timer(1.0, _restart).start()
    return jsonify({"ok": True})


# --- Arranque -----------------------------------------------------------------------


def main():
    stored = load_password_hash()
    if stored is None:
        print("ERROR: el panel no tiene contraseña configurada.", file=sys.stderr)
        print("Falta %s." % PASSWORD_HASH_FILE, file=sys.stderr)
        print("Créala con este comando (te pedirá la contraseña):", file=sys.stderr)
        cmd = ("python3 -c \"import hashlib,secrets; s=secrets.token_hex(8); "
               "print('sha256$%s$%s' % (s, hashlib.sha256((s+input('Contrasena: '))"
               ".encode()).hexdigest()))\" > " + PASSWORD_HASH_FILE)
        print("  " + cmd, file=sys.stderr)
        print("O reinstala el panel con su instalador (panel-web.sh).", file=sys.stderr)
        print("El panel NO arranca sin contraseña (nunca con login abierto).",
              file=sys.stderr)
        sys.exit(1)
    app.secret_key = load_or_create_secret()
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        PERMANENT_SESSION_LIFETIME=86400,
    )
    print("Panel web MUSTAFA en http://0.0.0.0:%d/ (puerto %d)"
          % (PANEL_PORT, PANEL_PORT))
    app.run(host="0.0.0.0", port=PANEL_PORT)


if __name__ == "__main__":
    main()
