// chttp-server: servidor del protocolo CHTTP (v1).
//
// CHTTP es una versión propia y mejorada del protocolo binario BHTTP
// (de La Casita, NO es el Binary HTTP del RFC 9292). Cambios frente a BHTTP:
//   - Transporte TCP + TLS obligatorio (sin HTTP plano, sin falso "101").
//   - Autenticación por token en CADA request (SHA-256 de la contraseña).
//   - Cifrado AEAD AES-256-GCM con claves derivadas por dirección
//     (en lugar del XOR + keystream SHA-256 sin integridad).
//   - Upload idempotente (reintentos seguros) y Batch.
//   - Soporte de requests concurrentes sobre la misma sesión
//     (mutex por sesión; Upload y Download corren en paralelo).
//
// Protocolo (v1):
//
//	Request header 61B: [mode(1) | sid(16) | token(32) | seq BE64 | value BE32]
//	  mode: 0 Probe, 1 Upload, 2 Download, 3 Batch, 4 ACK, 5 Lane (v2, rechazado).
//	  token: SHA-256(password). value: largo del payload sellado.
//	Respuesta: [status(1) | len BE32 | payload]
//	  status 0 OK (plaintext vacío, salvo Probe -> "CHTP1"),
//	  1 Error (plaintext = texto UTF-8), 2 Data (plaintext = bytes del stream).
//	  TODAS las respuestas van selladas con AES-256-GCM (Error también:
//	  su plaintext es el texto UTF-8). Así el cliente Java descifra
//	  todas las respuestas igual, incluido un "bad token".
//	Claves: kup = SHA256(token || sid || "up"), kdown = SHA256(token || sid || "down").
//	Nonce 12B = seq BE64 || 0x00000000. Sellado = ciphertext || tag 16B.
//	Máximo plaintext por mensaje: 524272 bytes.
//
// Flujo: Probe -> Upload seq 0 (marca el SSH) -> Upload seq 1,2,3...
// -> Download seq 0,1,2... (polling) -> ACK. Sin Hello ni Close explícitos;
// la sesión se limpia tras 60s sin tráfico o al cerrarse el SSH.
//
// Uso:
//
//	chttp-server --password SECRETO --addr :8445 \
//	  --cert /etc/chttp/cert.pem --key /etc/chttp/key.pem \
//	  --ssh-addr 127.0.0.1:22 --allow 127.0.0.1:* --allow ::1:*
//
// Sin --cert/--key, --gen-cert genera un certificado autofirmado en memoria.
package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/binary"
	"encoding/hex"
	"encoding/pem"
	"flag"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	headerSize      = 61
	maxPlaintext    = 524272
	maxSealed       = maxPlaintext + 16 // GCM tag
	maxChunk        = 32 * 1024
	sessionIdleTTL  = 60 * time.Second
	downloadWaitMax = 5 * time.Second
	sshDialTimeout  = 10 * time.Second
)

const (
	modeProbe    = 0
	modeUpload   = 1
	modeDownload = 2
	modeBatch    = 3
	modeAck      = 4
	modeLane     = 5
)

const (
	statusOK    = 0
	statusError = 1
	statusData  = 2
)

// ------------------------------------------------------------------
// Configuración
// ------------------------------------------------------------------

type allowRule struct {
	cidr     *net.IPNet // si no es nil, coincide por red (cualquier puerto)
	host     string     // si cidr es nil, host exacto o IP
	port     int        // -1 = cualquier puerto
	allowAll bool
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

type config struct {
	addr          string
	password      string
	token         [32]byte // SHA-256(password)
	certFile      string
	keyFile       string
	genCert       bool
	sshAddr       string
	allow         []allowRule
	maxSessions   int
	maxSessionsIP int
}

func parseAllow(spec string) (allowRule, error) {
	if spec == "*" {
		return allowRule{allowAll: true}, nil
	}
	if strings.Contains(spec, "/") {
		_, cidr, err := net.ParseCIDR(spec)
		if err != nil {
			return allowRule{}, fmt.Errorf("allow inválido %q: %v", spec, err)
		}
		return allowRule{cidr: cidr}, nil
	}
	host, portStr, err := net.SplitHostPort(spec)
	if err != nil {
		// Sin puerto: host con cualquier puerto.
		return allowRule{host: spec, port: -1}, nil
	}
	if portStr == "*" {
		return allowRule{host: host, port: -1}, nil
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return allowRule{}, fmt.Errorf("allow inválido %q: puerto no numérico", spec)
	}
	return allowRule{host: host, port: port}, nil
}

func (c *config) allowed(host string, port int) bool {
	ip := net.ParseIP(host)
	for _, r := range c.allow {
		if r.allowAll {
			return true
		}
		if r.cidr != nil {
			if ip != nil && r.cidr.Contains(ip) {
				return true
			}
			continue
		}
		hostOK := false
		if r.host == host {
			hostOK = true
		} else if rip := net.ParseIP(r.host); rip != nil && ip != nil && rip.Equal(ip) {
			hostOK = true
		}
		if hostOK && (r.port == -1 || r.port == port) {
			return true
		}
	}
	return false
}

// ------------------------------------------------------------------
// AEAD: AES-256-GCM, claves por dirección, nonce = seq BE64 || ceros
// ------------------------------------------------------------------

func deriveKeys(token [32]byte, sid [16]byte) (up, down cipher.AEAD, err error) {
	upKey := sha256.Sum256(append(append(append([]byte{}, token[:]...), sid[:]...), []byte("up")...))
	downKey := sha256.Sum256(append(append(append([]byte{}, token[:]...), sid[:]...), []byte("down")...))
	up, err = newGCM(upKey[:])
	if err != nil {
		return nil, nil, err
	}
	down, err = newGCM(downKey[:])
	if err != nil {
		return nil, nil, err
	}
	return up, down, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func nonceFor(seq int64) []byte {
	n := make([]byte, 12)
	binary.BigEndian.PutUint64(n[:8], uint64(seq))
	// últimos 4 bytes en cero
	return n
}

func seal(aead cipher.AEAD, seq int64, plaintext []byte) []byte {
	return aead.Seal(nil, nonceFor(seq), plaintext, nil)
}

func openSealed(aead cipher.AEAD, seq int64, sealed []byte) ([]byte, error) {
	return aead.Open(nil, nonceFor(seq), sealed, nil)
}

// ------------------------------------------------------------------
// Sesión
//
// Una sesión = un sid de 16B + una conexión SSH. Cada request llega por
// su propia conexión TLS; Upload y Download corren en paralelo y hasta
// 4 Downloads pueden estar en vuelo sobre la misma sesión, así que todo
// el estado mutable vive detrás de mu (mutex por sesión).
// ------------------------------------------------------------------

type session struct {
	mu       sync.Mutex
	sid      [16]byte
	sidHex   string
	clientIP string
	created  time.Time
	lastSeen time.Time

	token    [32]byte
	upAEAD   cipher.AEAD
	downAEAD cipher.AEAD

	sshConn   net.Conn
	dialed    bool
	sshDone   bool // el SSH se cerró (EOF/error del reader)
	closed    bool // sesión marcada para limpieza
	endLogged bool

	lastUploadSeq int64 // último seq de Upload aplicado (-1 = ninguno)
	pending       map[int64][]byte

	// Buffer de descarga: dlBuf son los bytes del stream desde dlBase.
	dlBase int64
	dlBuf  []byte
	dlDone bool
	// sent[seq] = bytes ya devueltos para ese seq (para ACK y reintentos).
	sent      map[int64]int
	lastAcked int64

	bytesUp   int64
	bytesDown int64
}

func (s *session) touch() {
	s.lastSeen = time.Now()
}

// ---- servidor ----

type server struct {
	cfg *config

	mu       sync.Mutex
	sessions map[string]*session
	perIP    map[string]int
}

func newServer(cfg *config) *server {
	return &server{
		cfg:      cfg,
		sessions: make(map[string]*session),
		perIP:    make(map[string]int),
	}
}

func (s *server) getOrCreateSession(sid [16]byte, token [32]byte, clientIP string) (*session, error) {
	key := hex.EncodeToString(sid[:])
	s.mu.Lock()
	defer s.mu.Unlock()
	if sess, ok := s.sessions[key]; ok {
		return sess, nil
	}
	if len(s.sessions) >= s.cfg.maxSessions {
		return nil, fmt.Errorf("demasiadas sesiones activas")
	}
	if s.perIP[clientIP] >= s.cfg.maxSessionsIP {
		return nil, fmt.Errorf("demasiadas sesiones desde esta IP")
	}
	upAEAD, downAEAD, err := deriveKeys(token, sid)
	if err != nil {
		return nil, err
	}
	now := time.Now()
	sess := &session{
		sid:           sid,
		sidHex:        key,
		clientIP:      clientIP,
		created:       now,
		lastSeen:      now,
		token:         token,
		upAEAD:        upAEAD,
		downAEAD:      downAEAD,
		lastUploadSeq: -1,
		pending:       make(map[int64][]byte),
		sent:          make(map[int64]int),
		lastAcked:     -1,
	}
	s.sessions[key] = sess
	s.perIP[clientIP]++
	log.Printf("sesión inicio sid=%s ip=%s", key[:12], clientIP)
	return sess, nil
}

// removeSession borra la sesión del mapa (la llama el reaper).
// Cierra el SSH si sigue abierto y escribe la línea de fin.
func (s *server) removeSession(sess *session) {
	s.mu.Lock()
	_, ok := s.sessions[sess.sidHex]
	if ok {
		delete(s.sessions, sess.sidHex)
		if s.perIP[sess.clientIP] > 0 {
			s.perIP[sess.clientIP]--
		}
	}
	s.mu.Unlock()
	if !ok {
		return
	}
	sess.mu.Lock()
	if sess.sshConn != nil {
		sess.sshConn.Close()
	}
	if !sess.endLogged {
		sess.endLogged = true
		log.Printf("sesión fin sid=%s ip=%s up=%d down=%d dur=%s",
			sess.sidHex[:12], sess.clientIP, sess.bytesUp, sess.bytesDown,
			time.Since(sess.created).Round(time.Second))
	}
	sess.mu.Unlock()
}

// reaper: limpia sesiones sin tráfico 60s o ya cerradas.
func (s *server) reaper() {
	for {
		time.Sleep(15 * time.Second)
		now := time.Now()
		s.mu.Lock()
		var stale []*session
		for _, sess := range s.sessions {
			sess.mu.Lock()
			idle := sess.closed || now.Sub(sess.lastSeen) > sessionIdleTTL
			sess.mu.Unlock()
			if idle {
				stale = append(stale, sess)
			}
		}
		s.mu.Unlock()
		for _, sess := range stale {
			s.removeSession(sess)
		}
	}
}

// ---- entrada: una conexión TLS = un request ----

func (s *server) handleConn(conn net.Conn) {
	defer conn.Close()
	remoteIP, _, _ := net.SplitHostPort(conn.RemoteAddr().String())

	// Header 61B exacto.
	hdr := make([]byte, headerSize)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		return
	}
	mode := hdr[0]
	var sid [16]byte
	copy(sid[:], hdr[1:17])
	var token [32]byte
	copy(token[:], hdr[17:49])
	seq := int64(binary.BigEndian.Uint64(hdr[49:57]))
	value := binary.BigEndian.Uint32(hdr[57:61])

	// AEAD de bajada para esta conexión (derivado del token del header).
	_, reqDown, err := deriveKeys(token, sid)
	if err != nil {
		return
	}

	// Modo válido antes que nada (Lane es v2).
	if mode > modeLane {
		writeError(conn, reqDown, seq, "bad mode")
		return
	}

	// Token en CADA request, comparación en tiempo constante.
	if subtle.ConstantTimeCompare(token[:], s.cfg.token[:]) != 1 {
		log.Printf("bad token desde %s (sid=%s mode=%d)", remoteIP, hex.EncodeToString(sid[:])[:12], mode)
		writeError(conn, reqDown, seq, "bad token")
		return
	}

	if value > maxSealed {
		writeError(conn, reqDown, seq, "payload too large")
		return
	}

	// Payload sellado (puede ser vacío).
	var sealed []byte
	if value > 0 {
		sealed = make([]byte, value)
		if _, err := io.ReadFull(conn, sealed); err != nil {
			return
		}
	}

	sess, err := s.getOrCreateSession(sid, token, remoteIP)
	if err != nil {
		log.Printf("sesión rechazada ip=%s: %v", remoteIP, err)
		writeError(conn, reqDown, seq, err.Error())
		return
	}

	sess.mu.Lock()
	sess.touch()
	closed := sess.closed
	sess.mu.Unlock()
	if closed {
		writeError(conn, reqDown, seq, "session closed")
		return
	}

	if mode == modeLane {
		writeError(conn, reqDown, seq, "lane not supported in v1")
		return
	}

	// Descifrar el payload (salvo Probe con value 0, que no trae nada).
	var plain []byte
	if len(sealed) > 0 {
		plain, err = openSealed(sess.upAEAD, seq, sealed)
		if err != nil {
			writeError(conn, reqDown, seq, "decrypt failed")
			return
		}
		if len(plain) > maxPlaintext {
			writeError(conn, reqDown, seq, "plaintext too large")
			return
		}
	}
	sess.mu.Lock()
	sess.bytesUp += int64(len(sealed))
	sess.mu.Unlock()

	switch mode {
	case modeProbe:
		s.handleProbe(conn, sess, seq)
	case modeUpload:
		s.handleUpload(conn, sess, seq, plain)
	case modeDownload:
		s.handleDownload(conn, sess, seq)
	case modeBatch:
		s.handleBatch(conn, sess, seq, plain)
	case modeAck:
		s.handleAck(conn, sess, seq)
	default:
		writeError(conn, reqDown, seq, "bad mode")
	}
}

// ---- respuestas ----

// writeSealed escribe [status | len BE32 | sealed].
func writeSealed(conn net.Conn, status byte, sealed []byte) {
	out := make([]byte, 1+4+len(sealed))
	out[0] = status
	binary.BigEndian.PutUint32(out[1:5], uint32(len(sealed)))
	copy(out[5:], sealed)
	conn.Write(out)
}

// writeError sella el texto del error con el AEAD de bajada y el seq del
// request (el cliente deriva las mismas claves del token que envió, así que
// puede descifrarlo aunque el token sea incorrecto).
func writeError(conn net.Conn, down cipher.AEAD, seq int64, msg string) {
	writeSealed(conn, statusError, seal(down, seq, []byte(msg)))
}

// writeOK sella un plaintext (vacío en general) con kdown y el seq dado.
func (s *server) writeOK(conn net.Conn, sess *session, seq int64, plain []byte) {
	sess.mu.Lock()
	sealed := seal(sess.downAEAD, seq, plain)
	sess.bytesDown += int64(len(sealed))
	sess.mu.Unlock()
	writeSealed(conn, statusOK, sealed)
}

// writeData sella los bytes del stream con kdown y el seq dado.
func (s *server) writeData(conn net.Conn, sess *session, seq int64, plain []byte) {
	sess.mu.Lock()
	sealed := seal(sess.downAEAD, seq, plain)
	sess.bytesDown += int64(len(sealed))
	sess.mu.Unlock()
	writeSealed(conn, statusData, sealed)
}

// ------------------------------------------------------------------
// Handlers por modo
// ------------------------------------------------------------------

func (s *server) handleProbe(conn net.Conn, sess *session, seq int64) {
	// Probe verifica el token (ya hecho) y responde "CHTP1" sellado.
	s.writeOK(conn, sess, seq, []byte("CHTP1"))
}

func (s *server) handleUpload(conn net.Conn, sess *session, seq int64, plain []byte) {
	sess.mu.Lock()
	if sess.closed {
		sess.mu.Unlock()
		writeError(conn, sess.downAEAD, seq, "session closed")
		return
	}
	// Idempotente: un seq ya aplicado se responde OK sin reaplicar.
	// Esto es lo que hace seguros los reintentos del cliente.
	if seq <= sess.lastUploadSeq {
		sess.mu.Unlock()
		s.writeOK(conn, sess, seq, nil)
		return
	}
	// Hueco: guardar para cuando llegue el seq que falta.
	if seq > sess.lastUploadSeq+1 {
		if _, ok := sess.pending[seq]; !ok {
			cp := make([]byte, len(plain))
			copy(cp, plain)
			sess.pending[seq] = cp
		}
		sess.mu.Unlock()
		s.writeOK(conn, sess, seq, nil)
		return
	}
	// seq == lastUploadSeq+1: aplicar este y los pendientes consecutivos.
	err := s.applyUploadLocked(sess, seq, plain)
	for err == nil {
		next := sess.lastUploadSeq + 1
		p, ok := sess.pending[next]
		if !ok {
			break
		}
		delete(sess.pending, next)
		err = s.applyUploadLocked(sess, next, p)
	}
	sess.mu.Unlock()
	if err != nil {
		writeError(conn, sess.downAEAD, seq, err.Error())
		return
	}
	s.writeOK(conn, sess, seq, nil)
}

// applyUploadLocked aplica un Upload cuyo seq es exactamente
// lastUploadSeq+1. El llamador tiene sess.mu. Marca el SSH en seq 0.
func (s *server) applyUploadLocked(sess *session, seq int64, plain []byte) error {
	if seq == 0 && !sess.dialed {
		if sess.sshDone {
			sess.closed = true
			return fmt.Errorf("session closed")
		}
		if err := s.dialSSH(sess); err != nil {
			sess.closed = true
			return err
		}
	}
	if sess.sshDone {
		sess.closed = true
		return fmt.Errorf("session closed")
	}
	if len(plain) > 0 {
		if _, err := sess.sshConn.Write(plain); err != nil {
			sess.sshDone = true
			sess.closed = true
			return fmt.Errorf("ssh write failed")
		}
	}
	sess.lastUploadSeq = seq
	return nil
}

// dialSSH conecta al SSH (con allow-list) y arranca el lector.
// El llamador tiene sess.mu.
func (s *server) dialSSH(sess *session) error {
	host, portStr, err := net.SplitHostPort(s.cfg.sshAddr)
	if err != nil {
		return fmt.Errorf("ssh-addr inválido: %v", err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		return fmt.Errorf("ssh-addr inválido: puerto no numérico")
	}
	if !s.cfg.allowed(host, port) {
		return fmt.Errorf("ssh target no permitido")
	}
	c, err := net.DialTimeout("tcp", s.cfg.sshAddr, sshDialTimeout)
	if err != nil {
		log.Printf("sesión sid=%s: no se pudo marcar SSH %s: %v", sess.sidHex[:12], s.cfg.sshAddr, err)
		return fmt.Errorf("ssh dial failed")
	}
	sess.sshConn = c
	sess.dialed = true
	go s.sshReader(sess)
	log.Printf("sesión sid=%s ip=%s: SSH marcado a %s", sess.sidHex[:12], sess.clientIP, s.cfg.sshAddr)
	return nil
}

// sshReader bombea SSH -> buffer de descarga hasta EOF/error.
func (s *server) sshReader(sess *session) {
	buf := make([]byte, maxChunk)
	for {
		n, err := sess.sshConn.Read(buf)
		sess.mu.Lock()
		if n > 0 {
			sess.dlBuf = append(sess.dlBuf, buf[:n]...)
		}
		if err != nil {
			sess.dlDone = true
			sess.sshDone = true
			sess.mu.Unlock()
			return
		}
		sess.mu.Unlock()
	}
}

func (s *server) handleDownload(conn net.Conn, sess *session, seq int64) {
	if seq < 0 {
		writeError(conn, sess.downAEAD, seq, "bad seq")
		return
	}
	deadline := time.Now().Add(downloadWaitMax)
	for {
		sess.mu.Lock()
		if sess.closed {
			sess.mu.Unlock()
			writeError(conn, sess.downAEAD, seq, "session closed")
			return
		}
		start := seq*maxChunk - sess.dlBase
		if start < 0 {
			// Chunk ya confirmado (ACK) y borrado: no hay nada que devolver.
			sess.mu.Unlock()
			s.writeOK(conn, sess, seq, nil)
			return
		}
		avail := int64(len(sess.dlBuf)) - start
		if take, ok := sess.sent[seq]; ok {
			// Reintento del mismo seq: devolver exactamente lo mismo.
			data := make([]byte, take)
			copy(data, sess.dlBuf[start:start+int64(take)])
			sess.mu.Unlock()
			s.writeData(conn, sess, seq, data)
			return
		}
		if avail > 0 {
			take := avail
			if take > maxChunk {
				take = maxChunk
			}
			data := make([]byte, take)
			copy(data, sess.dlBuf[start:start+take])
			sess.sent[seq] = int(take)
			sess.mu.Unlock()
			s.writeData(conn, sess, seq, data)
			return
		}
		if sess.dlDone {
			sess.mu.Unlock()
			s.writeOK(conn, sess, seq, nil)
			return
		}
		sess.mu.Unlock()
		if time.Now().After(deadline) {
			// Nada todavía: OK vacío, el cliente vuelve a preguntar.
			s.writeOK(conn, sess, seq, nil)
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (s *server) handleBatch(conn net.Conn, sess *session, seq int64, plain []byte) {
	// Payload = concat de [len BE32 | sub-payload], seqs consecutivos
	// desde el seq del header. La respuesta se sella con el seq del header.
	headerSeq := seq
	off := 0
	for off < len(plain) {
		if off+4 > len(plain) {
			writeError(conn, sess.downAEAD, seq, "bad batch")
			return
		}
		n := int(binary.BigEndian.Uint32(plain[off : off+4]))
		off += 4
		if n < 0 || off+n > len(plain) {
			writeError(conn, sess.downAEAD, seq, "bad batch")
			return
		}
		sub := plain[off : off+n]
		off += n
		if err := s.applyUploadPart(sess, seq, sub); err != nil {
			writeError(conn, sess.downAEAD, seq, err.Error())
			return
		}
		seq++
	}
	s.writeOK(conn, sess, headerSeq, nil)
}

// applyUploadPart aplica UNA parte de un Batch con la misma idempotencia
// que un Upload normal. Devuelve error si la sesión está cerrada o el
// SSH falla; los huecos se guardan en pending como en Upload.
func (s *server) applyUploadPart(sess *session, seq int64, plain []byte) error {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.closed {
		return fmt.Errorf("session closed")
	}
	if seq <= sess.lastUploadSeq {
		return nil
	}
	if seq > sess.lastUploadSeq+1 {
		if _, ok := sess.pending[seq]; !ok {
			cp := make([]byte, len(plain))
			copy(cp, plain)
			sess.pending[seq] = cp
		}
		return nil
	}
	if err := s.applyUploadLocked(sess, seq, plain); err != nil {
		return err
	}
	for {
		next := sess.lastUploadSeq + 1
		p, ok := sess.pending[next]
		if !ok {
			break
		}
		delete(sess.pending, next)
		if err := s.applyUploadLocked(sess, next, p); err != nil {
			return err
		}
	}
	return nil
}

func (s *server) handleAck(conn net.Conn, sess *session, seq int64) {
	sess.mu.Lock()
	if take, ok := sess.sent[seq]; ok {
		newBase := seq*maxChunk + int64(take)
		if newBase > sess.dlBase {
			drop := newBase - sess.dlBase
			if drop >= int64(len(sess.dlBuf)) {
				sess.dlBuf = sess.dlBuf[:0]
			} else {
				sess.dlBuf = append([]byte(nil), sess.dlBuf[drop:]...)
			}
			sess.dlBase = newBase
		}
		for q := range sess.sent {
			if q <= seq {
				delete(sess.sent, q)
			}
		}
		if seq > sess.lastAcked {
			sess.lastAcked = seq
		}
	}
	sess.mu.Unlock()
	s.writeOK(conn, sess, seq, nil)
}

// ------------------------------------------------------------------
// Certificado autofirmado (solo con --gen-cert)
// ------------------------------------------------------------------

func genSelfSignedCert() (tls.Certificate, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return tls.Certificate{}, err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return tls.Certificate{}, err
	}
	tmpl := x509.Certificate{
		SerialNumber: serial,
		Subject:      pkix.Name{CommonName: "chttp"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(3650 * 24 * time.Hour),
		KeyUsage:     x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		DNSNames:     []string{"localhost"},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		return tls.Certificate{}, err
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return tls.Certificate{}, err
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return tls.X509KeyPair(certPEM, keyPEM)
}

// ------------------------------------------------------------------
// main
// ------------------------------------------------------------------

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var allowFlags multiFlag
	addr := flag.String("addr", ":8445", "dirección TCP/TLS de escucha")
	password := flag.String("password", "", "contraseña del protocolo (o env CHTTP_PASSWORD)")
	passwordFile := flag.String("password-file", "", "archivo con la contraseña (una línea)")
	certFile := flag.String("cert", "", "certificado TLS")
	keyFile := flag.String("key", "", "clave privada TLS")
	genCert := flag.Bool("gen-cert", false, "generar certificado autofirmado en memoria si no hay --cert/--key")
	sshAddr := flag.String("ssh-addr", "127.0.0.1:22", "destino SSH al que se puentea")
	maxSessions := flag.Int("max-sessions", 100, "máximo de sesiones activas")
	maxSessionsIP := flag.Int("max-sessions-per-ip", 5, "máximo de sesiones por IP")
	flag.Var(&allowFlags, "allow", "destino permitido (host:puerto, host:* o CIDR); se puede repetir")
	flag.Parse()

	pass := *password
	if pass == "" {
		pass = os.Getenv("CHTTP_PASSWORD")
	}
	if pass == "" && *passwordFile != "" {
		b, err := os.ReadFile(*passwordFile)
		if err != nil {
			log.Fatalf("no se pudo leer password-file: %v", err)
		}
		pass = strings.TrimSpace(string(b))
	}
	if pass == "" {
		log.Fatal("falta la contraseña: usa --password, CHTTP_PASSWORD o --password-file")
	}

	cfg := &config{
		addr:          *addr,
		password:      pass,
		sshAddr:       *sshAddr,
		certFile:      *certFile,
		keyFile:       *keyFile,
		genCert:       *genCert,
		maxSessions:   *maxSessions,
		maxSessionsIP: *maxSessionsIP,
	}
	cfg.token = sha256.Sum256([]byte(pass))
	if len(allowFlags) == 0 {
		allowFlags = multiFlag{"127.0.0.1:*", "::1:*"}
	}
	for _, spec := range allowFlags {
		r, err := parseAllow(spec)
		if err != nil {
			log.Fatalf("allow: %v", err)
		}
		cfg.allow = append(cfg.allow, r)
	}

	var tlsCert tls.Certificate
	var err error
	if cfg.certFile != "" && cfg.keyFile != "" {
		tlsCert, err = tls.LoadX509KeyPair(cfg.certFile, cfg.keyFile)
		if err != nil {
			log.Fatalf("no se pudo cargar cert/key: %v", err)
		}
		log.Printf("chttp-server: TLS con certificado %s", cfg.certFile)
	} else if cfg.genCert {
		tlsCert, err = genSelfSignedCert()
		if err != nil {
			log.Fatalf("no se pudo generar certificado: %v", err)
		}
		log.Printf("chttp-server: TLS con certificado autofirmado generado en memoria")
	} else {
		log.Fatal("falta TLS: usa --cert/--key o --gen-cert (CHTTP siempre va con TLS)")
	}

	srv := newServer(cfg)
	go srv.reaper()

	ln, err := net.Listen("tcp", cfg.addr)
	if err != nil {
		log.Fatalf("no se pudo escuchar %s: %v", cfg.addr, err)
	}
	tlsLn := tls.NewListener(ln, &tls.Config{
		Certificates: []tls.Certificate{tlsCert},
		MinVersion:   tls.VersionTLS12,
	})
	log.Printf("chttp-server: escuchando en %s (TLS), SSH -> %s, max-sessions=%d/%d por IP",
		cfg.addr, cfg.sshAddr, cfg.maxSessions, cfg.maxSessionsIP)
	for {
		conn, err := tlsLn.Accept()
		if err != nil {
			log.Printf("accept: %v", err)
			continue
		}
		go srv.handleConn(conn)
	}
}
