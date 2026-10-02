package apns

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSendUsesHTTP2AndValidJWT(t *testing.T) {
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	var gotProto, gotTopic, gotPush, gotPath, gotBody string
	var jwtOK bool
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotProto, gotTopic, gotPush, gotPath = r.Proto, r.Header.Get("apns-topic"), r.Header.Get("apns-push-type"), r.URL.Path
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		jwtOK = VerifyJWT(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), &key.PublicKey)
		if strings.HasSuffix(r.URL.Path, "/dead") {
			w.WriteHeader(http.StatusGone)
			_, _ = w.Write([]byte(`{"reason":"Unregistered"}`))
			return
		}
		w.Header().Set("apns-id", "id-1")
	}))
	srv.EnableHTTP2 = true
	srv.StartTLS()
	defer srv.Close()

	c := New(key, "KEYID", "TEAMID", "com.example.app")
	c.SandboxBase = srv.URL
	c.HTTP = srv.Client()
	res, err := c.Send(context.Background(), "abc123", true, []byte(`{"aps":{}}`), "")
	if err != nil || res.Status != 200 || res.APNsID != "id-1" {
		t.Fatalf("send: %+v %v", res, err)
	}
	if gotProto != "HTTP/2.0" || gotTopic != "com.example.app" || gotPush != "alert" || gotPath != "/3/device/abc123" || !jwtOK || gotBody != `{"aps":{}}` {
		t.Fatalf("request: proto=%s topic=%s push=%s path=%s jwt=%v body=%s", gotProto, gotTopic, gotPush, gotPath, jwtOK, gotBody)
	}
	res, _ = c.Send(context.Background(), "dead", true, []byte(`{}`), "")
	if !res.Permanent || res.Status != 410 {
		t.Fatalf("410 must be permanent: %+v", res)
	}
}
