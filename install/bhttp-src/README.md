# BHTTP server — codigo fuente vendored (copia congelada)

El servidor BHTTP que instala `install/bhttp.sh` se compila desde ESTA
copia, no desde el repo de La Casita. Asi el instalador no
depende de que lacasitamx/CoreSSH siga existiendo o no cambie.

## Procedencia

- Origen: https://github.com/lacasitamx/CoreSSH (publico, sin licencia)
  proyecto "DragonCoreSSH V40", commit
  `2b5a8c445233024b2de3f51dea6996f3d464d029` ("HCR SUPPORT").
- Copiado el 2026-11-14 desde /opt/CoreSSH de la VPS La Casita
  (77.113.105.219), donde el servidor ya corre en el puerto 8087.
- Archivos: `internal/bhttp/{protocol,server,session,sniff}.go` y
  `cmd/bhttp-standalone/main.go`, sin modificar (solo se anadio este
  README y el go.mod minimo).

## Por que compila solo

El paquete `internal/bhttp` solo importa la libreria estandar de Go
(bufio, bytes, crypto/sha256, encoding/binary, errors, fmt, io, log,
net, strings, sync, sync/atomic, time). No usa ninguna dependencia
externa del resto del panel (PostgreSQL, kcp, smux, DNSTT, etc.), por
eso basta un go.mod minimo con `module shell2` y `go 1.21`.

## Compilacion

La hace `install/bhttp.sh`: descarga el toolchain oficial Go 1.27.4
de go.dev (SHA-256 verificado), compila
`go build -trimpath -ldflags "-s -w" -o /opt/bhttp/bhttp-server ./cmd/bhttp-standalone`
e instala el binario con su servicio systemd.

## Actualizar

Si La Casita mejora BHTTP y se quiere traer el cambio, se copian de
nuevo los 5 archivos desde su repo y se actualiza el commit de arriba.
No se actualiza solo.
