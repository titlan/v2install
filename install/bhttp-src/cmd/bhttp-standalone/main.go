package main

import (
    "flag"
    "log"
    "net"
    "os"
    "os/signal"
    "syscall"
    "time"

    "shell2/internal/bhttp"
)

func main() {
    listen := flag.String("listen", ":8081", "Direccion de escucha")
    target := flag.String("target", "127.0.0.1:22", "Destino SSH")
    sessionTimeout := flag.Duration("session-timeout", 2*time.Minute, "Tiempo de sesion")
    dialTimeout := flag.Duration("dial-timeout", 10*time.Second, "Tiempo de conexion")
    maxV2Lanes := flag.Int("max-v2-lanes", 128, "Maximo de canales V2")
    maxConnections := flag.Int("max-connections", 1024, "Maximo de conexiones")
    maxSessions := flag.Int("max-sessions", 1024, "Maximo de sesiones")
    logConnections := flag.Bool("log-connections", false, "Registrar conexiones")

    flag.Parse()

    logger := log.New(os.Stdout, "[BHTTP] ", log.LstdFlags)

    listener, err := net.Listen("tcp", *listen)
    if err != nil {
        logger.Fatalf("No se pudo abrir el puerto: %v", err)
    }

    config := bhttp.Config{
        TargetAddress: *target,
        SessionTimeout: *sessionTimeout,
        DialTimeout: *dialTimeout,
        MaxV2Lanes: *maxV2Lanes,
        Logger: logger,
        MaxConnections: *maxConnections,
        MaxSessions: *maxSessions,
        LogConnections: *logConnections,
    }

    server := bhttp.NewServer(config)

    logger.Printf("BHTTP escuchando en %s", listener.Addr())
    logger.Printf("Destino configurado: %s", *target)

    go func() {
        if err := server.Serve(listener); err != nil {
            logger.Printf("Servidor finalizado: %v", err)
        }
    }()

    signals := make(chan os.Signal, 1)

    signal.Notify(
        signals,
        syscall.SIGINT,
        syscall.SIGTERM,
    )

    <-signals

    logger.Println("Cerrando servidor...")

    server.Close()
    listener.Close()
    server.Wait()

    logger.Println("Servidor detenido.")
}
