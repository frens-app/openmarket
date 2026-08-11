// Package config loads service configuration from flags, environment
// variables, and .env files, in that order of precedence.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/spf13/pflag"
	"github.com/spf13/viper"
)

func init() {
	pflag.String("env", "development", "environment (development, production)")
	pflag.Int("port", 8080, "server listen port")
	pflag.String("database_url", "", "postgres connection URL")
	pflag.String("log_level", "info", "zap log level (debug, info, warn, error)")

	// Auth
	pflag.String("jwt_secret", "", "HMAC-SHA256 signing key for access tokens")
	pflag.String("refresh_token_hmac_key", "", "HMAC-SHA256 key for hashing refresh tokens at rest")
	// Short-lived, because the session check on every call is what makes
	// revocation immediate and a long-lived access token would defeat it.
	pflag.Duration("access_token_ttl", 30*time.Minute, "access token TTL")
	pflag.Duration("refresh_token_ttl", 365*24*time.Hour, "refresh token TTL")

	// SMS verification, via Prelude.
	//
	// Deliberately no base-URL override. Every environment talks to the real
	// Prelude API; the only thing that skips it is the bypass list below, which
	// is in-process. An override would exist purely to point a deployment at
	// something that isn't Prelude, and the one deployment where that matters is
	// the one where it must never happen.
	pflag.String("prelude_api_key", "", "Prelude API key")
	pflag.Int("verification_code_length", 6, "digits in the verification code, reported to the client")
	// Specific numbers that skip the provider — the dev skip button, and a demo
	// account for App Review. Everything not on this list goes through the
	// provider normally, which is the difference from the flag this replaced.
	pflag.String("dev_bypass_phone_numbers", "", "comma-separated E.164 numbers that accept dev_verification_code without SMS (never in production)")
	pflag.String("dev_verification_code", "123456", "the code those numbers accept")

	// Abuse controls on StartPhoneVerification.
	//
	// Per-number limiting and pumping detection are the provider's, not ours —
	// see migration 00002. What is left here is the country allowlist (which
	// fails closed at boot; see pkg/phone) and a ceiling on total spend, which
	// is the one thing a per-entity limit cannot give you.
	pflag.String("allowed_country_codes", "1", "comma-separated country calling codes allowed to receive codes")
	pflag.Int("verification_max_sends", 500, "total verification sends allowed per window, across all numbers")
	pflag.Duration("verification_send_window", time.Hour, "window the send ceiling is counted over")
	// Reported to the client to drive its resend countdown. A hint, not an
	// enforced limit: the provider's own per-number limit is what actually stops
	// a runaway client, and keeping this server-side means tuning it doesn't need
	// an app release.
	pflag.Duration("verification_resend_cooldown", 60*time.Second, "resend countdown reported to the client")

	// Push. The topic and environment are properties of a deployment rather than
	// of a stored token, which is why they are config and not columns on
	// user_devices — see the comment in migration 00003. Nothing reads them yet;
	// they are what the APNs sender will need when it exists.
	pflag.String("apns_bundle_id", "", "APNs topic (apns-topic header) used when sending pushes")

	// The model calls behind Price Check.
	//
	// Unlike Prelude, this one has a local stand-in: `stub` answers without a
	// network or a key, so the iOS side can be built and re-run without a bill.
	// That is a real code path selected by configuration rather than a mock —
	// the same arrangement as DEV_BYPASS_PHONE_NUMBERS — and like that list it
	// is refused under ENV=production.
	pflag.String("llm_provider", "stub", "model provider: stub, google")
	pflag.String("llm_api_key", "", "API key for the model provider (not required by stub)")
	pflag.String("llm_model", "", "model identifier to request (not required by stub)")
	// Per user, per window, counted in calls rather than money because there is
	// no rate table yet. The failure this guards against early is a client stuck
	// in a retry loop, not a large bill, and calls are the right unit for that.
	pflag.Int("llm_max_calls_per_user", 60, "model calls allowed per user per window")
	pflag.Duration("llm_call_window", time.Hour, "window the per-user call ceiling is counted over")
	// Attempts for one logical call, not retries on top of it: 2 means one
	// retry. Every attempt is charged and every attempt is a row.
	pflag.Int("llm_max_attempts", 2, "attempts per model call, including the first")
	pflag.Duration("llm_timeout", 30*time.Second, "deadline for a single model call")
}

var parseFlagsOnce sync.Once

// ServiceConfig is the fully resolved configuration.
type ServiceConfig struct {
	Env         string `mapstructure:"env"`
	Port        int    `mapstructure:"port"`
	DatabaseURL string `mapstructure:"database_url"`
	LogLevel    string `mapstructure:"log_level"`

	JWTSecret           string        `mapstructure:"jwt_secret"`
	RefreshTokenHMACKey string        `mapstructure:"refresh_token_hmac_key"`
	AccessTokenTTL      time.Duration `mapstructure:"access_token_ttl"`
	RefreshTokenTTL     time.Duration `mapstructure:"refresh_token_ttl"`

	PreludeAPIKey          string `mapstructure:"prelude_api_key"`
	VerificationCodeLength int    `mapstructure:"verification_code_length"`
	DevBypassPhoneNumbers  string `mapstructure:"dev_bypass_phone_numbers"`
	DevVerificationCode    string `mapstructure:"dev_verification_code"`

	AllowedCountryCodes        string        `mapstructure:"allowed_country_codes"`
	VerificationMaxSends       int           `mapstructure:"verification_max_sends"`
	VerificationSendWindow     time.Duration `mapstructure:"verification_send_window"`
	VerificationResendCooldown time.Duration `mapstructure:"verification_resend_cooldown"`

	APNSBundleID string `mapstructure:"apns_bundle_id"`

	LLMProvider        string        `mapstructure:"llm_provider"`
	LLMAPIKey          string        `mapstructure:"llm_api_key"`
	LLMModel           string        `mapstructure:"llm_model"`
	LLMMaxCallsPerUser int           `mapstructure:"llm_max_calls_per_user"`
	LLMCallWindow      time.Duration `mapstructure:"llm_call_window"`
	LLMMaxAttempts     int           `mapstructure:"llm_max_attempts"`
	LLMTimeout         time.Duration `mapstructure:"llm_timeout"`
}

// IsProduction reports whether this is the production environment.
func (c ServiceConfig) IsProduction() bool { return c.Env == "production" }

// LLMProviderStub is the provider name that answers without a network.
const LLMProviderStub = "stub"

// UsesStubLLM reports whether model calls are being answered locally.
func (c ServiceConfig) UsesStubLLM() bool { return c.LLMProvider == LLMProviderStub }

// BypassPhoneNumbers returns the parsed dev bypass list.
func (c ServiceConfig) BypassPhoneNumbers() []string {
	var out []string
	for _, raw := range strings.Split(c.DevBypassPhoneNumbers, ",") {
		if n := strings.TrimSpace(raw); n != "" {
			out = append(out, n)
		}
	}
	return out
}

// LoadAPI loads and validates configuration for the API server. It panics on
// missing required values: a service that boots without a JWT secret is worse
// than one that refuses to boot.
func LoadAPI() ServiceConfig {
	parseFlagsOnce.Do(pflag.Parse)

	v := viper.New()
	if err := v.BindPFlags(pflag.CommandLine); err != nil {
		panic(err)
	}
	v.AutomaticEnv()

	if err := loadConfigFiles(v, v.GetString("env")); err != nil {
		panic(err)
	}

	var cfg ServiceConfig
	if err := v.Unmarshal(&cfg); err != nil {
		panic(err)
	}
	requireAPIValues(cfg)
	return cfg
}

func requireAPIValues(cfg ServiceConfig) {
	// The Prelude key is required everywhere, development included. There is no
	// local substitute to fall back on and no base URL to redirect: every
	// environment talks to the real API, and the bypass list is what makes that
	// workable on a laptop.
	required := []string{
		"database_url", cfg.DatabaseURL,
		"jwt_secret", cfg.JWTSecret,
		"refresh_token_hmac_key", cfg.RefreshTokenHMACKey,
		"allowed_country_codes", cfg.AllowedCountryCodes,
		"prelude_api_key", cfg.PreludeAPIKey,
	}

	var missing []string
	for i := 0; i < len(required); i += 2 {
		if strings.TrimSpace(required[i+1]) == "" {
			missing = append(missing, required[i])
		}
	}
	if len(missing) > 0 {
		// Nothing is defaulted into place quietly. Prelude credentials are
		// required in development too — that is what keeps dev on the same code
		// path as production — so the first run on a fresh clone stops here, and
		// the message says exactly how to get past it rather than leaving
		// somebody to work out which of twenty settings is missing.
		hint := ""
		if !cfg.IsProduction() {
			hint = "\n\ncp apps/backend/.env.local.example apps/backend/.env.local" +
				"\n\nThen put a real Prelude API key in it. There is no offline mode:\n" +
				"dev talks to the same Prelude the production service does, and the\n" +
				"numbers on DEV_BYPASS_PHONE_NUMBERS are what skip it."
		}
		panic(fmt.Sprintf("missing required config: %v%s", missing, hint))
	}

	// The bypass list is the only way a code is accepted without Prelude having
	// sent it, so it is the only thing that has to be impossible in production.
	if cfg.IsProduction() && len(cfg.BypassPhoneNumbers()) > 0 {
		panic("dev_bypass_phone_numbers must be empty in production")
	}

	// The model provider is required to be real in production for the same
	// reason: the stub is the one configuration that returns an answer nothing
	// generated, and a price built on it would look exactly like a price.
	if cfg.IsProduction() && cfg.UsesStubLLM() {
		panic("llm_provider must not be " + LLMProviderStub + " in production")
	}
	// Credentials are required only when there is something to authenticate to,
	// which is the difference from Prelude: this feature does have a local
	// stand-in, so a fresh clone runs without a key and only a deployment that
	// means to call a provider has to have one.
	if !cfg.UsesStubLLM() {
		var missingLLM []string
		if strings.TrimSpace(cfg.LLMAPIKey) == "" {
			missingLLM = append(missingLLM, "llm_api_key")
		}
		if strings.TrimSpace(cfg.LLMModel) == "" {
			missingLLM = append(missingLLM, "llm_model")
		}
		if len(missingLLM) > 0 {
			panic(fmt.Sprintf("llm_provider=%s requires %v (or set llm_provider=%s)",
				cfg.LLMProvider, missingLLM, LLMProviderStub))
		}
	}
	if cfg.LLMMaxAttempts < 1 {
		panic("llm_max_attempts must be at least 1")
	}
	if cfg.LLMCallWindow <= 0 {
		panic("llm_call_window must be positive")
	}
	if cfg.JWTSecret == cfg.RefreshTokenHMACKey {
		panic("jwt_secret and refresh_token_hmac_key must differ; rotating one should not invalidate the other")
	}
}

// loadConfigFiles merges .env.<env> then .env.local, both optional. Values
// already set by a flag or a real environment variable win over both, which is
// what makes the same binary work on a laptop and on Railway.
func loadConfigFiles(v *viper.Viper, env string) error {
	v.SetConfigType("env")

	paths := []string{filepath.Join(".", fmt.Sprintf(".env.%s", env))}
	if env != "production" {
		paths = append(paths, filepath.Join(".", ".env.local"))
	}

	for _, path := range paths {
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return fmt.Errorf("stat %s: %w", path, err)
		}
		f, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("open %s: %w", path, err)
		}
		err = v.MergeConfig(f)
		_ = f.Close()
		if err != nil {
			return fmt.Errorf("merge %s: %w", path, err)
		}
	}
	return nil
}
