package identity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

func TestAppleRevocation(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	encoded := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	for _, test := range []struct {
		name                           string
		wrongIdentity, providerFailure bool
	}{
		{name: "revokes verified grant"}, {name: "rejects another identity", wrongIdentity: true}, {name: "provider failure", providerFailure: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			revoked := false
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if err := r.ParseForm(); err != nil {
					t.Error(err)
				}
				if r.Form.Get("client_id") != "bundle.id" {
					t.Error("wrong client ID")
				}
				claims := &jwt.RegisteredClaims{}
				token, err := jwt.ParseWithClaims(r.Form.Get("client_secret"), claims, func(token *jwt.Token) (any, error) { return &key.PublicKey, nil }, jwt.WithValidMethods([]string{"ES256"}), jwt.WithIssuer("team"), jwt.WithAudience("https://appleid.apple.com"), jwt.WithSubject("bundle.id"), jwt.WithExpirationRequired())
				if err != nil || token.Header["kid"] != "key-id" {
					t.Errorf("invalid client secret: %v", err)
				}
				switch r.URL.Path {
				case "/token":
					if r.Form.Get("code") != "fresh-code" || r.Form.Get("grant_type") != "authorization_code" {
						t.Error("wrong code exchange")
					}
					if test.providerFailure {
						w.WriteHeader(http.StatusBadRequest)
						return
					}
					_, _ = w.Write([]byte(`{"id_token":"verified-identity-token","refresh_token":"provider-refresh"}`))
				case "/revoke":
					if r.Form.Get("token") != "provider-refresh" || r.Form.Get("token_type_hint") != "refresh_token" {
						t.Error("wrong revoked token")
					}
					revoked = true
				default:
					t.Errorf("unexpected path: %s", r.URL.Path)
				}
			}))
			defer server.Close()
			revoker, err := NewAppleRevoker("bundle.id", "team", "key-id", encoded)
			if err != nil {
				t.Fatal(err)
			}
			revoker.baseURL = server.URL
			err = revoker.Revoke(context.Background(), "fresh-code", func(raw string) error {
				if raw != "verified-identity-token" {
					t.Error("missing identity validation")
				}
				if test.wrongIdentity {
					return errors.New("another user")
				}
				return nil
			})
			if test.wrongIdentity || test.providerFailure {
				if err == nil || revoked {
					t.Fatal("revoked an unverified grant")
				}
			} else if err != nil || !revoked {
				t.Fatalf("revocation failed: %v", err)
			}
		})
	}
}
