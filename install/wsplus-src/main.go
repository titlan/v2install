// wsplus-server — Servidor del protocolo WSPLUS (Upgrade 101).
//
// Handshake HTTP Upgrade 101 idéntico a WebSocket (RFC 6455) y luego
// proxy bidireccional de bytes crudos al destino SSH. Sin framing de
// WebSocket. Solo stdlib.
//
// Uso:
//
//	wsplus-server --listen :8081 --target 127.0.0.1:22 \
//	  --password-file /etc/wsplus/password \
//	  --cert /etc/wsplus/cert.pem --key /etc/wsplus/key.pem
//
// Si se pasan --cert y --key, escucha con TLS; si no, TCP plano.
// El token se valida con comparación en tiempo constante.
package main

import (
	"bufio"
	"bytes"
	"crypto/sha1"
	"crypto/subtle"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

const (
	version      = "1.0.0"
	wsGUID       = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	maxHeaderLen = 8 * 1024 // 8 KiB para las cabeceras del handshake.
	handshakeTO  = 10 * time.Second
)

// config agrupa la configuración del servidor.
type config struct {
	listen   string
	target   string
	password string
	certFile string
	keyFile  string
}

// computeAccept calcula Sec-WebSocket-Accept como en RFC 6455:
// base64(SHA1(key + GUID)).
func computeAccept(key string) string {
	h := sha1.New()
	h.Write([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// validToken compara el token con tiempo constante. Si las longitudes
// difieren, no son iguales (ConstantTimeCompare exige igual longitud).
func validToken(given, expected string) bool {
	if len(given) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(given), []byte(expected)) == 1
}

// headerHasToken revisa si un valor de cabecera (lista separada por
// comas) contiene el token dado, sin distinguir mayúsculas/minúsculas.
func headerHasToken(value, token string) bool {
	for _, part := range strings.Split(value, ",") {
		if strings.EqualFold(strings.TrimSpace(part), token) {
			return true
		}
	}
	return false
}

// writeError contesta un error HTTP con cuerpo vacío y cierra.
func writeError(conn net.Conn, status string) {
	fmt.Fprintf(conn, "HTTP/1.1 %s\r\nContent-Length: 0\r\n\r\n", status)
}

// handleConn atiende una conexión: handshake Upgrade 101 y, si es
// válido, proxy bidireccional al destino. Registra una línea en el log.
func handleConn(conn net.Conn, cfg config) {
	remote := conn.RemoteAddr().String()
	defer conn.Close()

	// El handshake debe completarse en 10 s; después se quita el límite.
	_ = conn.SetReadDeadline(time.Now().Add(handshakeTO))

	// Leer las cabeceras con límite de 8 KiB. http.ReadRequest parsea
	// el método y las cabeceras (case-insensitive).
	br := bufio.NewReaderSize(io.LimitReader(conn, maxHeaderLen), 4096)
	req, err := http.ReadRequest(br)
	if err != nil {
		log.Printf("%s handshake-error: %v", remote, err)
		return
	}

	// Validar: método GET.
	if req.Method != "GET" {
		writeError(conn, "400 Bad Request")
		log.Printf("%s 400 method=%s", remote, req.Method)
		return
	}
	// Validar: Upgrade: websocket.
	if !headerHasToken(req.Header.Get("Upgrade"), "websocket") {
		writeError(conn, "400 Bad Request")
		log.Printf("%s 400 no-upgrade", remote)
		return
	}
	// Validar: Connection debe contener Upgrade.
	if !headerHasToken(req.Header.Get("Connection"), "Upgrade") {
		writeError(conn, "400 Bad Request")
		log.Printf("%s 400 no-connection-upgrade", remote)
		return
	}
	// Validar: Sec-WebSocket-Key presente y base64 de 16 bytes.
	key := req.Header.Get("Sec-WebSocket-Key")
	rawKey, err := base64.StdEncoding.DecodeString(strings.TrimSpace(key))
	if err != nil || len(rawKey) != 16 {
		writeError(conn, "400 Bad Request")
		log.Printf("%s 400 bad-ws-key", remote)
		return
	}
	// Validar: token en tiempo constante.
	if !validToken(req.Header.Get("X-Mustafa-Token"), cfg.password) {
		writeError(conn, "403 Forbidden")
		log.Printf("%s 403 bad-token", remote)
		return
	}

	// Marcar el destino ANTES de contestar 101: si no se puede marcar,
	// se cierra sin haber mandado nada (el cliente ve un cierre).
	target, err := net.DialTimeout("tcp", cfg.target, handshakeTO)
	if err != nil {
		log.Printf("%s dial-target-error: %v", remote, err)
		return
	}
	defer target.Close()

	// Contestar 101 con el Accept calculado como en RFC 6455.
	accept := computeAccept(strings.TrimSpace(key))
	_, err = fmt.Fprintf(conn, "HTTP/1.1 101 Switching Protocols\r\n"+
		"Upgrade: websocket\r\n"+
		"Connection: Upgrade\r\n"+
		"Sec-WebSocket-Accept: %s\r\n\r\n", accept)
	if err != nil {
		log.Printf("%s 101-write-error: %v", remote, err)
		return
	}

	// Quitar el deadline: el túnel vive lo que dure la conexión.
	_ = conn.SetReadDeadline(time.Time{})

	// El bufio puede tener bytes ya leídos del túnel (el cliente manda
	// datos justo después de las cabeceras). Se conservan poniéndolos
	// delante de la conexión en la dirección cliente -> destino.
	var clientReader io.Reader = conn
	if n := br.Buffered(); n > 0 {
		buf, _ := br.Peek(n)
		clientReader = io.MultiReader(bytes.NewReader(append([]byte(nil), buf...)), conn)
	}

	// Proxy bidireccional con conteo de bytes.
	var up, down int64
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		n, _ := io.Copy(target, clientReader)
		up = n
		// Al terminar un sentido, cerrar ambos para soltar el otro.
		_ = target.Close()
		_ = conn.Close()
	}()
	go func() {
		defer wg.Done()
		n, _ := io.Copy(conn, target)
		down = n
		_ = target.Close()
		_ = conn.Close()
	}()
	wg.Wait()

	log.Printf("%s 101 up=%d down=%d", remote, up, down)
}

// serve acepta conexiones hasta que el listener se cierre.
func serve(ln net.Listener, cfg config) error {
	for {
		conn, err := ln.Accept()
		if err != nil {
			// Si el listener se cerró, terminar sin error.
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			return err
		}
		go handleConn(conn, cfg)
	}
}

func main() {
	log.SetFlags(log.LstdFlags)

	listen := flag.String("listen", ":8081", "dirección TCP donde escucha (host:puerto)")
	target := flag.String("target", "127.0.0.1:22", "destino SSH al que tuneliza")
	password := flag.String("password", "", "token del protocolo")
	passwordFile := flag.String("password-file", "", "archivo con el token (una línea)")
	certFile := flag.String("cert", "", "certificado TLS (con --key activa TLS)")
	keyFile := flag.String("key", "", "clave privada TLS (con --cert activa TLS)")
	showVersion := flag.Bool("version", false, "imprime la versión y sale")
	flag.Parse()

	if *showVersion {
		fmt.Printf("wsplus-server %s\n", version)
		os.Exit(0)
	}

	// Resolver el token: el archivo manda sobre --password.
	pass := *password
	if *passwordFile != "" {
		data, err := os.ReadFile(*passwordFile)
		if err != nil {
			log.Fatalf("no se pudo leer --password-file %s: %v", *passwordFile, err)
		}
		pass = strings.TrimSpace(string(data))
	}
	if pass == "" {
		log.Fatalf("se necesita --password o --password-file")
	}

	// TLS solo si están AMBOS; uno solo es un error de configuración.
	useTLS := *certFile != "" || *keyFile != ""
	if (*certFile == "") != (*keyFile == "") {
		log.Fatalf("TLS necesita --cert y --key juntos")
	}

	cfg := config{
		listen:   *listen,
		target:   *target,
		password: pass,
		certFile: *certFile,
		keyFile:  *keyFile,
	}

	var ln net.Listener
	var err error
	if useTLS {
		cert, err := tls.LoadX509KeyPair(*certFile, *keyFile)
		if err != nil {
			log.Fatalf("no se pudo cargar el cert/key TLS: %v", err)
		}
		tlsCfg := &tls.Config{Certificates: []tls.Certificate{cert}}
		ln, err = tls.Listen("tcp", *listen, tlsCfg)
	} else {
		ln, err = net.Listen("tcp", *listen)
	}
	if err != nil {
		log.Fatalf("no se pudo escuchar en %s: %v", *listen, err)
	}
	defer ln.Close()

	mode := "TCP plano"
	if useTLS {
		mode = "TLS"
	}
	log.Printf("wsplus-server %s escuchando en %s (%s) -> %s", version, *listen, mode, *target)
	if err := serve(ln, cfg); err != nil {
		// Aceptar se cierra al cerrar el listener (apagado limpio).
		if !strings.Contains(err.Error(), "use of closed network connection") {
			log.Fatalf("serve: %v", err)
		}
	}
}
