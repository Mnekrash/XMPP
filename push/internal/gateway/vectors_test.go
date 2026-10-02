package gateway

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// TestWriteVectors writes envelopes sealed by the gateway for the Swift NotificationEnvelope tests.
// Run: VECTORS_OUT=path go test ./internal/gateway -run TestWriteVectors
func TestWriteVectors(t *testing.T) {
	out := os.Getenv("VECTORS_OUT")
	if out == "" {
		t.Skip("VECTORS_OUT not set")
	}
	key := make([]byte, 32)
	for i := range key {
		key[i] = byte(i)
	}
	type vector struct {
		Key      string   `json:"key"`
		E        string   `json:"e"`
		Envelope Envelope `json:"envelope"`
		Thread   string   `json:"thread"`
	}
	var vs []vector
	for _, env := range []Envelope{
		{V: 1, Sender: "alice@chat.example.com/phone", Conv: "alice@chat.example.com", Count: 1},
		{V: 1, Sender: "team@groups.chat.example.com/Bob", Conv: "team@groups.chat.example.com", Count: 3},
		{V: 1, Sender: "Ünïcødé@chat.example.com", Conv: "Ünïcødé@chat.example.com", Count: 1},
	} {
		e, err := SealEnvelope(key, env)
		if err != nil {
			t.Fatal(err)
		}
		vs = append(vs, vector{Key: base64.StdEncoding.EncodeToString(key), E: e, Envelope: env, Thread: OpaqueID(key, env.Conv)})
	}
	b, _ := json.MarshalIndent(vs, "", " ")
	if err := os.WriteFile(out, b, 0o644); err != nil {
		t.Fatal(err)
	}
}
