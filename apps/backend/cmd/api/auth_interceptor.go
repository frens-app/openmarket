package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// skipAuth lists the procedures reachable without a session.
//
// Allowlist, not a denylist: a new RPC is authenticated by default, and opening
// it up is a visible edit to this map. The reverse ordering is how endpoints
// end up public by accident.
var skipAuth = map[string]bool{
	apiv1connect.AuthServiceGetSignInOptionsProcedure:       true,
	apiv1connect.AuthServiceStartPhoneVerificationProcedure: true,
	apiv1connect.AuthServiceVerifyPhoneProcedure:            true,
	apiv1connect.AuthServiceRefreshTokenProcedure:           true,
}

type activeSessionChecker interface {
	CheckActiveSession(context.Context, db.CheckActiveSessionParams) (uuid.UUID, error)
}

// authenticate validates the Authorization header and returns a context
// carrying the user and session ids.
func authenticate(
	ctx context.Context,
	procedure string,
	header http.Header,
	jwtSecret string,
	sessions activeSessionChecker,
) (context.Context, error) {
	if skipAuth[procedure] {
		return ctx, nil
	}

	authz := header.Get("Authorization")
	if authz == "" {
		return nil, connect.NewError(connect.CodeUnauthenticated, nil)
	}
	token := strings.TrimPrefix(authz, "Bearer ")
	if token == authz {
		return nil, connect.NewError(connect.CodeUnauthenticated, nil)
	}

	claims, err := auth.ValidateAccessToken(token, jwtSecret)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	userID, err := uuid.Parse(claims.Subject)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}

	// A valid signature is not enough. The session row is checked on every
	// call so Logout and DeleteAccount take effect immediately rather than
	// whenever the access token happens to expire.
	if _, err := sessions.CheckActiveSession(ctx, db.CheckActiveSessionParams{
		ID:     claims.SessionID,
		UserID: userID,
	}); err != nil {
		switch {
		case errors.Is(err, pgx.ErrNoRows):
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("session is no longer valid"))
		case errors.Is(err, context.Canceled):
			return nil, connect.NewError(connect.CodeCanceled, err)
		case errors.Is(err, context.DeadlineExceeded):
			return nil, connect.NewError(connect.CodeDeadlineExceeded, err)
		default:
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("check active session: %w", err))
		}
	}

	ctx = auth.WithUserID(ctx, userID)
	ctx = auth.WithSessionID(ctx, claims.SessionID)
	return ctx, nil
}

type authInterceptor struct {
	jwtSecret string
	sessions  activeSessionChecker
}

func newAuthInterceptor(jwtSecret string, sessions activeSessionChecker) connect.Interceptor {
	return &authInterceptor{jwtSecret: jwtSecret, sessions: sessions}
}

func (a *authInterceptor) WrapUnary(next connect.UnaryFunc) connect.UnaryFunc {
	return func(ctx context.Context, req connect.AnyRequest) (connect.AnyResponse, error) {
		ctx, err := authenticate(ctx, req.Spec().Procedure, req.Header(), a.jwtSecret, a.sessions)
		if err != nil {
			return nil, err
		}
		return next(ctx, req)
	}
}

// WrapStreamingClient is a no-op: this binary is a server, never a streaming
// client of its own services.
func (*authInterceptor) WrapStreamingClient(next connect.StreamingClientFunc) connect.StreamingClientFunc {
	return next
}

func (a *authInterceptor) WrapStreamingHandler(next connect.StreamingHandlerFunc) connect.StreamingHandlerFunc {
	return func(ctx context.Context, conn connect.StreamingHandlerConn) error {
		ctx, err := authenticate(ctx, conn.Spec().Procedure, conn.RequestHeader(), a.jwtSecret, a.sessions)
		if err != nil {
			return err
		}
		return next(ctx, conn)
	}
}
