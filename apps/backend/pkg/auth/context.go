package auth

import (
	"context"
	"fmt"

	"github.com/google/uuid"
)

type contextKey int

const (
	userIDKey contextKey = iota
	sessionIDKey
)

// WithUserID returns a context carrying the authenticated user.
func WithUserID(ctx context.Context, userID uuid.UUID) context.Context {
	return context.WithValue(ctx, userIDKey, userID)
}

// WithSessionID returns a context carrying the authenticated session.
func WithSessionID(ctx context.Context, sessionID uuid.UUID) context.Context {
	return context.WithValue(ctx, sessionIDKey, sessionID)
}

// UserID returns the authenticated user, or an error if the context did not
// pass through the auth interceptor. Handlers treat the error as a bug rather
// than a rejected request — an unauthenticated call never reaches them.
func UserID(ctx context.Context) (uuid.UUID, error) {
	id, ok := ctx.Value(userIDKey).(uuid.UUID)
	if !ok {
		return uuid.Nil, fmt.Errorf("no user id in context")
	}
	return id, nil
}

// SessionID returns the authenticated session id.
func SessionID(ctx context.Context) (uuid.UUID, error) {
	id, ok := ctx.Value(sessionIDKey).(uuid.UUID)
	if !ok {
		return uuid.Nil, fmt.Errorf("no session id in context")
	}
	return id, nil
}
