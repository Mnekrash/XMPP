// Package apns sends notifications to Apple Push Notification service over HTTP/2
// with token-based (ES256 JWT) authentication.
package apns

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"os"
	"sync"
	"time"
)

const (
	ProductionURL = "https://api.push.apple.com"
	SandboxURL    = "https://api.sandbox.push.apple.com"
)

// Result classifies an APNs response.
type Result struct {
	Status    int
	Reason    string
	APNsID    string
	Permanent bool // token is invalid for good: delete the registration
}

// Client is safe for concurrent use.
type Client struct {
	KeyID, TeamID, Topic        string
	ProductionBase, SandboxBase string
	HTTP                        *http.Client
	key                         *ecdsa.PrivateKey
	mu                          sync.Mutex
	jwt                         string
	jwtIssued                   time.Time
}

// LoadKey parses an Apple .p8 (PKCS#8 PEM, P-256) key file.
func LoadKey(path string) (*ecdsa.PrivateKey, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return ParseKey(raw)
}

// ParseKey parses PKCS#8 PEM P-256 private key bytes.
func ParseKey(raw []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(raw)
	if block == nil {
		return nil, errors.New("apns key: no PEM block")
	}
	k, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	ec, ok := k.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns key: not an ECDSA key")
	}
	return ec, nil
}

// New creates a client. Base URLs default to Apple's endpoints.
func New(key *ecdsa.PrivateKey, keyID, teamID, topic string) *Client {
	return &Client{KeyID: keyID, TeamID: teamID, Topic: topic, key: key,
		ProductionBase: ProductionURL, SandboxBase: SandboxURL,
		HTTP: &http.Client{Timeout: 15 * time.Second}}
}

// token returns a cached provider token; Apple accepts tokens up to 60 min old, we refresh after 50.
func (c *Client) token(force bool) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !force && c.jwt != "" && time.Since(c.jwtIssued) < 50*time.Minute {
		return c.jwt, nil
	}
	now := time.Now()
	header, _ := json.Marshal(map[string]string{"alg": "ES256", "kid": c.KeyID})
	claims, _ := json.Marshal(map[string]any{"iss": c.TeamID, "iat": now.Unix()})
	enc := base64.RawURLEncoding
	signingInput := enc.EncodeToString(header) + "." + enc.EncodeToString(claims)
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt = signingInput + "." + enc.EncodeToString(sig)
	c.jwtIssued = now
	return c.jwt, nil
}

// VerifyJWT checks an ES256 JWT against a public key (used by tests and the local mock).
func VerifyJWT(token string, pub *ecdsa.PublicKey) bool {
	var parts [3]string
	n := 0
	start := 0
	for i := 0; i < len(token) && n < 2; i++ {
		if token[i] == '.' {
			parts[n] = token[start:i]
			n++
			start = i + 1
		}
	}
	if n != 2 {
		return false
	}
	parts[2] = token[start:]
	sig, err := base64.RawURLEncoding.DecodeString(parts[2])
	if err != nil || len(sig) != 64 {
		return false
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	return ecdsa.Verify(pub, digest[:], new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:]))
}

// Send posts one alert notification. sandbox selects the development endpoint.
func (c *Client) Send(ctx context.Context, deviceToken string, sandbox bool, payload []byte, collapseID string) (Result, error) {
	base := c.ProductionBase
	if sandbox {
		base = c.SandboxBase
	}
	for attempt := 0; attempt < 2; attempt++ {
		tok, err := c.token(attempt > 0)
		if err != nil {
			return Result{}, err
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+"/3/device/"+deviceToken, bytes.NewReader(payload))
		if err != nil {
			return Result{}, err
		}
		req.Header.Set("authorization", "bearer "+tok)
		req.Header.Set("apns-topic", c.Topic)
		req.Header.Set("apns-push-type", "alert")
		req.Header.Set("apns-priority", "10")
		req.Header.Set("apns-expiration", fmt.Sprint(time.Now().Add(24*time.Hour).Unix()))
		if collapseID != "" {
			req.Header.Set("apns-collapse-id", collapseID)
		}
		resp, err := c.HTTP.Do(req)
		if err != nil {
			return Result{}, err
		}
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
		res := Result{Status: resp.StatusCode, APNsID: resp.Header.Get("apns-id")}
		var reason struct {
			Reason string `json:"reason"`
		}
		_ = json.Unmarshal(body, &reason)
		res.Reason = reason.Reason
		switch {
		case resp.StatusCode == http.StatusOK:
			return res, nil
		case resp.StatusCode == http.StatusForbidden && res.Reason == "ExpiredProviderToken" && attempt == 0:
			continue // refresh the JWT once
		case resp.StatusCode == http.StatusGone,
			res.Reason == "BadDeviceToken", res.Reason == "DeviceTokenNotForTopic", res.Reason == "Unregistered":
			res.Permanent = true
			return res, nil
		default:
			return res, nil
		}
	}
	return Result{}, errors.New("apns: provider token rejected twice")
}
