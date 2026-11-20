#!/usr/bin/env python3
# checkUser para MUSTAFA - igual que el de Enigma
# Escucha en loopback (127.0.0.1:8888 por defecto) y Nginx lo publica en
# el puerto 80 con /checkUser y /server/online. El :80 directo NO se
# puede usar: en una VPS MUSTAFA Nginx ya ocupa el 80 y el servicio no
# arrancaría (Address already in use).
# POST http://<IP-VPS>/checkUser  con body {"user": "mexico"}
# Responde texto plano:
#   "not exist"              -> el usuario no existe en /etc/passwd
#   "01/01/2027"             -> fecha de vencimiento (dd/MM/yyyy) del usuario
#   "never"                  -> existe pero nunca vence
#   "token invalido"         -> el usuario tiene un token registrado y el
#                               token enviado no coincide (o no se envio)
# POST con token: {"user": "mexico", "token": "<android-id>"}
#   La app Mustafa VPN siempre envia el Android ID del telefono
#   (Settings.Secure.ANDROID_ID). Si el usuario NO tiene token
#   registrado, el campo token se ignora y responde como antes.
# GET http://<IP-VPS>/server/online
# Responde texto plano con el numero de usuarios online (sesiones SSH
# activas). Lo lee la app Mustafa VPN (SocksHttpMainActivity.loadServer1)
# para mostrar "Usuarios Online: N" en el home.
# Registro de tokens: archivo JSON /etc/checkuser-tokens.json con
#   {"usuario": "android-id", ...}
# Se administra con:
#   python3 checkuser.py --register <usuario> <token>
#   python3 checkuser.py --unregister <usuario>
#   python3 checkuser.py --list
# (el servicio NO necesita reiniciarse: el archivo se lee en cada consulta)
# Solo usa la libreria estandar de Python 3, sin Flask ni nada extra.
import json
import os
import pwd
import spwd
import subprocess
import sys
import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST = os.environ.get("CHECKUSER_HOST", "127.0.0.1")
PORT = int(os.environ.get("CHECKUSER_PORT", "8888"))
TOKENS_FILE = os.environ.get("CHECKUSER_TOKENS_FILE", "/etc/checkuser-tokens.json")

def load_tokens():
    """Registro usuario -> token (Android ID). {} si no existe o esta roto."""
    try:
        with open(TOKENS_FILE, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}

def save_tokens(tokens):
    with open(TOKENS_FILE, "w", encoding="utf-8") as f:
        json.dump(tokens, f, indent=2, sort_keys=True)
        f.write("\n")

def online_count():
    """Numero de usuarios con sesion SSH activa = usuarios conectados a la VPN.
    Cada sesion autenticada deja procesos `sshd: usuario` y `sshd: usuario [priv]`
    (sin @ cuando no hay TTY, como las sesiones VPN); el listener es
    `sshd: ... [listener]` y no se cuenta. Se cuentan usuarios distintos
    (no procesos) y se excluye root, para que las sesiones SSH de mantenimiento
    no inflen el numero. OJO: `who` NO sirve aqui: las sesiones VPN y SSH sin
    TTY no quedan registradas en utmp, asi que `who` siempre devuelve 0 aunque
    haya usuarios conectados (verificado en la VPS MUSTAFA 2026-11-14).
    CORREGIDO 2026-11-15: la version anterior contaba solo lineas con "@"
    (`sshd: root@notty`), o sea las sesiones SSH de mantenimiento, y NO contaba
    las sesiones VPN (`sshd: mexico`, sin @)."""
    try:
        out = subprocess.run(["ps", "-eo", "args"], capture_output=True, text=True, timeout=5)
        users = set()
        for line in out.stdout.splitlines():
            line = line.strip()
            if not line.startswith("sshd: "):
                continue
            if "[listener]" in line:
                continue
            user = line[len("sshd: "):].split()[0].split("@")[0]
            if not user or user == "root":
                continue
            users.add(user)
        return len(users)
    except Exception:
        return 0

def expiry_of(username):
    """Devuelve (existe, fecha_ddmmyyyy_o_never)."""
    try:
        pwd.getpwnam(username)
    except KeyError:
        return False, None
    try:
        # /etc/shadow campo 8 = dias desde 1970-01-01 en que vence la cuenta
        days = spwd.getspnam(username).sp_expire
    except Exception:
        days = -1
    if days is None or days < 0:
        return True, "never"
    date = datetime.date(1970, 1, 1) + datetime.timedelta(days=days)
    return True, date.strftime("%d/%m/%Y")

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/server/online":
            self._send(200, str(online_count()))
            return
        self._send(404, "not found")

    def do_POST(self):
        if self.path != "/checkUser":
            self._send(404, "not found")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length).decode("utf-8", "replace")
            data = json.loads(body) if body.strip() else {}
            username = str(data.get("user", "")).strip()
            token = str(data.get("token", "") or "").strip()
        except Exception:
            self._send(400, "bad request")
            return
        if not username:
            self._send(400, "bad request")
            return
        exists, expiry = expiry_of(username)
        if not exists:
            self._send(200, "not exist")
            return
        # Validacion de token: solo si el usuario tiene uno registrado.
        # Sin token registrado, el campo token se ignora (como antes).
        registered = load_tokens().get(username)
        if registered is not None and token != str(registered).strip():
            self._send(200, "token invalido")
            return
        self._send(200, expiry)

    def _send(self, code, text):
        payload = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        # Silencioso: no llenar el log con cada consulta
        pass

if __name__ == "__main__":
    # Administracion del registro de tokens (no inicia el servidor):
    #   checkuser.py --register <usuario> <token>
    #   checkuser.py --unregister <usuario>
    #   checkuser.py --list
    if len(sys.argv) >= 2 and sys.argv[1] in ("--register", "--unregister", "--list"):
        cmd = sys.argv[1]
        if cmd == "--list":
            tokens = load_tokens()
            if not tokens:
                print("(sin tokens registrados)")
            for user in sorted(tokens):
                print(f"{user}: {tokens[user]}")
            sys.exit(0)
        if len(sys.argv) < 3:
            print(f"Uso: {sys.argv[0]} {cmd} <usuario> [<token>]")
            sys.exit(2)
        user = sys.argv[2].strip()
        tokens = load_tokens()
        if cmd == "--register":
            if len(sys.argv) < 4 or not sys.argv[3].strip():
                print(f"Uso: {sys.argv[0]} --register <usuario> <token>")
                sys.exit(2)
            tokens[user] = sys.argv[3].strip()
            save_tokens(tokens)
            print(f"Token registrado para {user}")
        else:  # --unregister
            if user in tokens:
                del tokens[user]
                save_tokens(tokens)
                print(f"Token eliminado para {user}")
            else:
                print(f"{user} no tenia token registrado")
        sys.exit(0)
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
