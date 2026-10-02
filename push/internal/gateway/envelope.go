// Package gateway implements the XEP-0357 app server: registration commands from clients and
// push publications from the XMPP server, delivered to APNs without message content.
package gateway

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
)

// EnvelopeVersion is the first byte of the encrypted notification envelope (docs/04 §2.1).
const EnvelopeVersion = 1

// Envelope is the content only the device can read. It never contains message text.
type Envelope struct {
	V      int    `json:"v"`
	Sender string `json:"sender,omitempty"`
	Conv   string `json:"conv,omitempty"`
	Count  int    `json:"count,omitempty"`
}

// SealEnvelope returns base64(version ‖ nonce(12) ‖ AES-256-GCM(deviceKey, json) ‖ tag(16)).
func SealEnvelope(deviceKey []byte, e Envelope) (string, error) {
	if len(deviceKey) != 32 {
		return "", errors.New("device key must be 32 bytes")
	}
	plain, err := json.Marshal(e)
	if err != nil {
		return "", err
	}
	block, err := aes.NewCipher(deviceKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	out := append([]byte{EnvelopeVersion}, nonce...)
	out = gcm.Seal(out, nonce, plain, []byte{EnvelopeVersion})
	return base64.StdEncoding.EncodeToString(out), nil
}

// OpenEnvelope is the inverse (the NSE does this in Swift with CryptoKit; used by tests).
func OpenEnvelope(deviceKey []byte, b64 string) (Envelope, error) {
	var e Envelope
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) < 1+12+16 || raw[0] != EnvelopeVersion {
		return e, errors.New("malformed envelope")
	}
	block, err := aes.NewCipher(deviceKey)
	if err != nil {
		return e, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return e, err
	}
	plain, err := gcm.Open(nil, raw[1:13], raw[13:], []byte{EnvelopeVersion})
	if err != nil {
		return e, err
	}
	return e, json.Unmarshal(plain, &e)
}

// OpaqueID derives a per-device opaque identifier for a conversation (thread-id, mute key).
// The client computes the same value, so the gateway never needs the plaintext conversation for muting.
func OpaqueID(deviceKey []byte, conv string) string {
	mac := hmac.New(sha256.New, deviceKey)
	mac.Write([]byte("thread:" + conv))
	return hex.EncodeToString(mac.Sum(nil)[:16])
}
