package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
)

// AccessClaims are the claims embedded in every access token. SessionID is what
// makes revocation work: the interceptor checks it against user_sessions on
// every call, so signing out kills the token immediately instead of at expiry.
type AccessClaims struct {
	jwt.RegisteredClaims
	SessionID uuid.UUID `json:"sid"`
}

// SignAccessToken creates an HS256 JWT for the given user and session.
func SignAccessToken(userID, sessionID uuid.UUID, secret string, ttl time.Duration) (string, error) {
	now := time.Now()
	claims := AccessClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(ttl)),
		},
		SessionID: sessionID,
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

// ValidateAccessToken parses and validates an HS256 access token.
func ValidateAccessToken(tokenString, secret string) (*AccessClaims, error) {
	// The algorithm is pinned rather than taken from the header: accepting
	// whatever the token claims is the classic JWT forgery, and "none" or an
	// RS256/HS256 confusion both start there.
	token, err := jwt.ParseWithClaims(
		tokenString,
		&AccessClaims{},
		func(*jwt.Token) (any, error) { return []byte(secret), nil },
		jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}),
	)
	if err != nil {
		return nil, fmt.Errorf("invalid access token: %w", err)
	}
	claims, ok := token.Claims.(*AccessClaims)
	if !ok {
		return nil, fmt.Errorf("unexpected claims type")
	}
	if claims.SessionID == uuid.Nil {
		return nil, fmt.Errorf("access token has no session id")
	}
	return claims, nil
}

// GenerateRefreshToken returns a random plaintext token and its HMAC-SHA256
// hash. Only the hash is stored, so a database dump is not a set of usable
// credentials.
func GenerateRefreshToken(hmacKey string) (plaintext, hash string, err error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", "", fmt.Errorf("generate refresh token: %w", err)
	}
	plaintext = hex.EncodeToString(b)
	return plaintext, HashRefreshToken(plaintext, hmacKey), nil
}

// HashRefreshToken computes the stored form of a refresh token.
//
// HMAC rather than a password hash on purpose: the input is 256 bits of
// entropy we generated, so there is nothing to brute-force and the cost of
// bcrypt would buy nothing but latency on every refresh.
func HashRefreshToken(token, hmacKey string) string {
	mac := hmac.New(sha256.New, []byte(hmacKey))
	mac.Write([]byte(token))
	return hex.EncodeToString(mac.Sum(nil))
}
