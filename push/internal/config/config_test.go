package config

import (
	"strings"
	"testing"
)

func lookupFrom(m map[string]string) func(string) (string, bool) {
	return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
}

func TestFromEnvValid(t *testing.T) {
	cfg, err := FromEnv(lookupFrom(map[string]string{
		"ENVIRONMENT":      "staging",
		"XMPP_DOMAIN":      "chat.example.com",
		"COMPONENT_JID":    "push.chat.example.com",
		"COMPONENT_ADDR":   "ejabberd:5347",
		"COMPONENT_SECRET": "s3cret",
		"DATABASE_URL":     "postgres://x",
		"APNS_KEY_FILE":    "/k.p8",
		"APNS_KEY_ID":      "K",
		"APNS_TEAM_ID":     "T",
		"APNS_TOPIC":       "com.example.app",
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Environment != Staging || cfg.HTTPAddr != ":8080" {
		t.Fatalf("unexpected config: %+v", cfg)
	}
}

func TestFromEnvReportsAllMissing(t *testing.T) {
	_, err := FromEnv(lookupFrom(map[string]string{"ENVIRONMENT": "prod"}))
	if err == nil {
		t.Fatal("expected error")
	}
	for _, want := range []string{"ENVIRONMENT", "XMPP_DOMAIN", "COMPONENT_JID", "COMPONENT_ADDR", "COMPONENT_SECRET", "DATABASE_URL"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not mention %s", err, want)
		}
	}
}

func TestProductionRejectsOverridesAndMissingKey(t *testing.T) {
	_, err := FromEnv(lookupFrom(map[string]string{
		"ENVIRONMENT": "production", "XMPP_DOMAIN": "d", "COMPONENT_JID": "p.d", "COMPONENT_ADDR": "a:1",
		"COMPONENT_SECRET": "s", "DATABASE_URL": "postgres://x", "APNS_SANDBOX_URL": "https://mock",
	}))
	if err == nil || !strings.Contains(err.Error(), "APNS_KEY_FILE") || !strings.Contains(err.Error(), "overrides") {
		t.Fatalf("expected key + override errors, got %v", err)
	}
}
