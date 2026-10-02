// Command apns-mock is a DEVELOPMENT-ONLY stand-in for APNs used by spike S2's server-side tests.
// It speaks HTTP/2 over TLS, verifies the ES256 provider token with the given public key, records every
// request to a JSON-lines file, and answers 410 Unregistered for tokens listed in DEAD_TOKENS.
// It is never part of a staging/production deployment (the gateway rejects endpoint overrides there).
package main

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/mnekrash/xmpp/push/internal/apns"
)

func main() {
	pubPEM, err := os.ReadFile(os.Getenv("JWT_PUBLIC_KEY"))
	if err != nil {
		log.Fatal(err)
	}
	block, _ := pem.Decode(pubPEM)
	k, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		log.Fatal(err)
	}
	pub := k.(*ecdsa.PublicKey)
	dead := map[string]bool{}
	for _, t := range strings.Split(os.Getenv("DEAD_TOKENS"), ",") {
		if t != "" {
			dead[strings.ToLower(t)] = true
		}
	}
	out, err := os.OpenFile(os.Getenv("RECORD_FILE"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		log.Fatal(err)
	}
	var mu sync.Mutex
	http.HandleFunc("/3/device/", func(w http.ResponseWriter, r *http.Request) {
		token := strings.TrimPrefix(r.URL.Path, "/3/device/")
		body, _ := io.ReadAll(r.Body)
		jwtOK := apns.VerifyJWT(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), pub)
		status := http.StatusOK
		reason := ""
		switch {
		case !jwtOK:
			status, reason = http.StatusForbidden, "InvalidProviderToken"
		case dead[token]:
			status, reason = http.StatusGone, "Unregistered"
		}
		rec := map[string]any{"time": time.Now().UTC().Format(time.RFC3339Nano), "proto": r.Proto, "token": token,
			"topic": r.Header.Get("apns-topic"), "pushType": r.Header.Get("apns-push-type"),
			"priority": r.Header.Get("apns-priority"), "jwtValid": jwtOK, "status": status, "payload": json.RawMessage(body)}
		mu.Lock()
		_ = json.NewEncoder(out).Encode(rec)
		mu.Unlock()
		if status != http.StatusOK {
			w.WriteHeader(status)
			_ = json.NewEncoder(w).Encode(map[string]string{"reason": reason})
			return
		}
		w.Header().Set("apns-id", "mock-"+time.Now().Format("150405.000000"))
	})
	log.Fatal(http.ListenAndServeTLS(":8443", os.Getenv("TLS_CERT"), os.Getenv("TLS_KEY"), nil))
}
