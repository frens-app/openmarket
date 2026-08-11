package auth

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

const testSecret = "test-secret"

func TestAccessTokenRoundTrip(t *testing.T) {
	userID, sessionID := uuid.New(), uuid.New()

	token, err := SignAccessToken(userID, sessionID, testSecret, time.Minute)
	if err != nil {
		t.Fatalf("SignAccessToken: %v", err)
	}
	claims, err := ValidateAccessToken(token, testSecret)
	if err != nil {
		t.Fatalf("ValidateAccessToken: %v", err)
	}
	if claims.Subject != userID.String() {
		t.Fatalf("Subject = %q, want %q", claims.Subject, userID)
	}
	if claims.SessionID != sessionID {
		t.Fatalf("SessionID = %v, want %v", claims.SessionID, sessionID)
	}
}

func TestValidateAccessTokenRejectsWrongSecret(t *testing.T) {
	token, err := SignAccessToken(uuid.New(), uuid.New(), testSecret, time.Minute)
	if err != nil {
		t.Fatalf("SignAccessToken: %v", err)
	}
	if _, err := ValidateAccessToken(token, "other-secret"); err == nil {
		t.Fatal("ValidateAccessToken with wrong secret = nil error, want error")
	}
}

func TestValidateAccessTokenRejectsExpired(t *testing.T) {
	token, err := SignAccessToken(uuid.New(), uuid.New(), testSecret, -time.Minute)
	if err != nil {
		t.Fatalf("SignAccessToken: %v", err)
	}
	if _, err := ValidateAccessToken(token, testSecret); err == nil {
		t.Fatal("ValidateAccessToken on expired token = nil error, want error")
	}
}

// The forgery this guards against: an attacker re-signs the claims with alg
// "none" and no key. Without an explicit algorithm allowlist the parser honours
// the header and accepts it.
func TestValidateAccessTokenRejectsAlgNone(t *testing.T) {
	claims := AccessClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   uuid.New().String(),
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
		},
		SessionID: uuid.New(),
	}
	forged, err := jwt.NewWithClaims(jwt.SigningMethodNone, claims).
		SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("sign none: %v", err)
	}
	if _, err := ValidateAccessToken(forged, testSecret); err == nil {
		t.Fatal("ValidateAccessToken accepted an alg=none token")
	}
}

// A token with a valid signature but no session id would sail past the
// interceptor's uuid.Nil session lookup and never be revocable.
func TestValidateAccessTokenRejectsMissingSessionID(t *testing.T) {
	claims := jwt.RegisteredClaims{
		Subject:   uuid.New().String(),
		ExpiresAt: jwt.NewNumericDate(time.Now().Add(time.Hour)),
	}
	token, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(testSecret))
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if _, err := ValidateAccessToken(token, testSecret); err == nil {
		t.Fatal("ValidateAccessToken accepted a token with no session id")
	}
}

func TestRefreshTokenHashing(t *testing.T) {
	plaintext, hash, err := GenerateRefreshToken("hmac-key")
	if err != nil {
		t.Fatalf("GenerateRefreshToken: %v", err)
	}
	if len(plaintext) != 64 {
		t.Fatalf("plaintext length = %d, want 64 hex chars (32 bytes)", len(plaintext))
	}
	if plaintext == hash {
		t.Fatal("stored hash equals the plaintext token")
	}
	if got := HashRefreshToken(plaintext, "hmac-key"); got != hash {
		t.Fatal("HashRefreshToken is not deterministic")
	}
	if got := HashRefreshToken(plaintext, "other-key"); got == hash {
		t.Fatal("HashRefreshToken ignored the key")
	}

	other, _, err := GenerateRefreshToken("hmac-key")
	if err != nil {
		t.Fatalf("GenerateRefreshToken: %v", err)
	}
	if other == plaintext {
		t.Fatal("GenerateRefreshToken returned the same token twice")
	}
}
