package push

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type Sender struct {
	key                        *ecdsa.PrivateKey
	keyID, teamID, topic, host string
	client                     *http.Client
	mu                         sync.Mutex
	token                      string
	signedAt                   time.Time
}

type Error struct {
	Status int
	Reason string
}

func (e *Error) Error() string { return fmt.Sprintf("APNs %d: %s", e.Status, e.Reason) }
func (e *Error) InvalidToken() bool {
	return e.Reason == "Unregistered" || e.Reason == "BadDeviceToken" || e.Reason == "DeviceTokenNotForTopic"
}

func New(keyPEM, keyID, teamID, topic, environment string) (*Sender, error) {
	key, err := jwt.ParseECPrivateKeyFromPEM([]byte(strings.ReplaceAll(keyPEM, `\n`, "\n")))
	if err != nil {
		return nil, fmt.Errorf("parse APNs private key: %w", err)
	}
	if key.Curve.Params().BitSize != 256 || keyID == "" || teamID == "" || topic == "" {
		return nil, fmt.Errorf("APNs requires a P-256 key, key ID, team ID, and bundle ID")
	}
	host := "https://api.push.apple.com"
	if environment == "development" {
		host = "https://api.sandbox.push.apple.com"
	} else if environment != "production" {
		return nil, fmt.Errorf("APNS_ENVIRONMENT must be development or production")
	}
	return &Sender{key: key, keyID: keyID, teamID: teamID, topic: topic, host: host, client: &http.Client{Timeout: 10 * time.Second}}, nil
}

func (s *Sender) authorization() (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.token != "" && time.Since(s.signedAt) < 50*time.Minute {
		return s.token, nil
	}
	now := time.Now()
	token := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.MapClaims{"iss": s.teamID, "iat": now.Unix()})
	token.Header["kid"] = s.keyID
	signed, err := token.SignedString(s.key)
	if err == nil {
		s.token = signed
		s.signedAt = now
	}
	return signed, err
}

var deviceToken = regexp.MustCompile(`^[a-fA-F0-9]{32,256}$`)

func (s *Sender) Send(ctx context.Context, token, collapseID string, background bool, payload map[string]any) error {
	if !deviceToken.MatchString(token) {
		return &Error{Status: 400, Reason: "BadDeviceToken"}
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	authorization, err := s.authorization()
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.host+"/3/device/"+token, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+authorization)
	req.Header.Set("content-type", "application/json")
	req.Header.Set("apns-topic", s.topic)
	req.Header.Set("apns-collapse-id", collapseID)
	req.Header.Set("apns-expiration", strconv.FormatInt(time.Now().Add(time.Hour).Unix(), 10))
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", "10")
	if background {
		req.Header.Set("apns-push-type", "background")
		req.Header.Set("apns-priority", "5")
	}
	resp, err := s.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusOK {
		return nil
	}
	var failure struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(io.LimitReader(resp.Body, 4096)).Decode(&failure)
	return &Error{Status: resp.StatusCode, Reason: failure.Reason}
}
