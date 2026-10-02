// Package config loads push gateway settings from the environment.
package config

import (
	"errors"
	"fmt"
	"os"
	"strings"
)

// Environment selects the APNs endpoint: development uses the sandbox.
type Environment string

const (
	Development Environment = "development"
	Staging     Environment = "staging"
	Production  Environment = "production"
)

// Config holds all gateway settings. Secrets are never logged.
type Config struct {
	Environment     Environment
	XMPPDomain      string
	ComponentJID    string
	ComponentAddr   string
	ComponentSecret string
	HTTPAddr        string
	DatabaseURL     string

	// APNs token authentication. KeyFile empty = APNs disabled (allowed only in development).
	APNsKeyFile string
	APNsKeyID   string
	APNsTeamID  string
	APNsTopic   string // app bundle id
	// Endpoint overrides for local testing only; rejected in production.
	APNsSandboxURL    string
	APNsProductionURL string
	APNsCAFile        string
}

// FromEnv reads the configuration using the given lookup function (os.LookupEnv in production).
func FromEnv(lookup func(string) (string, bool)) (Config, error) {
	get := func(key string) string {
		v, _ := lookup(key)
		return strings.TrimSpace(v)
	}

	cfg := Config{
		Environment:       Environment(get("ENVIRONMENT")),
		XMPPDomain:        get("XMPP_DOMAIN"),
		ComponentJID:      get("COMPONENT_JID"),
		ComponentAddr:     get("COMPONENT_ADDR"),
		ComponentSecret:   get("COMPONENT_SECRET"),
		HTTPAddr:          get("HTTP_ADDR"),
		DatabaseURL:       get("DATABASE_URL"),
		APNsKeyFile:       get("APNS_KEY_FILE"),
		APNsKeyID:         get("APNS_KEY_ID"),
		APNsTeamID:        get("APNS_TEAM_ID"),
		APNsTopic:         get("APNS_TOPIC"),
		APNsSandboxURL:    get("APNS_SANDBOX_URL"),
		APNsProductionURL: get("APNS_PRODUCTION_URL"),
		APNsCAFile:        get("APNS_CA_FILE"),
	}
	if cfg.HTTPAddr == "" {
		cfg.HTTPAddr = ":8080"
	}

	var errs []error
	switch cfg.Environment {
	case Development, Staging, Production:
	default:
		errs = append(errs, fmt.Errorf("ENVIRONMENT must be development, staging or production, got %q", cfg.Environment))
	}
	for key, value := range map[string]string{
		"XMPP_DOMAIN":      cfg.XMPPDomain,
		"COMPONENT_JID":    cfg.ComponentJID,
		"COMPONENT_ADDR":   cfg.ComponentAddr,
		"COMPONENT_SECRET": cfg.ComponentSecret,
		"DATABASE_URL":     cfg.DatabaseURL,
	} {
		if value == "" {
			errs = append(errs, fmt.Errorf("%s is required", key))
		}
	}
	if cfg.APNsKeyFile != "" {
		for key, value := range map[string]string{"APNS_KEY_ID": cfg.APNsKeyID, "APNS_TEAM_ID": cfg.APNsTeamID, "APNS_TOPIC": cfg.APNsTopic} {
			if value == "" {
				errs = append(errs, fmt.Errorf("%s is required when APNS_KEY_FILE is set", key))
			}
		}
	} else if cfg.Environment != Development {
		errs = append(errs, errors.New("APNS_KEY_FILE is required outside development"))
	}
	if cfg.Environment == Production && (cfg.APNsSandboxURL != "" || cfg.APNsProductionURL != "" || cfg.APNsCAFile != "") {
		errs = append(errs, errors.New("APNs endpoint overrides are not allowed in production"))
	}
	return cfg, errors.Join(errs...)
}

// FromOS reads the configuration from the process environment.
func FromOS() (Config, error) { return FromEnv(os.LookupEnv) }
