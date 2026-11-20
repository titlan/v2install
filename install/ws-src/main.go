// mustafa-ws — Proxy WebSocket -> TCP para MUSTAFA.
// Escucha conexiones HTTP con Upgrade a WebSocket (o HTTP CONNECT),
// responde el handshake y tuneliza los bytes crudos al destino
// (normalmente el SSH local). Código original, solo librería estándar.
//
// Uso:
//
//	mustafa-ws -config /etc/mustafa-ws/config
//	mustafa-ws -listen 0.0.0.0:444 -target 127.0.0.1:22 -token secreto
package main

import (
	"bufio"
	"crypto/sha1"
	"crypto/tls"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

const version = "1.0.0"

const wsGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// Config del proxy. Se llena desde el archivo y los flags lo sobreescriben.
type Config struct {
	Listen        string
	Target        string
	Token         string
	TLSCert       string
	TLSKey        string
	MaxConns      int
	MaxConnsPerIP int
	IdleTimeout   time.Duration
	LogFile       string
}

var (
	cfg     Config
	logger  *log.Logger
	active  atomic.Int64
	perIP   = map[string]int{}
	perIPMu sync.Mutex
)

func main() {
	var configPath string
	flag.StringVar(&configPath, "config", "/etc/mustafa-ws/config", "ruta del archivo de configuración")
	flag.StringVar(&cfg.Listen, "listen", "", "dirección de escucha, ej. 0.0.0.0:444 o :444 (IPv4+IPv6)")
	flag.StringVar(&cfg.Target, "target", "", "destino del túnel, ej. 127.0.0.1:22")
	flag.StringVar(&cfg.Token, "token", "", "token compartido (vacío = sin autenticación)")
	flag.StringVar(&cfg.TLSCert, "tls-cert", "", "certificado TLS para WSS (opcional)")
	flag.StringVar(&cfg.TLSKey, "tls-key", "", "clave TLS para WSS (opcional)")
	flag.IntVar(&cfg.MaxConns, "max-conns", 0, "máximo de conexiones simultáneas (0 = 100)")
	flag.IntVar(&cfg.MaxConnsPerIP, "max-conns-per-ip", 0, "máximo de conexiones por IP (0 = 5)")
	flag.DurationVar(&cfg.IdleTimeout, "idle-timeout", 0, "cierra túneles sin tráfico, ej. 5m (0 = sin límite)")
	flag.StringVar(&cfg.LogFile, "log-file", "", "archivo de log adicional (vacío = solo stdout)")
	flag.Parse()

	// Valores por defecto del archivo de configuración.
	fileCfg := Config{
		Listen:        "0.0.0.0:444",
		Target:        "127.0.0.1:22",
		MaxConns:      100,
		MaxConnsPerIP: 5,
		IdleTimeout:   0,
		LogFile:       "/var/log/mustafa-ws.log",
	}
	if err := loadConfigFile(configPath, &fileCfg); err != nil && configPath != "" {
		// Si el archivo no existe y no se pasaron flags, se sigue con defaults.
		fmt.Fprintf(os.Stderr, "aviso: no se pudo leer %s: %v (se usan valores por defecto)\n", configPath, err)
	}
	mergeConfig(&fileCfg)

	if cfg.MaxConns <= 0 {
		cfg.MaxConns = 100
	}
	if cfg.MaxConnsPerIP <= 0 {
		cfg.MaxConnsPerIP = 5
	}

	setupLogger(cfg.LogFile)

	logger.Printf("mustafa-ws v%s iniciando: escucha=%s destino=%s tls=%v token=%v max_conns=%d max_por_ip=%d idle=%s",
		version, cfg.Listen, cfg.Target, cfg.TLSCert != "", cfg.Token != "", cfg.MaxConns, cfg.MaxConnsPerIP, cfg.IdleTimeout)
	if cfg.Token == "" {
		logger.Printf("ADVERTENCIA: sin TOKEN configurado, cualquiera que llegue al puerto puede usar el túnel")
	}
	if cfg.TLSCert == "" {
		logger.Printf("ADVERTENCIA: sin TLS, el WebSocket va en plano (WS, no WSS). El cifrado lo pone el SSH de adentro")
	}

	ln, err := listen()
	if err != nil {
		logger.Fatalf("no se pudo escuchar en %s: %v", cfg.Listen, err)
	}
	logger.Printf("escuchando en %s -> %s", ln.Addr(), cfg.Target)

	// Apagado limpio con Ctrl+C / SIGTERM.
	go func() {
		ch := make(chan os.Signal, 1)
		signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
		<-ch
		logger.Printf("apagando...")
		ln.Close()
		os.Exit(0)
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				continue
			}
			// El listener se cerró (apagado): salir.
			logger.Printf("listener cerrado: %v", err)
			return
		}
		go handleConn(conn)
	}
}

// listen crea el listener TCP (o TLS si hay certificado).
func listen() (net.Listener, error) {
	ln, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return nil, err
	}
	if cfg.TLSCert != "" && cfg.TLSKey != "" {
		cert, err := tls.LoadX509KeyPair(cfg.TLSCert, cfg.TLSKey)
		if err != nil {
			ln.Close()
			return nil, fmt.Errorf("certificado TLS: %w", err)
		}
		tlsCfg := &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}
		return tls.NewListener(ln, tlsCfg), nil
	}
	return ln, nil
}

// loadConfigFile lee un archivo KEY=VALUE. Las líneas # son comentarios.
func loadConfigFile(path string, out *Config) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 4096), 65536)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(strings.Trim(v, `"'`))
		switch k {
		case "LISTEN":
			out.Listen = v
		case "TARGET":
			out.Target = v
		case "TOKEN":
			out.Token = v
		case "TLS_CERT":
			out.TLSCert = v
		case "TLS_KEY":
			out.TLSKey = v
		case "MAX_CONNS":
			if n, err := strconv.Atoi(v); err == nil {
				out.MaxConns = n
			}
		case "MAX_CONNS_PER_IP":
			if n, err := strconv.Atoi(v); err == nil {
				out.MaxConnsPerIP = n
			}
		case "IDLE_TIMEOUT":
			if d, err := time.ParseDuration(v); err == nil {
				out.IdleTimeout = d
			}
		case "LOG_FILE":
			out.LogFile = v
		}
	}
	return sc.Err()
}

// mergeConfig aplica los flags sobre el archivo: solo lo que el usuario
// pasó en la línea de comandos reemplaza al archivo.
func mergeConfig(fileCfg *Config) {
	seen := map[string]bool{}
	flag.Visit(func(f *flag.Flag) { seen[f.Name] = true })
	if seen["listen"] {
		fileCfg.Listen = cfg.Listen
	}
	if seen["target"] {
		fileCfg.Target = cfg.Target
	}
	if seen["token"] {
		fileCfg.Token = cfg.Token
	}
	if seen["tls-cert"] {
		fileCfg.TLSCert = cfg.TLSCert
	}
	if seen["tls-key"] {
		fileCfg.TLSKey = cfg.TLSKey
	}
	if seen["max-conns"] {
		fileCfg.MaxConns = cfg.MaxConns
	}
	if seen["max-conns-per-ip"] {
		fileCfg.MaxConnsPerIP = cfg.MaxConnsPerIP
	}
	if seen["idle-timeout"] {
		fileCfg.IdleTimeout = cfg.IdleTimeout
	}
	if seen["log-file"] {
		fileCfg.LogFile = cfg.LogFile
	}
	cfg = *fileCfg
}

// setupLogger escribe a stdout y, si se puede, también al archivo de log.
func setupLogger(logFile string) {
	w := io.Writer(os.Stdout)
	if logFile != "" {
		if f, err := os.OpenFile(logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644); err == nil {
			w = io.MultiWriter(os.Stdout, f)
		} else {
			fmt.Fprintf(os.Stderr, "aviso: no se pudo abrir el log %s: %v (solo stdout)\n", logFile, err)
		}
	}
	logger = log.New(w, "", log.LstdFlags)
}

// clientIP extrae la IP remota sin el puerto.
func clientIP(conn net.Conn) string {
	host, _, err := net.SplitHostPort(conn.RemoteAddr().String())
	if err != nil {
		return conn.RemoteAddr().String()
	}
	return host
}

// handleConn atiende una conexión entrante: handshake y túnel.
func handleConn(client net.Conn) {
	ip := clientIP(client)
	start := time.Now()

	// Límite global de conexiones.
	if active.Load() >= int64(cfg.MaxConns) {
		logger.Printf("RECHAZADA ip=%s motivo=límite global de conexiones (%d)", ip, cfg.MaxConns)
		writeStatus(client, "503 Service Unavailable")
		client.Close()
		return
	}
	// Límite por IP.
	perIPMu.Lock()
	if perIP[ip] >= cfg.MaxConnsPerIP {
		perIPMu.Unlock()
		logger.Printf("RECHAZADA ip=%s motivo=límite por IP (%d)", ip, cfg.MaxConnsPerIP)
		writeStatus(client, "429 Too Many Requests")
		client.Close()
		return
	}
	perIP[ip]++
	perIPMu.Unlock()
	defer func() {
		perIPMu.Lock()
		perIP[ip]--
		if perIP[ip] <= 0 {
			delete(perIP, ip)
		}
		perIPMu.Unlock()
	}()

	active.Add(1)
	defer active.Add(-1)
	defer client.Close()

	// El handshake debe llegar rápido o se cierra.
	_ = client.SetReadDeadline(time.Now().Add(10 * time.Second))
	br := bufio.NewReader(client)
	method, path, headers, err := readRequest(br)
	if err != nil {
		logger.Printf("AUTH FALLIDA ip=%s motivo=petición inválida: %v", ip, err)
		return
	}
	_ = client.SetReadDeadline(time.Time{}) // sin límite durante el túnel (lo maneja idle)

	// Autenticación por token (si está configurado).
	if cfg.Token != "" && !tokenOK(path, headers) {
		logger.Printf("AUTH FALLIDA ip=%s motivo=token inválido o ausente método=%s ruta=%s", ip, method, path)
		writeStatus(client, "403 Forbidden")
		return
	}

	var isWS bool
	switch {
	case method == "CONNECT":
		// Proxy HTTP clásico: 200 y túnel crudo.
		fmt.Fprintf(client, "HTTP/1.1 200 Connection Established\r\n\r\n")
	case method == "GET" && isWebSocketUpgrade(headers):
		key := headers["sec-websocket-key"]
		if key == "" {
			writeStatus(client, "400 Bad Request")
			return
		}
		accept := websocketAccept(key)
		fmt.Fprintf(client, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", accept)
		isWS = true
	default:
		writeStatus(client, "400 Bad Request")
		return
	}
	_ = isWS

	// Conectar al destino.
	d := &net.Dialer{Timeout: 10 * time.Second}
	target, err := d.Dial("tcp", cfg.Target)
	if err != nil {
		logger.Printf("FALLO ip=%s motivo=no se pudo conectar al destino %s: %v", ip, cfg.Target, err)
		return
	}
	defer target.Close()

	// Copia bidireccional de bytes crudos (después del handshake el
	// WebSocket lleva datos sin tramas: así lo hacen los clientes
	// tipo HTTP Custom / inyectores y así lo hacía el proxy anterior).
	cConn := client
	tConn := target
	if cfg.IdleTimeout > 0 {
		cConn = &deadlineConn{Conn: client, idle: cfg.IdleTimeout}
		tConn = &deadlineConn{Conn: target, idle: cfg.IdleTimeout}
	}

	var up, down int64
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		n, _ := io.Copy(tConn, cConn)
		atomic.StoreInt64(&up, n)
		// Un sentido se cerró: cerrar el otro para no quedar colgado.
		cConn.Close()
		tConn.Close()
	}()
	go func() {
		defer wg.Done()
		n, _ := io.Copy(cConn, tConn)
		atomic.StoreInt64(&down, n)
		cConn.Close()
		tConn.Close()
	}()
	wg.Wait()

	logger.Printf("CONEXION ip=%s destino=%s subida=%dB bajada=%dB duracion=%s",
		ip, cfg.Target, up, down, time.Since(start).Round(time.Millisecond))
}

// readRequest lee la línea de petición y las cabeceras HTTP.
// Devuelve método, ruta y cabeceras en minúsculas.
func readRequest(br *bufio.Reader) (string, string, map[string]string, error) {
	line, err := br.ReadString('\n')
	if err != nil {
		return "", "", nil, err
	}
	line = strings.TrimRight(line, "\r\n")
	parts := strings.SplitN(line, " ", 3)
	if len(parts) < 2 {
		return "", "", nil, fmt.Errorf("línea de petición inválida: %q", line)
	}
	method := strings.ToUpper(parts[0])
	path := parts[1]

	headers := map[string]string{}
	for i := 0; i < 64; i++ {
		l, err := br.ReadString('\n')
		if err != nil {
			return "", "", nil, err
		}
		l = strings.TrimRight(l, "\r\n")
		if l == "" {
			return method, path, headers, nil
		}
		k, v, ok := strings.Cut(l, ":")
		if !ok {
			continue
		}
		headers[strings.ToLower(strings.TrimSpace(k))] = strings.TrimSpace(v)
	}
	return "", "", nil, fmt.Errorf("demasiadas cabeceras")
}

// isWebSocketUpgrade revisa que pidan el cambio a WebSocket.
func isWebSocketUpgrade(h map[string]string) bool {
	return strings.EqualFold(h["upgrade"], "websocket") &&
		strings.Contains(strings.ToLower(h["connection"]), "upgrade")
}

// websocketAccept calcula Sec-WebSocket-Accept según RFC 6455.
func websocketAccept(key string) string {
	sum := sha1.Sum([]byte(key + wsGUID))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// tokenOK acepta el token en la ruta (GET /<token>) o en la cabecera
// X-Mustafa-Token. La ruta puede llevar query (?...) que se ignora.
func tokenOK(path string, h map[string]string) bool {
	if h["x-mustafa-token"] == cfg.Token {
		return true
	}
	p := strings.SplitN(path, "?", 2)[0]
	p = strings.Trim(p, "/")
	return p == cfg.Token
}

// writeStatus responde un error HTTP simple y cierra.
func writeStatus(conn net.Conn, status string) {
	fmt.Fprintf(conn, "HTTP/1.1 %s\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status)
}

// deadlineConn cierra la conexión si no hay tráfico durante idle.
type deadlineConn struct {
	net.Conn
	idle time.Duration
}

func (d *deadlineConn) Read(b []byte) (int, error) {
	_ = d.Conn.SetReadDeadline(time.Now().Add(d.idle))
	return d.Conn.Read(b)
}

func (d *deadlineConn) Write(b []byte) (int, error) {
	_ = d.Conn.SetWriteDeadline(time.Now().Add(d.idle))
	return d.Conn.Write(b)
}
