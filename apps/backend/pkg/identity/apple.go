package identity

import (
	"context"
	"crypto/ecdsa"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

type AppleRevoker struct {
	clientID, teamID, keyID string
	key                     *ecdsa.PrivateKey
	client                  *http.Client
	baseURL                 string
}

func NewAppleRevoker(clientID, teamID, keyID, pem string) (*AppleRevoker, error) {
	if teamID == "" && keyID == "" && pem == "" {
		return nil, nil
	}
	if clientID == "" || teamID == "" || keyID == "" || pem == "" {
		return nil, errors.New("incomplete Apple revocation configuration")
	}
	key, err := jwt.ParseECPrivateKeyFromPEM([]byte(strings.ReplaceAll(pem, `\n`, "\n")))
	if err != nil {
		return nil, errors.New("invalid Apple signing key")
	}
	if key.Curve.Params().BitSize != 256 {
		return nil, errors.New("Apple signing key must use P-256")
	}
	return &AppleRevoker{clientID: clientID, teamID: teamID, keyID: keyID, key: key, client: &http.Client{Timeout: 10 * time.Second}, baseURL: "https://appleid.apple.com/auth"}, nil
}

// Reauthorization supplies a fresh code at deletion time, so provider refresh
// tokens do not need to be retained by the application.
func (a *AppleRevoker) Revoke(ctx context.Context, code string, verifyIdentity func(string) error) error {
	if a == nil {
		return errors.New("Apple revocation is not configured")
	}
	if code == "" {
		return errors.New("missing Apple authorization code")
	}
	now := time.Now()
	secret := jwt.NewWithClaims(jwt.SigningMethodES256, jwt.RegisteredClaims{
		Issuer: a.teamID, Subject: a.clientID, Audience: jwt.ClaimStrings{"https://appleid.apple.com"},
		IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(5 * time.Minute)),
	})
	secret.Header["kid"] = a.keyID
	signed, err := secret.SignedString(a.key)
	if err != nil {
		return err
	}
	form := url.Values{"client_id": {a.clientID}, "client_secret": {signed}, "grant_type": {"authorization_code"}, "code": {code}}
	body, err := a.post(ctx, "/token", form)
	if err != nil {
		return err
	}
	var tokens struct {
		IDToken      string `json:"id_token"`
		RefreshToken string `json:"refresh_token"`
		AccessToken  string `json:"access_token"`
	}
	if err := json.Unmarshal(body, &tokens); err != nil {
		return errors.New("invalid Apple token response")
	}
	if err := verifyIdentity(tokens.IDToken); err != nil {
		return err
	}
	token, hint := tokens.RefreshToken, "refresh_token"
	if token == "" {
		token, hint = tokens.AccessToken, "access_token"
	}
	if token == "" {
		return errors.New("Apple returned no token to revoke")
	}
	_, err = a.post(ctx, "/revoke", url.Values{"client_id": {a.clientID}, "client_secret": {signed}, "token": {token}, "token_type_hint": {hint}})
	return err
}

func (a *AppleRevoker) post(ctx context.Context, path string, form url.Values) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.baseURL+path, strings.NewReader(form.Encode()))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response, err := a.client.Do(req)
	if err != nil {
		return nil, errors.New("Apple request failed")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Apple %s returned HTTP %d", path, response.StatusCode)
	}
	return io.ReadAll(io.LimitReader(response.Body, 64<<10))
}
