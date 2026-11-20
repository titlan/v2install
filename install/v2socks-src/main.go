// v2socks-server: servidor del protocolo v2socks.
//
// Un solo proceso hace todo:
//   - Señalización HTTPS: POST /v2socks/signal {password, offer} -> {answer}
//   - WebRTC (pion): un canal de datos por conexión TCP.
//   - Puente: cada canal se conecta por TCP al destino que pide el cliente
//     (controlado por --allow; por defecto solo loopback).
//
// Uso:
//   v2socks-server --password SECRETO --signal-addr :443 --udp-port 3478 \
//     --cert /etc/v2socks/cert.pem --key /etc/v2socks/key.pem \
//     --allow 127.0.0.1:* --allow 10.0.0.0/8
// Sin --cert/--key sirve la señalización por HTTP sin cifrar (solo para
// pruebas en red local; la contraseña viajaría en claro).
package main

import (
	"crypto/subtle"
	"encoding/json"
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

	"github.com/pion/ice/v4"
	"github.com/pion/webrtc/v4"
)

const (
	channelLabel = "v2socks"
	maxChunk     = 16 * 1024 // trozo máximo por mensaje del canal de datos
)

// ------------------------------------------------------------------
// Configuración
// ------------------------------------------------------------------

type allowRule struct {
	cidr    *net.IPNet // si no es nil, coincide por red (cualquier puerto)
	host    string     // si cidr es nil, host exacto o IP
	port    int        // -1 = cualquier puerto
	allowAll bool
}

type config struct {
	signalAddr  string
	udpPort     int
	password    string
	certFile    string
	keyFile     string
	publicIP    string
	allow       []allowRule
	networkTypes []webrtc.NetworkType // vacío = UDP4+UDP6 (TCP solo para pruebas)
	// Solo para pruebas: habilita ICE-TCP y candidatos loopback, porque
	// el sandbox de pruebas bloquea UDP. En producción es UDP puro.
	enableTCPMux    bool
	includeLoopback bool
}

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

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
// Señalización
// ------------------------------------------------------------------

type signalRequest struct {
	Password string `json:"password"`
	Offer    string `json:"offer"`
}

type signalResponse struct {
	Answer string `json:"answer"`
}

type server struct {
	cfg *config
	api *webrtc.API
}

func (s *server) handleSignal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "solo POST", http.StatusMethodNotAllowed)
		return
	}
	var req signalRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "JSON inválido", http.StatusBadRequest)
		return
	}
	if subtle.ConstantTimeCompare([]byte(req.Password), []byte(s.cfg.password)) != 1 {
		http.Error(w, "contraseña incorrecta", http.StatusUnauthorized)
		log.Printf("señalización: contraseña incorrecta desde %s", r.RemoteAddr)
		return
	}
	if req.Offer == "" {
		http.Error(w, "falta offer", http.StatusBadRequest)
		return
	}

	pc, err := s.api.NewPeerConnection(webrtc.Configuration{})
	if err != nil {
		log.Printf("señalización: NewPeerConnection: %v", err)
		http.Error(w, "error interno", http.StatusInternalServerError)
		return
	}
	pc.OnDataChannel(func(dc *webrtc.DataChannel) {
		if dc.Label() != channelLabel {
			log.Printf("canal con etiqueta inesperada %q, se ignora", dc.Label())
			return
		}
		s.handleChannel(pc, dc)
	})
	pc.OnICEConnectionStateChange(func(state webrtc.ICEConnectionState) {
		log.Printf("peer %s: estado ICE %s", r.RemoteAddr, state.String())
	})
	pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		log.Printf("peer %s: estado conexión %s", r.RemoteAddr, state.String())
	})

	if err := pc.SetRemoteDescription(webrtc.SessionDescription{
		Type: webrtc.SDPTypeOffer, SDP: req.Offer,
	}); err != nil {
		log.Printf("señalización: SetRemoteDescription: %v", err)
		http.Error(w, "oferta inválida", http.StatusBadRequest)
		pc.Close()
		return
	}
	answer, err := pc.CreateAnswer(nil)
	if err != nil {
		log.Printf("señalización: CreateAnswer: %v", err)
		http.Error(w, "error interno", http.StatusInternalServerError)
		pc.Close()
		return
	}
	if err := pc.SetLocalDescription(answer); err != nil {
		log.Printf("señalización: SetLocalDescription: %v", err)
		http.Error(w, "error interno", http.StatusInternalServerError)
		pc.Close()
		return
	}

	// Esperar a que el gathering ICE termine (sin trickle: la respuesta
	// lleva los candidatos ya dentro).
	select {
	case <-webrtc.GatheringCompletePromise(pc):
	case <-time.After(10 * time.Second):
		log.Printf("señalización: gathering ICE lento, se devuelve lo que hay")
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(signalResponse{Answer: pc.LocalDescription().SDP})
	log.Printf("señalización: peer conectado desde %s", r.RemoteAddr)
}

// ------------------------------------------------------------------
// Canal de datos -> TCP
// ------------------------------------------------------------------

type destHeader struct {
	Host string `json:"host"`
	Port int    `json:"port"`
}

func (s *server) handleChannel(pc *webrtc.PeerConnection, dc *webrtc.DataChannel) {
	var once sync.Once
	var conn net.Conn
	done := make(chan struct{})
	closeAll := func() {
		once.Do(func() {
			close(done)
			if conn != nil {
				conn.Close()
			}
			dc.Close()
			pc.Close()
		})
	}

	dc.OnClose(func() { closeAll() })
	dc.OnError(func(err error) {
		log.Printf("canal: error: %v", err)
		closeAll()
	})

	first := true
	dc.OnMessage(func(msg webrtc.DataChannelMessage) {
		if first {
			first = false
			var h destHeader
			if err := json.Unmarshal(msg.Data, &h); err != nil {
				log.Printf("canal: cabecera inválida: %v", err)
				closeAll()
				return
			}
			if h.Host == "" || h.Port <= 0 || h.Port > 65535 {
				log.Printf("canal: destino inválido %+v", h)
				closeAll()
				return
			}
			if !s.cfg.allowed(h.Host, h.Port) {
				log.Printf("canal: destino no permitido %s:%d", h.Host, h.Port)
				closeAll()
				return
			}
			c, err := net.DialTimeout("tcp", net.JoinHostPort(h.Host, strconv.Itoa(h.Port)), 10*time.Second)
			if err != nil {
				log.Printf("canal: no se pudo conectar a %s:%d: %v", h.Host, h.Port, err)
				closeAll()
				return
			}
			conn = c
			log.Printf("canal: puente abierto a %s:%d", h.Host, h.Port)
			// TCP -> canal de datos.
			go func() {
				buf := make([]byte, maxChunk)
				for {
					n, err := conn.Read(buf)
					if n > 0 {
						if sendErr := sendAll(dc, buf[:n]); sendErr != nil {
							log.Printf("canal: envío fallido: %v", sendErr)
							closeAll()
							return
						}
					}
					if err != nil {
						if err != io.EOF {
							log.Printf("canal: lectura TCP: %v", err)
						}
						closeAll()
						return
					}
				}
			}()
			return
		}
		// Mensajes siguientes: bytes crudos hacia el TCP.
		if conn == nil {
			return
		}
		if _, err := conn.Write(msg.Data); err != nil {
			log.Printf("canal: escritura TCP: %v", err)
			closeAll()
		}
	})
}

// Envía en trozos de maxChunk y espera si el buffer SCTP se llena.
func sendAll(dc *webrtc.DataChannel, data []byte) error {
	for len(data) > 0 {
		n := len(data)
		if n > maxChunk {
			n = maxChunk
		}
		// Control de flujo sencillo: si el buffer pasa de 256 KiB,
		// esperar un poco a que se vacíe.
		for dc.BufferedAmount() > 256*1024 {
			time.Sleep(10 * time.Millisecond)
		}
		if err := dc.Send(data[:n]); err != nil {
			return err
		}
		data = data[n:]
	}
	return nil
}

// newServer crea el servidor WebRTC con un solo puerto UDP (UDP mux)
// compartido por todas las conexiones.
func newServer(cfg *config) (*server, error) {
	udpAddr := &net.UDPAddr{IP: net.IPv4zero, Port: cfg.udpPort}
	udpConn, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		return nil, fmt.Errorf("no se pudo escuchar UDP :%d: %w", cfg.udpPort, err)
	}
	udpMux := ice.NewUDPMuxDefault(ice.UDPMuxParams{UDPConn: udpConn})

	se := webrtc.SettingEngine{}
	se.SetICEUDPMux(udpMux)
	if cfg.enableTCPMux {
		tcpListener, err := net.Listen("tcp", ":0")
		if err != nil {
			return nil, fmt.Errorf("no se pudo escuchar TCP para ICE-TCP: %w", err)
		}
		se.SetICETCPMux(ice.NewTCPMuxDefault(ice.TCPMuxParams{Listener: tcpListener}))
	}
	if cfg.includeLoopback {
		se.SetIncludeLoopbackCandidate(true)
	}
	types := cfg.networkTypes
	if len(types) == 0 {
		types = []webrtc.NetworkType{webrtc.NetworkTypeUDP4, webrtc.NetworkTypeUDP6}
	}
	se.SetNetworkTypes(types)
	if cfg.publicIP != "" {
		se.SetNAT1To1IPs([]string{cfg.publicIP}, webrtc.ICECandidateTypeHost)
	}
	api := webrtc.NewAPI(webrtc.WithSettingEngine(se))
	return &server{cfg: cfg, api: api}, nil
}

func main() {
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)

	var allowFlags multiFlag
	signalAddr := flag.String("signal-addr", ":443", "dirección TCP de la señalización HTTPS")
	udpPort := flag.Int("udp-port", 3478, "puerto UDP de WebRTC (un solo puerto)")
	password := flag.String("password", "", "contraseña del protocolo (o env V2SOCKS_PASSWORD)")
	passwordFile := flag.String("password-file", "", "archivo con la contraseña (una línea)")
	certFile := flag.String("cert", "", "certificado TLS para la señalización")
	keyFile := flag.String("key", "", "clave privada TLS para la señalización")
	publicIP := flag.String("public-ip", "", "IP pública a anunciar en ICE (si el VPS está detrás de NAT)")
	flag.Var(&allowFlags, "allow", "destino permitido (host:puerto, host:* o CIDR); se puede repetir")
	flag.Parse()

	pass := *password
	if pass == "" {
		pass = os.Getenv("V2SOCKS_PASSWORD")
	}
	if pass == "" && *passwordFile != "" {
		b, err := os.ReadFile(*passwordFile)
		if err != nil {
			log.Fatalf("no se pudo leer password-file: %v", err)
		}
		pass = strings.TrimSpace(string(b))
	}
	if pass == "" {
		log.Fatal("falta la contraseña: usa --password, V2SOCKS_PASSWORD o --password-file")
	}

	cfg := &config{
		signalAddr: *signalAddr,
		udpPort:    *udpPort,
		password:   pass,
		certFile:   *certFile,
		keyFile:    *keyFile,
		publicIP:   *publicIP,
	}
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

	// WebRTC: un solo puerto UDP para todas las conexiones (UDP mux).
	srv, err := newServer(cfg)
	if err != nil {
		log.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/v2socks/signal", srv.handleSignal)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	log.Printf("v2socks-server: señalización en %s, WebRTC UDP :%d, allow=%v",
		cfg.signalAddr, cfg.udpPort, allowFlags)
	if cfg.certFile != "" && cfg.keyFile != "" {
		log.Printf("v2socks-server: TLS activo (%s)", cfg.certFile)
		log.Fatal(http.ListenAndServeTLS(cfg.signalAddr, cfg.certFile, cfg.keyFile, mux))
	}
	log.Printf("AVISO: señalización sin TLS (solo para pruebas en red local); la contraseña viaja en claro")
	log.Fatal(http.ListenAndServe(cfg.signalAddr, mux))
}
