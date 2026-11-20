// doh-server — Servidor del protocolo DOH (túnel DNS sobre DoH, RFC 8484).
//
// Túnel DNS real (datos en el QNAME y en registros TXT) transportado por
// DNS over HTTPS: POST /dns-query con Content-Type: application/dns-message.
// Para un observador el tráfico es indistinguible de consultas DoH normales
// a un resolver. Solo stdlib.
//
// Uso:
//
//	doh-server --listen :8053 --target 127.0.0.1:22 \
//	  --password-file /etc/doh/password \
//	  --cert /etc/doh/cert.pem --key /etc/doh/key.pem
//
// Si se pasan --cert y --key, escucha con TLS; si no, TCP plano (solo
// pruebas). El token se valida con comparación en tiempo constante.
// Fiabilidad stop-and-wait: una consulta, una respuesta.
package main

import (
	"crypto/subtle"
	"encoding/base32"
	"encoding/base64"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	version = "1.0.0"

	// maxQueryBytes es el tamaño máximo de un mensaje DNS de consulta
	// (el QNAME tiene como máximo 255 bytes; la consulta entera es
	// mucho menor que esto).
	maxQueryBytes = 4096
	// maxUploadLabels: hasta 3 etiquetas de datos en el QNAME.
	maxUploadLabels = 3
	// maxUploadBytes: lo que cabe en 3 etiquetas de 63 caracteres base32
	// (~117 bytes; 189 caracteres base32 = 118 bytes como máximo).
	maxUploadBytes = 118
	// maxDownloadBytes: bajada máxima por respuesta (base32 en TXT).
	maxDownloadBytes = 1275
	// sessionIdle: la sesión se cierra tras 60 s sin consultas.
	sessionIdle = 60 * time.Second
	// suffix es el sufijo fijo del QNAME.
	suffix = "doh"
)

var (
	// b32 es base32 RFC 4648 sin padding (el DNS no distingue
	// mayúsculas, así que el QNAME va en minúsculas).
	b32 = base32.StdEncoding.WithPadding(base32.NoPadding)
)

// config agrupa la configuración del servidor.
type config struct {
	listen   string
	target   string
	password string
	certFile string
	keyFile  string
}

// validToken compara el token con tiempo constante. Si las longitudes
// difieren, no son iguales (ConstantTimeCompare exige igual longitud).
func validToken(given, expected string) bool {
	if len(given) != len(expected) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(given), []byte(expected)) == 1
}

// encodeB32 codifica bytes a base32 en minúsculas y sin padding.
func encodeB32(data []byte) string {
	return strings.ToLower(b32.EncodeToString(data))
}

// decodeB32 decodifica base32 en minúsculas (o mayúsculas) sin padding.
func decodeB32(s string) ([]byte, error) {
	return b32.DecodeString(strings.ToUpper(s))
}

// ---------------------------------------------------------------------------
// Codec DNS mínimo (formato DNS real, RFC 1035).
// ---------------------------------------------------------------------------

// dnsQuestion es una pregunta DNS: QNAME (etiquetas) + QTYPE + QCLASS.
type dnsQuestion struct {
	labels []string // etiquetas del QNAME, en orden
	qtype  uint16
	qclass uint16
}

// qname devuelve el QNAME como cadena con puntos.
func (q *dnsQuestion) qname() string {
	return strings.Join(q.labels, ".")
}

// parseQuery parsea un mensaje DNS de consulta. Devuelve el ID, la pregunta
// y un error si el mensaje no es una consulta válida (cabecera corta,
// QDCOUNT != 1, QNAME malformado, etc.).
func parseQuery(msg []byte) (id uint16, q dnsQuestion, err error) {
	if len(msg) < 12 {
		return 0, q, fmt.Errorf("mensaje demasiado corto: %d bytes", len(msg))
	}
	id = binary.BigEndian.Uint16(msg[0:2])
	qdcount := binary.BigEndian.Uint16(msg[4:6])
	ancount := binary.BigEndian.Uint16(msg[6:8])
	if qdcount != 1 || ancount != 0 {
		return 0, q, fmt.Errorf("QDCOUNT=%d ANCOUNT=%d (se espera 1 y 0)", qdcount, ancount)
	}
	off := 12
	var labels []string
	for {
		if off >= len(msg) {
			return 0, q, fmt.Errorf("QNAME sin terminar")
		}
		l := int(msg[off])
		off++
		if l == 0 {
			break
		}
		// Puntero de compresión (0xC0..) no se acepta en una consulta.
		if l&0xC0 != 0 {
			return 0, q, fmt.Errorf("QNAME con puntero de compresión")
		}
		if l > 63 || off+l > len(msg) {
			return 0, q, fmt.Errorf("etiqueta inválida (len %d)", l)
		}
		labels = append(labels, string(msg[off:off+l]))
		off += l
	}
	if len(labels) == 0 {
		return 0, q, fmt.Errorf("QNAME vacío")
	}
	if off+4 > len(msg) {
		return 0, q, fmt.Errorf("falta QTYPE/QCLASS")
	}
	q.labels = labels
	q.qtype = binary.BigEndian.Uint16(msg[off : off+2])
	q.qclass = binary.BigEndian.Uint16(msg[off+2 : off+4])
	return id, q, nil
}

// writeQuestion escribe una pregunta (QNAME + QTYPE + QCLASS) en el buffer.
func writeQuestion(buf []byte, q dnsQuestion) []byte {
	for _, label := range q.labels {
		buf = append(buf, byte(len(label)))
		buf = append(buf, label...)
	}
	buf = append(buf, 0)
	var tmp [4]byte
	binary.BigEndian.PutUint16(tmp[0:2], q.qtype)
	binary.BigEndian.PutUint16(tmp[2:4], q.qclass)
	return append(buf, tmp[:]...)
}

// buildQuery construye un mensaje DNS de consulta (flags 0x0100, QDCOUNT=1).
func buildQuery(id uint16, q dnsQuestion) []byte {
	msg := make([]byte, 0, 64)
	var h [12]byte
	binary.BigEndian.PutUint16(h[0:2], id)
	binary.BigEndian.PutUint16(h[2:4], 0x0100)
	binary.BigEndian.PutUint16(h[4:6], 1)
	msg = append(msg, h[:]...)
	return writeQuestion(msg, q)
}

// buildResponse construye un mensaje DNS de respuesta con un registro TXT.
// rcode 0 = OK (ANCOUNT=1, con el TXT); rcode != 0 = error (ANCOUNT=0).
// down son los datos de bajada ya codificados en base32 (se reparten en
// cadenas TXT de 255 bytes como máximo; si down está vacío, el TXT es una
// sola cadena vacía).
func buildResponse(id uint16, q dnsQuestion, rcode uint16, downB32 string) []byte {
	msg := make([]byte, 0, 128)
	var h [12]byte
	binary.BigEndian.PutUint16(h[0:2], id)
	flags := uint16(0x8180) | (rcode & 0x0F)
	binary.BigEndian.PutUint16(h[2:4], flags)
	binary.BigEndian.PutUint16(h[4:6], 1)
	if rcode == 0 {
		binary.BigEndian.PutUint16(h[6:8], 1)
	}
	msg = append(msg, h[:]...)
	msg = writeQuestion(msg, q)
	if rcode != 0 {
		return msg
	}
	// Respuesta: NAME = puntero 0xC00C (al QNAME, offset 12), TYPE=16,
	// CLASS=1, TTL=0, RDLENGTH, RDATA (cadenas TXT con byte de longitud).
	msg = append(msg, 0xC0, 0x0C)
	var tmp [10]byte
	binary.BigEndian.PutUint16(tmp[0:2], 16) // TXT
	binary.BigEndian.PutUint16(tmp[2:4], 1)  // IN
	binary.BigEndian.PutUint32(tmp[4:8], 0)  // TTL
	// RDATA: cadenas de 255 bytes como máximo.
	rdata := make([]byte, 0, len(downB32)+8)
	if len(downB32) == 0 {
		rdata = append(rdata, 0)
	} else {
		for len(downB32) > 0 {
			n := len(downB32)
			if n > 255 {
				n = 255
			}
			rdata = append(rdata, byte(n))
			rdata = append(rdata, downB32[:n]...)
			downB32 = downB32[n:]
		}
	}
	binary.BigEndian.PutUint16(tmp[8:10], uint16(len(rdata)))
	msg = append(msg, tmp[:]...)
	return append(msg, rdata...)
}

// parseResponse parsea un mensaje DNS de respuesta y devuelve el ID, el
// RCODE y los datos de bajada (base32 descodificado). Es la función
// espejo de buildResponse; la usa el cliente y las pruebas.
func parseResponse(msg []byte) (id uint16, rcode uint16, down []byte, err error) {
	if len(msg) < 12 {
		return 0, 0, nil, fmt.Errorf("mensaje demasiado corto: %d bytes", len(msg))
	}
	id = binary.BigEndian.Uint16(msg[0:2])
	flags := binary.BigEndian.Uint16(msg[2:4])
	rcode = flags & 0x0F
	qdcount := binary.BigEndian.Uint16(msg[4:6])
	ancount := binary.BigEndian.Uint16(msg[6:8])
	if qdcount != 1 {
		return 0, 0, nil, fmt.Errorf("QDCOUNT=%d (se espera 1)", qdcount)
	}
	// Saltar la pregunta.
	off := 12
	for {
		if off >= len(msg) {
			return 0, 0, nil, fmt.Errorf("pregunta sin terminar")
		}
		l := int(msg[off])
		off++
		if l == 0 {
			break
		}
		if l&0xC0 != 0 {
			return 0, 0, nil, fmt.Errorf("pregunta con puntero")
		}
		off += l
		if off > len(msg) {
			return 0, 0, nil, fmt.Errorf("pregunta truncada")
		}
	}
	if off+4 > len(msg) {
		return 0, 0, nil, fmt.Errorf("falta QTYPE/QCLASS")
	}
	off += 4
	if rcode != 0 || ancount == 0 {
		return id, rcode, nil, nil
	}
	// Respuesta: NAME (puntero o etiquetas), TYPE, CLASS, TTL, RDLENGTH, RDATA.
	if off+2 > len(msg) {
		return 0, 0, nil, fmt.Errorf("falta NAME de la respuesta")
	}
	if msg[off]&0xC0 == 0xC0 {
		off += 2
	} else {
		for {
			if off >= len(msg) {
				return 0, 0, nil, fmt.Errorf("NAME sin terminar")
			}
			l := int(msg[off])
			off++
			if l == 0 {
				break
			}
			off += l
		}
	}
	if off+10 > len(msg) {
		return 0, 0, nil, fmt.Errorf("respuesta truncada")
	}
	typ := binary.BigEndian.Uint16(msg[off : off+2])
	rdlen := binary.BigEndian.Uint16(msg[off+8 : off+10])
	off += 10
	if typ != 16 {
		return 0, 0, nil, fmt.Errorf("TYPE=%d (se espera TXT 16)", typ)
	}
	if off+int(rdlen) > len(msg) {
		return 0, 0, nil, fmt.Errorf("RDATA truncado")
	}
	rdata := msg[off : off+int(rdlen)]
	// Concatenar las cadenas TXT.
	var b32str strings.Builder
	for len(rdata) > 0 {
		n := int(rdata[0])
		rdata = rdata[1:]
		if n > len(rdata) {
			return 0, 0, nil, fmt.Errorf("cadena TXT truncada")
		}
		b32str.Write(rdata[:n])
		rdata = rdata[n:]
	}
	if b32str.Len() == 0 {
		return id, rcode, nil, nil
	}
	down, err = decodeB32(b32str.String())
	if err != nil {
		return 0, 0, nil, fmt.Errorf("base32 de bajada inválido: %v", err)
	}
	return id, rcode, down, nil
}

// ---------------------------------------------------------------------------
// QNAME: <datos-b32...> . <seq> . <sesion> . doh
// ---------------------------------------------------------------------------

// parseQNAME separa el QNAME en sus partes: datos de subida (bytes),
// seq y sesión. Si no hay etiquetas de datos, es un sondeo (up vacío).
// Devuelve error si el QNAME no sigue el formato (sin sufijo "doh",
// seq no numérico, sesión no hex de 8).
func parseQNAME(q dnsQuestion) (up []byte, seq int, session string, err error) {
	labels := q.labels
	if len(labels) < 3 {
		return nil, 0, "", fmt.Errorf("QNAME demasiado corto: %q", q.qname())
	}
	if labels[len(labels)-1] != suffix {
		return nil, 0, "", fmt.Errorf("QNAME sin sufijo .%s: %q", suffix, q.qname())
	}
	session = labels[len(labels)-2]
	if len(session) != 8 {
		return nil, 0, "", fmt.Errorf("sesión no es 8 hex: %q", session)
	}
	for _, c := range session {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return nil, 0, "", fmt.Errorf("sesión no es hex minúsculas: %q", session)
		}
	}
	seqStr := labels[len(labels)-3]
	seq, err = strconv.Atoi(seqStr)
	if err != nil || seq < 0 {
		return nil, 0, "", fmt.Errorf("seq no numérico: %q", seqStr)
	}
	dataLabels := labels[:len(labels)-3]
	if len(dataLabels) > maxUploadLabels {
		return nil, 0, "", fmt.Errorf("demasiadas etiquetas de datos: %d", len(dataLabels))
	}
	if len(dataLabels) == 0 {
		return nil, seq, session, nil
	}
	joined := strings.Join(dataLabels, "")
	up, err = decodeB32(joined)
	if err != nil {
		return nil, 0, "", fmt.Errorf("base32 de subida inválido: %v", err)
	}
	if len(up) > maxUploadBytes {
		return nil, 0, "", fmt.Errorf("subida demasiado grande: %d bytes", len(up))
	}
	return up, seq, session, nil
}

// buildQNAME construye las etiquetas del QNAME para una subida dada.
func buildQNAME(up []byte, seq int, session string) dnsQuestion {
	var labels []string
	if len(up) > 0 {
		enc := encodeB32(up)
		for len(enc) > 0 {
			n := len(enc)
			if n > 63 {
				n = 63
			}
			labels = append(labels, enc[:n])
			enc = enc[n:]
		}
	}
	labels = append(labels, strconv.Itoa(seq), session, suffix)
	return dnsQuestion{labels: labels, qtype: 16, qclass: 1}
}

// ---------------------------------------------------------------------------
// Sesiones.
// ---------------------------------------------------------------------------

// session guarda el estado de un túnel: la conexión SSH, el búfer de
// bajada, el último seq visto y la última respuesta enviada.
type session struct {
	mu           sync.Mutex
	conn         net.Conn
	down         []byte // bajada leída del SSH y aún no enviada
	lastSeq      int
	lastResponse []byte
	lastActivity time.Time
	closed       bool
}

// server guarda las sesiones activas.
type server struct {
	cfg      config
	mu       sync.Mutex
	sessions map[string]*session
}

func newServer(cfg config) *server {
	return &server{cfg: cfg, sessions: make(map[string]*session)}
}

// getSession devuelve la sesión (creándola si no existe).
func (s *server) getSession(id string) *session {
	s.mu.Lock()
	defer s.mu.Unlock()
	sess, ok := s.sessions[id]
	if !ok {
		sess = &session{lastSeq: -1, lastActivity: time.Now()}
		s.sessions[id] = sess
	}
	return sess
}

// closeSession cierra una sesión y su conexión SSH.
func (s *server) closeSession(id string) {
	s.mu.Lock()
	sess, ok := s.sessions[id]
	if ok {
		delete(s.sessions, id)
	}
	s.mu.Unlock()
	if ok {
		sess.mu.Lock()
		sess.closed = true
		conn := sess.conn
		sess.conn = nil
		sess.mu.Unlock()
		if conn != nil {
			conn.Close()
		}
	}
}

// reap cierra las sesiones sin consultas desde hace más de sessionIdle.
func (s *server) reap() {
	for {
		time.Sleep(10 * time.Second)
		now := time.Now()
		s.mu.Lock()
		var idle []string
		for id, sess := range s.sessions {
			sess.mu.Lock()
			if now.Sub(sess.lastActivity) > sessionIdle {
				idle = append(idle, id)
			}
			sess.mu.Unlock()
		}
		s.mu.Unlock()
		for _, id := range idle {
			log.Printf("sesión %s cerrada por inactividad", id)
			s.closeSession(id)
		}
	}
}

// readLoop lee del SSH y lo guarda en el búfer de bajada de la sesión.
func (s *server) readLoop(id string, sess *session, conn net.Conn) {
	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			sess.mu.Lock()
			sess.down = append(sess.down, buf[:n]...)
			sess.mu.Unlock()
		}
		if err != nil {
			s.closeSession(id)
			return
		}
	}
}

// handleQuery procesa una consulta DNS ya parseada y devuelve el mensaje
// de respuesta. Aplica stop-and-wait: seq duplicado reenvía la última
// respuesta sin reprocesar la subida.
func (s *server) handleQuery(id uint16, q dnsQuestion) []byte {
	up, seq, sessionID, err := parseQNAME(q)
	if err != nil {
		log.Printf("FORMERR qname=%q: %v", q.qname(), err)
		return buildResponse(id, q, 1, "")
	}
	sess := s.getSession(sessionID)
	sess.mu.Lock()
	defer sess.mu.Unlock()
	sess.lastActivity = time.Now()

	// Duplicado: reenviar la última respuesta sin reprocesar la subida.
	if seq <= sess.lastSeq && sess.lastResponse != nil {
		log.Printf("seq=%d sesión=%s duplicado: reenvío (%d bytes)", seq, sessionID, len(sess.lastResponse))
		return sess.lastResponse
	}

	// Sin conexión SSH: marcar el destino (primera consulta o reintento).
	if sess.conn == nil {
		conn, err := net.DialTimeout("tcp", s.cfg.target, 10*time.Second)
		if err != nil {
			log.Printf("seq=%d sesión=%s SERVFAIL: no se puede marcar %s: %v", seq, sessionID, s.cfg.target, err)
			resp := buildResponse(id, q, 2, "")
			sess.lastSeq = seq
			sess.lastResponse = resp
			return resp
		}
		sess.conn = conn
		go s.readLoop(sessionID, sess, conn)
		log.Printf("seq=%d sesión=%s SSH conectado a %s", seq, sessionID, s.cfg.target)
	}

	// Procesar la subida.
	if len(up) > 0 {
		if _, err := sess.conn.Write(up); err != nil {
			log.Printf("seq=%d sesión=%s SERVFAIL: escritura al SSH falló: %v", seq, sessionID, err)
			resp := buildResponse(id, q, 2, "")
			sess.lastSeq = seq
			sess.lastResponse = resp
			return resp
		}
	}

	// Bajada: hasta maxDownloadBytes del búfer. Dar un momento al SSH
	// para responder (si no hay nada, la respuesta sale vacía y el
	// cliente sondea de nuevo).
	if len(sess.down) == 0 {
		sess.mu.Unlock()
		time.Sleep(20 * time.Millisecond)
		sess.mu.Lock()
	}
	n := len(sess.down)
	if n > maxDownloadBytes {
		n = maxDownloadBytes
	}
	down := sess.down[:n]
	sess.down = sess.down[n:]
	downB32 := encodeB32(down)
	resp := buildResponse(id, q, 0, downB32)
	sess.lastSeq = seq
	sess.lastResponse = resp
	log.Printf("seq=%d sesión=%s 200 up=%d down=%d", seq, sessionID, len(up), len(down))
	return resp
}

// ---------------------------------------------------------------------------
// HTTP (RFC 8484).
// ---------------------------------------------------------------------------

// writeError contesta un error HTTP con cuerpo vacío.
func writeError(w http.ResponseWriter, code int) {
	w.WriteHeader(code)
}

// handler es el manejador de /dns-query.
func (s *server) handler(w http.ResponseWriter, r *http.Request) {
	remote := r.RemoteAddr
	if r.URL.Path != "/dns-query" {
		log.Printf("%s 400 ruta=%s", remote, r.URL.Path)
		writeError(w, http.StatusBadRequest)
		return
	}
	var msg []byte
	switch r.Method {
	case http.MethodPost:
		if r.Header.Get("Content-Type") != "application/dns-message" {
			log.Printf("%s 400 content-type=%q", remote, r.Header.Get("Content-Type"))
			writeError(w, http.StatusBadRequest)
			return
		}
		body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxQueryBytes))
		if err != nil {
			log.Printf("%s 400 cuerpo ilegible: %v", remote, err)
			writeError(w, http.StatusBadRequest)
			return
		}
		msg = body
	case http.MethodGet:
		enc := r.URL.Query().Get("dns")
		if enc == "" {
			log.Printf("%s 400 GET sin parámetro dns", remote)
			writeError(w, http.StatusBadRequest)
			return
		}
		decoded, err := base64.RawURLEncoding.DecodeString(enc)
		if err != nil {
			log.Printf("%s 400 dns base64url inválido: %v", remote, err)
			writeError(w, http.StatusBadRequest)
			return
		}
		msg = decoded
	default:
		log.Printf("%s 400 método=%s", remote, r.Method)
		writeError(w, http.StatusBadRequest)
		return
	}
	if !validToken(r.Header.Get("X-Mustafa-Token"), s.cfg.password) {
		log.Printf("%s 403 token inválido o ausente", remote)
		writeError(w, http.StatusForbidden)
		return
	}
	id, q, err := parseQuery(msg)
	if err != nil {
		log.Printf("%s FORMERR: %v", remote, err)
		// Sin pregunta válida no se puede construir una respuesta DNS;
		// se contesta 400.
		writeError(w, http.StatusBadRequest)
		return
	}
	if q.qtype != 16 || q.qclass != 1 {
		log.Printf("%s FORMERR qtype=%d qclass=%d", remote, q.qtype, q.qclass)
		resp := buildResponse(id, q, 1, "")
		w.Header().Set("Content-Type", "application/dns-message")
		w.WriteHeader(http.StatusOK)
		w.Write(resp)
		return
	}
	resp := s.handleQuery(id, q)
	w.Header().Set("Content-Type", "application/dns-message")
	w.WriteHeader(http.StatusOK)
	w.Write(resp)
}

// ---------------------------------------------------------------------------
// Main.
// ---------------------------------------------------------------------------

func main() {
	log.SetFlags(log.LstdFlags)
	showVersion := flag.Bool("version", false, "imprime la versión y sale")
	listen := flag.String("listen", ":8053", "dirección de escucha")
	target := flag.String("target", "127.0.0.1:22", "destino SSH")
	password := flag.String("password", "", "contraseña (token)")
	passwordFile := flag.String("password-file", "", "archivo con la contraseña")
	certFile := flag.String("cert", "", "certificado TLS")
	keyFile := flag.String("key", "", "clave privada TLS")
	flag.Parse()

	if *showVersion {
		fmt.Printf("doh-server %s\n", version)
		return
	}

	cfg := config{listen: *listen, target: *target, certFile: *certFile, keyFile: *keyFile}
	switch {
	case *password != "":
		cfg.password = *password
	case *passwordFile != "":
		data, err := os.ReadFile(*passwordFile)
		if err != nil {
			log.Fatalf("no se puede leer --password-file %s: %v", *passwordFile, err)
		}
		cfg.password = strings.TrimSpace(string(data))
	}
	if cfg.password == "" {
		log.Fatal("sin contraseña: pasa --password o --password-file")
	}
	if (*certFile == "") != (*keyFile == "") {
		log.Fatal("--cert y --key deben pasarse juntos (o ninguno, TCP plano)")
	}

	srv := newServer(cfg)
	go srv.reap()
	mux := http.NewServeMux()
	// Se registra en "/" (no solo en /dns-query): si no, el mux contesta
	// 404 para otras rutas antes de llegar al handler, y el spec pide
	// 400 para ruta distinta de /dns-query. El handler valida la ruta.
	mux.HandleFunc("/", srv.handler)
	httpSrv := &http.Server{
		Addr:         cfg.listen,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}
	if cfg.certFile != "" {
		log.Printf("doh-server %s escuchando en %s (TLS) -> %s", version, cfg.listen, cfg.target)
		log.Fatal(httpSrv.ListenAndServeTLS(cfg.certFile, cfg.keyFile))
	}
	log.Printf("doh-server %s escuchando en %s (TCP plano) -> %s", version, cfg.listen, cfg.target)
	log.Fatal(httpSrv.ListenAndServe())
}
