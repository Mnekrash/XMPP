// Command push-gateway is the XEP-0357 app server: an XEP-0114 component that accepts push registrations
// from users (XEP-0050 commands) and push publications from ejabberd, and delivers content-free
// notifications to APNs (docs/04-push.md).
package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/mnekrash/xmpp/push/internal/apns"
	"github.com/mnekrash/xmpp/push/internal/config"
	"github.com/mnekrash/xmpp/push/internal/gateway"
	"github.com/mnekrash/xmpp/push/internal/store"
	"github.com/mnekrash/xmpp/push/internal/xmpp"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	if err := run(logger); err != nil {
		logger.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	cfg, err := config.FromOS()
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := openStore(ctx, cfg.DatabaseURL, logger)
	if err != nil {
		return err
	}
	defer st.Close()

	var sender gateway.Sender
	if cfg.APNsKeyFile != "" {
		key, err := apns.LoadKey(cfg.APNsKeyFile)
		if err != nil {
			return err
		}
		client := apns.New(key, cfg.APNsKeyID, cfg.APNsTeamID, cfg.APNsTopic)
		if cfg.APNsSandboxURL != "" {
			client.SandboxBase = cfg.APNsSandboxURL
		}
		if cfg.APNsProductionURL != "" {
			client.ProductionBase = cfg.APNsProductionURL
		}
		if cfg.APNsCAFile != "" { // development mock only (rejected in production by config)
			pem, err := os.ReadFile(cfg.APNsCAFile)
			if err != nil {
				return err
			}
			pool := x509.NewCertPool()
			pool.AppendCertsFromPEM(pem)
			client.HTTP.Transport = &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool}, ForceAttemptHTTP2: true}
		}
		sender = client
		logger.Info("APNs enabled", "topic", cfg.APNsTopic, "sandbox_base", client.SandboxBase, "production_base", client.ProductionBase)
	} else {
		logger.Warn("APNs disabled (development, no APNS_KEY_FILE)")
	}

	gw := &gateway.Gateway{XMPPDomain: cfg.XMPPDomain, ComponentJID: cfg.ComponentJID, Store: st, APNs: sender, Log: logger}
	comp := &xmpp.Component{Addr: cfg.ComponentAddr, Domain: cfg.ComponentJID, Secret: cfg.ComponentSecret, Log: logger}
	go comp.Run(ctx, gw.Handle)

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		n, dbErr := st.Count(r.Context())
		status := http.StatusOK
		if dbErr != nil || !comp.Connected() {
			status = http.StatusServiceUnavailable
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(map[string]any{
			"component": comp.Connected(), "database": dbErr == nil, "registrations": n, "apns": sender != nil,
		})
	})
	server := &http.Server{Addr: cfg.HTTPAddr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := server.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("http server failed", "error", err)
			stop()
		}
	}()
	logger.Info("push gateway started", "environment", cfg.Environment, "component", cfg.ComponentJID)
	<-ctx.Done()
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = server.Shutdown(shutdown)
	return nil
}

func openStore(ctx context.Context, url string, logger *slog.Logger) (*store.Postgres, error) {
	var lastErr error
	for i := 0; i < 30; i++ { // the database may still be starting
		st, err := store.OpenPostgres(ctx, url)
		if err == nil {
			return st, nil
		}
		lastErr = err
		logger.Warn("database not ready", "error", err)
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return nil, lastErr
}
