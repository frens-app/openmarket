package config

import (
	"testing"
	"time"
)

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
