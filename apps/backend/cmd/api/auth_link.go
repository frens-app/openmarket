package main

import (
	"context"
	"errors"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/identity"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/jackc/pgx/v5"
)

func (s *authServer) BeginLinkSignIn(ctx context.Context, req *connect.Request[v1.BeginLinkSignInRequest]) (*connect.Response[v1.BeginLinkSignInResponse], error) {
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	provider, err := authService(req.Msg.Provider)
	if err != nil {
		return nil, err
	}
	if !s.identities.Enabled(string(provider)) {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("this sign-in provider is not configured yet"))
	}
	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	if err != nil {
		return nil, notFoundOrInternal(err, "load device")
	}
	nonce, hash, err := identity.NewNonce()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.queries.CreateLinkSignInChallenge(ctx, db.CreateLinkSignInChallengeParams{
		NonceHash: hash, AuthService: provider, InstallID: device.InstallID, LinkingSessionID: &sessionID,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.BeginLinkSignInResponse{Nonce: nonce}), nil
}

// LinkSignIn replaces a phone login without changing the user ID or sessions.
// Keeping the same ID preserves history and analytics identity. It does not
// merge accounts or support switching between social providers.
func (s *authServer) LinkSignIn(ctx context.Context, req *connect.Request[v1.LinkSignInRequest]) (*connect.Response[v1.LinkSignInResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	provider, err := authService(req.Msg.Provider)
	if err != nil {
		return nil, err
	}
	verified, err := s.identities.Verify(ctx, string(provider), req.Msg.IdentityToken, req.Msg.Nonce)
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("couldn't verify your sign-in; please try again"))
	}
	firstName, err := profileName(req.Msg.FirstName, "first_name", 256)
	if err != nil {
		return nil, err
	}
	lastName, err := profileName(req.Msg.LastName, "last_name", 256)
	if err != nil {
		return nil, err
	}
	displayName, err := profileName(req.Msg.DisplayName, "display_name", 512)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)
	if _, err := qtx.ConsumeLinkSignInChallenge(ctx, db.ConsumeLinkSignInChallengeParams{
		NonceHash: identity.HashNonce(req.Msg.Nonce), AuthService: provider, LinkingSessionID: &sessionID,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("link request expired; please try again"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	// Use the same identity lock as sign-in. Account/session locks serialize
	// linking with deletion, logout, and other linking attempts.
	if err := qtx.LockAuthIdentity(ctx, string(provider)+":"+verified.Subject); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if _, err := qtx.LockUser(ctx, userID); err != nil {
		return nil, notFoundOrInternal(err, "load user")
	}
	if _, err := qtx.LockActiveSession(ctx, db.LockActiveSessionParams{ID: sessionID, UserID: userID}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("session is no longer valid"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	current, err := qtx.GetAuthMethodForUser(ctx, userID)
	if err != nil {
		return nil, notFoundOrInternal(err, "load sign-in provider")
	}
	if current.AuthService != db.AuthServicePHONE && (current.AuthService != provider || current.Subject != verified.Subject) {
		return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("this account already uses Apple or Google; reopen the app to refresh your account"))
	}
	existing, err := qtx.GetAuthMethod(ctx, db.GetAuthMethodParams{AuthService: provider, Subject: verified.Subject})
	switch {
	case err == nil && existing.UserID != userID:
		return nil, connect.NewError(connect.CodeAlreadyExists, errors.New("that Apple or Google login already belongs to another Openmarket account; choose a different login to keep this account's history"))
	case errors.Is(err, pgx.ErrNoRows):
		if _, err := qtx.CreateAuthMethod(ctx, db.CreateAuthMethodParams{UserID: userID, AuthService: provider, Subject: verified.Subject}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	case err != nil:
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if current.AuthService == db.AuthServicePHONE {
		if err := qtx.DeleteAuthMethodBySubject(ctx, db.DeleteAuthMethodBySubjectParams{AuthService: db.AuthServicePHONE, Subject: current.Subject}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	user, err := qtx.FillMissingUserNames(ctx, db.FillMissingUserNamesParams{ID: userID, FirstName: firstName, LastName: lastName, DisplayName: displayName})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if verified.VerifiedEmail != "" {
		if err := qtx.SetUserEmail(ctx, db.SetUserEmailParams{ID: userID, Email: verified.VerifiedEmail}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.LinkSignInResponse{Viewer: viewerProto(user, provider, verified.Subject)}), nil
}
