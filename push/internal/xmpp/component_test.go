package xmpp

import "testing"

// Known answer computed independently: printf '3BF96D32Calli0pe' | sha1sum
func TestHandshakeDigestKnownAnswer(t *testing.T) {
	if got := HandshakeDigest("3BF96D32", "Calli0pe"); got != "8b94cc5c235519be4871b3a17be65c5538d88f63" {
		t.Fatalf("digest %s", got)
	}
}
