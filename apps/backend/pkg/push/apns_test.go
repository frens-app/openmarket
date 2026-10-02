package push

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/golang-jwt/jwt/v5"
)

func TestAPNsHeadersAndSigning(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	raw := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})
	sender, err := New(string(raw), "key-id", "team-id", "lol.frens.openmarket.dev", "development")
	if err != nil {
		t.Fatal(err)
	}
	for _, background := range []bool{true, false} {
		t.Run(map[bool]string{true: "background", false: "visible"}[background], func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != "/3/device/"+strings.Repeat("a", 64) || r.Method != "POST" {
					t.Error("wrong APNs request")
				}
				kind, priority := "alert", "10"
				if background {
					kind, priority = "background", "5"
				}
				for header, want := range map[string]string{"apns-push-type": kind, "apns-priority": priority, "apns-topic": "lol.frens.openmarket.dev", "apns-collapse-id": "stable-id"} {
					if got := r.Header.Get(header); got != want {
						t.Errorf("%s = %s, want %s", header, got, want)
					}
				}
				token, err := jwt.Parse(strings.TrimPrefix(r.Header.Get("authorization"), "bearer "), func(token *jwt.Token) (any, error) { return &key.PublicKey, nil }, jwt.WithValidMethods([]string{"ES256"}), jwt.WithIssuer("team-id"))
				if err != nil || !token.Valid || token.Header["kid"] != "key-id" {
					t.Errorf("invalid token: %v", err)
				}
				var payload map[string]any
				if err := json.NewDecoder(r.Body).Decode(&payload); err != nil {
					t.Error(err)
				}
				if payload["alert_id"] != "test-alert" {
					t.Error("lost deep link")
				}
			}))
			defer server.Close()
			sender.host = server.URL
			if err := sender.Send(context.Background(), strings.Repeat("a", 64), "stable-id", background, map[string]any{"alert_id": "test-alert", "aps": map[string]int{"content-available": 1}}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestAPNsInvalidTokenClassification(t *testing.T) {
	for _, reason := range []string{"Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"} {
		e := &Error{Status: 410, Reason: reason}
		if !e.InvalidToken() {
			t.Error(reason)
		}
	}
	if (&Error{Status: 403, Reason: "ExpiredProviderToken"}).InvalidToken() {
		t.Fatal("provider failure must not erase device token")
	}
	sender := &Sender{}
	err := sender.Send(context.Background(), "../../not-a-token", "id", true, nil)
	var failure *Error
	if !errors.As(err, &failure) || !failure.InvalidToken() {
		t.Fatalf("bad token: %v", err)
	}
}
