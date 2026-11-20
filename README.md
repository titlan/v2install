# MUSTAFA — Instalador v1.0 (titlan/v2install)

Instalador propio de MUSTAFA para Ubuntu 22.04/24.04. Instala la base
(Xray, Nginx, SSH, mustafa-ws) y deja el menú `mustafa` con el que se
administran usuarios SSH, cuentas V2Ray, protocolos y keys de instalación.

## Instalación

Se necesita una **KEY de instalación**, generada por quien administra
MUSTAFA (menú `[04] GENERADOR DE KEY` en un VPS ya instalado).

```bash
git clone https://github.com/titlan/v2install.git
cd v2install
sudo bash install.sh [dominio]
```

El instalador pide la KEY y la valida contra el registro de hashes
(`keys.sha256` en este repo). También acepta `MUSTAFA_KEY=<key>`:

```bash
sudo MUSTAFA_KEY=MUSTAFA-XXXX-XXXX-XXXX-XXXX bash install.sh [dominio]
```

- El dominio es opcional. Sin dominio se instala VLESS + Reality, que no
  lo necesita. Con dominio se emite un certificado TLS con acme.sh y
  mustafa-ws sirve WSS.
- Log: `/var/log/mustafa-install.log`. Estado: `/etc/mustafa/`.
- **Aviso:** mientras no haya ninguna key publicada en `keys.sha256`, el
  instalador avisa y continúa sin verificar (modo prueba). En cuanto se
  publique la primera key, la KEY pasa a ser obligatoria y una key
  revocada (borrada del registro) ya no instala.

## Sistema de keys

- Formato: `MUSTAFA-XXXX-XXXX-XXXX-XXXX` (letras A-Z y dígitos 2-9).
- Se generan en el menú `[04] GENERADOR DE KEY`: generar, listar,
  revocar y exportar hashes.
- En el repo **solo van los hashes SHA-256** (`keys.sha256`), nunca las
  keys en claro: un hash no se puede revertir para obtener la key.
- Para publicar keys nuevas: menú `[04]` → `[4] Exportar hashes` y
  pegar el contenido en `keys.sha256` (raíz del repo).
- `install.sh` guarda solo el hash de la key usada en
  `/etc/mustafa/installed-key` (0600).

## Menú (`mustafa`)

| Opción | Qué hace |
| ------ | -------- |
| `[01] MENU SSH` | Crear / remover / bloquear / editar / renovar usuarios SSH, mostrar cuentas, usuarios conectados, eliminar vencidos |
| `[02] MENU V2RAY` | Mostrar cuentas UUID y enlaces (VLESS Reality, VMess WS, VLESS WS, **VLESS XHTTP** — se elige el transporte al mostrar o agregar), agregar/eliminar UUID, reiniciar Xray, estado, **instalar / desinstalar V2Ray** |
| `[03] INSTALAR PROTOCOLOS` | Cada protocolo trae **Instalar / Desinstalar / Cambiar puerto** (ver tabla). Muestra `[ON]` / `[OFF]` / `[--]` y el puerto actual |
| `[04] GENERADOR DE KEY` | Generar / listar / revocar keys, exportar hashes para el repo |
| `[05] HERRAMIENTAS 🔐` | **Fail2Ban** (bloquea fuerza bruta SSH), **BBR** (más velocidad TCP), **vnStat** (tráfico por día/mes), **respaldo** de usuarios/keys/configs (`/root/mustafa-backup-*.tar.gz`) |
| `[00] SALIR` | Salir del menú |
| `[88] REINICIAR VPS` | Reinicia el VPS (pide confirmación) |

## Protocolos (menú [03])

Cada protocolo tiene su propio submenú con **[1] Instalar, [2] Desinstalar
y [3] Cambiar puerto**. Al instalar (o al cambiar el puerto) el menú
pregunta en qué puerto escucha; si se deja en blanco usa el actual o el
de por defecto. El puerto elegido se guarda en `/etc/mustafa/ports/<protocolo>`
y se muestra en la lista. Cambiar el puerto reconfigura y reinicia el
servicio (sin recompilar ni perder la configuración ni el TOKEN de
mustafa-ws). Desinstalar borra el servicio, el binario y su configuración.

| # | Protocolo | Puerto (defecto, configurable) | Instalador |
| - | --------- | ------------------------------ | ---------- |
| 1 | BadVPN (udpgw) | 7300 UDP | `install/badvpn.sh` (compila desde ambrop72/badvpn) |
| 2 | Stunnel4 (SSH+SSL) | 443, o 4443 si Xray ocupa el 443 | `install/stunnel4.sh` (unidad systemd nativa) |
| 3 | HCR | 8080 TLS | `install/hcr.sh` (compila desde `install/hcr-src/`) |
| 4 | BHTTP | 8087 | `install/bhttp.sh` (compila desde `install/bhttp-src/`, solo x86_64) |
| 5 | CHTTP | 8445 TLS | `install/chttp.sh` (compila desde `install/chttp-src/`) |
| 6 | V2SOCKS | señal 8444, UDP 3478 (fijo) | `install/v2socks.sh` (compila desde `install/v2socks-src/`) |
| 7 | mustafa-ws (SSH/WS) | 444 | `install/mustafa-ws.sh` (compila desde `install/ws-src/`) |
| 8 | CheckUser | :80 público (vía Nginx) / 8888 loopback | `install/checkuser.sh` |
| 9 | Monitor App | panel en `http://IP/monitor.html` (sin puerto propio) | `install/monitor.sh` |
| 10 | Hysteria2 (QUIC/UDP) | 443 UDP | `install/hysteria2.sh` (binario oficial HyNetwork/hysteria, SHA-256 verificado) |

La base (sin entrar al menú [03]) ya instala: Xray (VLESS Reality :443,
VMess WS :10086, VLESS WS :10087, **VLESS XHTTP :10088**), Nginx proxy
WS/XHTTP :80 (`/vmess`, `/vless`, `/xhttp`, `/checkUser`, `/server/online`),
OpenSSH :22 y mustafa-ws :444 con TOKEN.

En el menú [02], al mostrar cuentas o agregar un UUID, se pregunta qué
transporte mostrar: Todos, solo Reality, solo WebSocket o solo XHTTP.
El UUID funciona en los 4 transportes; la elección solo cambia qué
enlace se muestra. Al reinstalar V2Ray con [02] → [6], si la config
existente no tiene XHTTP, se le agrega sin tocar los UUID ni las claves
Reality (y Nginx recibe el proxy `/xhttp` si le falta).

CheckUser escucha en loopback `127.0.0.1:8888` (configurable) y Nginx lo
publica en el :80 (`/checkUser` y `/server/online`), para que las tarjetas
Online/Vence de la app funcionen también con datos móviles (Telcel
intercepta el HTTP plano; por eso no va directo al :80).

La Monitor App vigila los servicios (timer cada 60 s), reinicia los
caídos, registra eventos en `/var/log/monitor-mustafa.log` y publica el
estado en `/var/www/html/monitor.html` (lo sirve Nginx en el :80).

## Estructura del repo

| Archivo | Qué es |
| ------- | ------ |
| `install.sh` | Instalador base + validación de KEY |
| `install/xray.sh` | Instalador standalone de Xray (para [02] → [6] Instalar V2Ray; también `--uninstall`) |
| `mustafa` | Menú principal (se instala como comando `mustafa`) |
| `keys.sha256` | Registro de hashes de keys válidas |
| `install/badvpn.sh`, `install/stunnel4.sh` | Instaladores BadVPN / Stunnel4 |
| `install/hcr.sh` + `install/hcr-src/` | HCR (fuente Go limpia) |
| `install/bhttp.sh` + `install/bhttp-src/` | BHTTP (fuente Go) |
| `install/chttp.sh` + `install/chttp-src/` | CHTTP (fuente Go) |
| `install/v2socks.sh` + `install/v2socks-src/` | V2SOCKS (fuente Go) |
| `install/mustafa-ws.sh` + `install/ws-src/` | mustafa-ws (fuente Go) |
| `install/checkuser.sh`, `install/checkuser.py`, `install/checkuser.service` | CheckUser |
| `install/hysteria2.sh` | Hysteria2 (binario oficial) |
| `install/monitor.sh` | Monitor App |
| `install/herramientas.sh` | Herramientas (Fail2Ban + BBR + vnStat + respaldo `mustafa-backup`) |
| `README.md` | Este archivo |

Los instaladores de protocolos se copian a `/etc/mustafa/install/` para
que el menú [03] los pueda ejecutar después. Todo se compila desde
fuente en el VPS (Go 1.27.4, se descarga si hace falta); el repo no
lleva binarios.

## Puertos

22 SSH · 80 HTTP/Nginx/CheckUser/Monitor · 443 Xray VLESS Reality
(o Stunnel4 si Xray no lo ocupa) · 444 mustafa-ws · 7300 BadVPN UDP ·
8080 HCR · 8087 BHTTP · 8444 V2SOCKS señal · 8445 CHTTP · 8888 CheckUser
(loopback) · 10086 VMess WS · 10087 VLESS WS · 10088 VLESS XHTTP ·
UDP 3478 V2SOCKS · UDP 443 Hysteria2 · 5667 ZIVPN UDP (futuro).

Todos los puertos de la tabla de protocolos se pueden cambiar desde el
menú [03] (cada protocolo → [3] Cambiar puerto); V2SOCKS cambia solo el
puerto de señalización (el UDP 3478 es fijo) y CheckUser cambia el puerto
de loopback (el público sigue siendo el :80 de Nginx).

## Estado

Versión **1.0**. Primera instalación real completada en un VPS limpio
(2026-11-19, base Xray + menú funcionando). Los instaladores de
protocolos (CHTTP, V2SOCKS, HCR, BHTTP, mustafa-ws, Stunnel4, CheckUser,
Monitor, Xray standalone) se probaron de punta a punta en local:
instalación con puerto elegido, cambio de puerto, desinstalación y
verificación de que el servicio escucha en el puerto. Las herramientas
[05] (Fail2Ban, vnStat, respaldo) también se probaron en local vía el
menú; BBR no se pudo probar en la VM de pruebas (su kernel no trae el
módulo tcp_bbr) — en un VPS Ubuntu normal sí está disponible. Falta
probar cada protocolo en el VPS real y una conexión de la app de punta
a punta.
