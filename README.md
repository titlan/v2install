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
| `[02] MENU V2RAY` | Mostrar cuentas UUID y enlaces (VLESS Reality, VMess WS, VLESS WS), agregar/eliminar UUID, reiniciar Xray, estado |
| `[03] INSTALAR PROTOCOLOS` | Instalar cada protocolo (ver tabla). Muestra `[ON]` / `[OFF]` / `[--]` |
| `[04] GENERADOR DE KEY` | Generar / listar / revocar keys, exportar hashes para el repo |
| `[00] SALIR` | Salir del menú |
| `[88] REINICIAR VPS` | Reinicia el VPS (pide confirmación) |

## Protocolos (menú [03])

| # | Protocolo | Puerto | Instalador |
| - | --------- | ------ | ---------- |
| 1 | BadVPN (udpgw) | 7300 UDP | `install/badvpn.sh` (compila desde ambrop72/badvpn) |
| 2 | Stunnel4 (SSH+SSL) | 443, o 4443 si Xray ocupa el 443 | `install/stunnel4.sh` |
| 3 | HCR | 8080 TLS | `install/hcr.sh` (compila desde `install/hcr-src/`) |
| 4 | BHTTP | 8087 | `install/bhttp.sh` (compila desde `install/bhttp-src/`, solo x86_64) |
| 5 | CHTTP | 8445 TLS | `install/chttp.sh` (compila desde `install/chttp-src/`) |
| 6 | V2SOCKS | señal 8444, UDP 3478 | `install/v2socks.sh` (compila desde `install/v2socks-src/`) |
| 7 | mustafa-ws (SSH/WS) | 444 | `install/mustafa-ws.sh` (compila desde `install/ws-src/`) |
| 8 | CheckUser | 80 | `install/checkuser.sh` |
| 9 | Monitor App | panel en `http://IP/monitor.html` | `install/monitor.sh` |

La base (sin entrar al menú [03]) ya instala: Xray (VLESS Reality :443,
VMess WS :10086, VLESS WS :10087), Nginx proxy WS :80 (`/vmess`, `/vless`),
OpenSSH :22 y mustafa-ws :444 con TOKEN.

La Monitor App vigila los servicios (timer cada 60 s), reinicia los
caídos, registra eventos en `/var/log/monitor-mustafa.log` y publica el
estado en `/var/www/html/monitor.html` (lo sirve Nginx en el :80).

## Estructura del repo

| Archivo | Qué es |
| ------- | ------ |
| `install.sh` | Instalador base + validación de KEY |
| `mustafa` | Menú principal (se instala como comando `mustafa`) |
| `keys.sha256` | Registro de hashes de keys válidas |
| `install/badvpn.sh`, `install/stunnel4.sh` | Instaladores BadVPN / Stunnel4 |
| `install/hcr.sh` + `install/hcr-src/` | HCR (fuente Go limpia) |
| `install/bhttp.sh` + `install/bhttp-src/` | BHTTP (fuente Go) |
| `install/chttp.sh` + `install/chttp-src/` | CHTTP (fuente Go) |
| `install/v2socks.sh` + `install/v2socks-src/` | V2SOCKS (fuente Go) |
| `install/mustafa-ws.sh` + `install/ws-src/` | mustafa-ws (fuente Go) |
| `install/checkuser.sh`, `install/checkuser.py`, `install/checkuser.service` | CheckUser |
| `install/monitor.sh` | Monitor App |
| `README.md` | Este archivo |

Los instaladores de protocolos se copian a `/etc/mustafa/install/` para
que el menú [03] los pueda ejecutar después. Todo se compila desde
fuente en el VPS (Go 1.27.4, se descarga si hace falta); el repo no
lleva binarios.

## Puertos

22 SSH · 80 HTTP/Nginx/CheckUser/Monitor · 443 Xray VLESS Reality
(o Stunnel4 si Xray no lo ocupa) · 444 mustafa-ws · 7300 BadVPN UDP ·
8080 HCR · 8087 BHTTP · 8444 V2SOCKS señal · 8445 CHTTP · UDP 3478
V2SOCKS · UDP 443 Hysteria2 (futuro) · 5667 ZIVPN UDP (futuro).

## Estado

Versión **1.0**. Probado en local (sintaxis y render del menú);
**falta la primera instalación real en un VPS limpio** para verificar
el arranque de cada servicio y la validación de KEY de punta a punta.
