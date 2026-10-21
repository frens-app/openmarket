package config

import (
	"testing"
	"time"
)

func TestListingAlertBaseLimit(t *testing.T) {
	for _, tc := range []struct {
		env            string
		devLimit, want int
	}{
		{"production", 3, 1}, {"production", 100, 1},
		{"development", 3, 3}, {"development", 10, 10},
		{"development", 0, 1}, {"", 100, 1}, {"staging", 100, 1},
	} {
		cfg := ServiceConfig{Env: tc.env, DevListingAlertLimit: tc.devLimit}
		if got := cfg.ListingAlertBaseLimit(); got != tc.want {
			t.Errorf("env=%q devLimit=%d: got %d, want %d", tc.env, tc.devLimit, got, tc.want)
		}
	}
}

func TestProductionConfigurationDoesNotRequireRetiredSMSCredentials(t *testing.T) {
	cfg := ServiceConfig{Env: "production", DatabaseURL: "postgres://test", JWTSecret: "access", RefreshTokenHMACKey: "refresh", LLMProvider: LLMProviderGoogle, LLMAPIKey: "test", LLMModel: "test", LLMMaxAttempts: 1, LLMCallWindow: time.Hour}
	requireAPIValues(cfg)
	cfg.GoogleClientID = "google-client"
	requireAPIValues(cfg)
	t.Run("enabled Apple requires revocation credentials", func(t *testing.T) {
		defer func() {
			if recover() == nil {
				t.Fatal("incomplete Apple configuration accepted")
			}
		}()
		apple := cfg
		apple.AppleClientID = "apple-client"
		requireAPIValues(apple)
	})
	t.Run("phone bypass remains forbidden in production", func(t *testing.T) {
		defer func() {
			if recover() == nil {
				t.Fatal("production bypass accepted")
			}
		}()
		bypass := cfg
		bypass.DevBypassPhoneNumbers = "*"
		requireAPIValues(bypass)
	})
}
