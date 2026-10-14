// Package identity verifies provider credentials before an app session is issued.
package identity

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
)

type Verifier struct {
	providers map[string]*oidc.IDTokenVerifier
}

type Identity struct {
	Subject       string
	VerifiedEmail string
}

func NewVerifier(ctx context.Context, appleClientID, googleClientID string) *Verifier {
	ctx = oidc.ClientContext(ctx, &http.Client{Timeout: 10 * time.Second})
	v := &Verifier{providers: make(map[string]*oidc.IDTokenVerifier)}
	for _, p := range []struct{ name, issuer, keys, clientID string }{
		{"APPLE", "https://appleid.apple.com", "https://appleid.apple.com/auth/keys", appleClientID},
		{"GOOGLE", "https://accounts.google.com", "https://www.googleapis.com/oauth2/v3/certs", googleClientID},
	} {
		if p.clientID == "" {
			continue
		}
		v.providers[p.name] = oidc.NewVerifier(p.issuer, oidc.NewRemoteKeySet(ctx, p.keys), &oidc.Config{
			ClientID: p.clientID, SupportedSigningAlgs: []string{oidc.RS256},
		})
	}
	return v
}

func (v *Verifier) Enabled(provider string) bool { return v.providers[provider] != nil }

func (v *Verifier) Verify(ctx context.Context, provider, rawToken, nonce string) (Identity, error) {
	verifier := v.providers[provider]
	if verifier == nil {
		return Identity{}, errors.New("provider unavailable")
	}
	token, err := verifier.Verify(ctx, rawToken)
	if err != nil {
		return Identity{}, err
	}
	if token.Subject == "" || len(nonce) != 43 || subtle.ConstantTimeCompare([]byte(token.Nonce), []byte(nonce)) != 1 {
		return Identity{}, errors.New("invalid identity or nonce")
	}
	var claims struct {
		Email         string          `json:"email"`
		EmailVerified json.RawMessage `json:"email_verified"`
	}
	if err := token.Claims(&claims); err != nil {
		return Identity{}, err
	}
	result := Identity{Subject: token.Subject}
	// Apple encodes email_verified as either a boolean or a string.
	if string(claims.EmailVerified) == "true" || string(claims.EmailVerified) == `"true"` {
		result.VerifiedEmail = strings.TrimSpace(claims.Email)
	}
	return result, nil
}

func NewNonce() (string, string, error) {
	var bytes [32]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return "", "", err
	}
	nonce := base64.RawURLEncoding.EncodeToString(bytes[:])
	return nonce, HashNonce(nonce), nil
}

func HashNonce(nonce string) string {
	sum := sha256.Sum256([]byte(nonce))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
