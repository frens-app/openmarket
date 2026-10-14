package identity

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/coreos/go-oidc/v3/oidc"
	"github.com/golang-jwt/jwt/v5"
)

func TestVerifyProviderIdentity(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	otherKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	keys := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"keys": []any{map[string]any{
			"kty": "RSA", "kid": "test", "alg": "RS256", "use": "sig",
			"n": base64.RawURLEncoding.EncodeToString(key.N.Bytes()),
			"e": base64.RawURLEncoding.EncodeToString(big.NewInt(int64(key.E)).Bytes()),
		}}})
	}))
	defer keys.Close()
	nonce, _, err := NewNonce()
	if err != nil {
		t.Fatal(err)
	}
	for _, provider := range []struct{ name, issuer string }{{"APPLE", "https://appleid.apple.com"}, {"GOOGLE", "https://accounts.google.com"}} {
		t.Run(provider.name, func(t *testing.T) {
			verifier := &Verifier{providers: map[string]*oidc.IDTokenVerifier{
				provider.name: oidc.NewVerifier(provider.issuer, oidc.NewRemoteKeySet(context.Background(), keys.URL), &oidc.Config{
					ClientID: "our-client", SupportedSigningAlgs: []string{oidc.RS256},
				}),
			}}
			for _, test := range []struct {
				name      string
				change    func(jwt.MapClaims)
				wrongKey  bool
				valid     bool
				wantEmail string
			}{
				{name: "verified email", valid: true, wantEmail: "person@example.com"},
				{name: "string verified email", valid: true, wantEmail: "person@example.com", change: func(c jwt.MapClaims) { c["email_verified"] = "true" }},
				{name: "Apple relay email", valid: true, wantEmail: "relay@privaterelay.appleid.com", change: func(c jwt.MapClaims) { c["email"] = "relay@privaterelay.appleid.com" }},
				{name: "missing email", valid: true, change: func(c jwt.MapClaims) { delete(c, "email") }},
				{name: "blank email", valid: true, change: func(c jwt.MapClaims) { c["email"] = "  " }},
				{name: "unverified email", valid: true, change: func(c jwt.MapClaims) { c["email_verified"] = false }},
				{name: "string unverified email", valid: true, change: func(c jwt.MapClaims) { c["email_verified"] = "false" }},
				{name: "missing email verification", valid: true, change: func(c jwt.MapClaims) { delete(c, "email_verified") }},
				{name: "numeric email verification", valid: true, change: func(c jwt.MapClaims) { c["email_verified"] = 1 }},
				{name: "null email verification", valid: true, change: func(c jwt.MapClaims) { c["email_verified"] = nil }},
				{name: "wrong audience", change: func(c jwt.MapClaims) { c["aud"] = "another-app" }},
				{name: "wrong issuer", change: func(c jwt.MapClaims) { c["iss"] = "https://attacker.invalid" }},
				{name: "expired", change: func(c jwt.MapClaims) { c["exp"] = time.Now().Add(-time.Hour).Unix() }},
				{name: "missing expiry", change: func(c jwt.MapClaims) { delete(c, "exp") }},
				{name: "missing subject", change: func(c jwt.MapClaims) { delete(c, "sub") }},
				{name: "missing nonce", change: func(c jwt.MapClaims) { delete(c, "nonce") }},
				{name: "wrong nonce", change: func(c jwt.MapClaims) { c["nonce"] = "another-login" }},
				{name: "forged signature", wrongKey: true},
			} {
				t.Run(test.name, func(t *testing.T) {
					claims := jwt.MapClaims{"iss": provider.issuer, "aud": "our-client", "sub": "stable-subject", "exp": time.Now().Add(time.Hour).Unix(), "iat": time.Now().Unix(), "nonce": nonce, "email": "person@example.com", "email_verified": true}
					if test.change != nil {
						test.change(claims)
					}
					token := jwt.NewWithClaims(jwt.SigningMethodRS256, claims)
					token.Header["kid"] = "test"
					signingKey := key
					if test.wrongKey {
						signingKey = otherKey
					}
					raw, err := token.SignedString(signingKey)
					if err != nil {
						t.Fatal(err)
					}
					verified, err := verifier.Verify(context.Background(), provider.name, raw, nonce)
					if test.valid {
						if err != nil || verified.Subject != "stable-subject" || verified.VerifiedEmail != test.wantEmail {
							t.Fatalf("identity=%+v error=%v", verified, err)
						}
					} else if err == nil || verified != (Identity{}) {
						t.Fatal("accepted invalid token")
					}
				})
			}
			if _, err := verifier.Verify(context.Background(), "UNKNOWN", "token", nonce); err == nil {
				t.Fatal("accepted unknown provider")
			}
		})
	}
}
