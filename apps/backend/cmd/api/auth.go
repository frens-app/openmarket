package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/identity"
	"frens.lol/openmarket/backend/pkg/phone"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/verify"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type identityVerifier interface {
	Enabled(string) bool
	Verify(context.Context, string, string, string) (identity.Identity, error)
}

type authServer struct {
	queries        *db.Queries
	pool           *pgxpool.Pool
	logger         *zap.Logger
	identities     identityVerifier
	sender         verify.Sender
	allowlist      *phone.Allowlist
	ceiling        *sendCeiling
	resendCooldown time.Duration

	jwtSecret           string
	refreshTokenHMACKey string
	accessTTL           time.Duration
	refreshTTL          time.Duration
}

func authService(provider v1.SignInProvider) (db.AuthService, error) {
	switch provider {
	case v1.SignInProvider_SIGN_IN_PROVIDER_APPLE:
		return db.AuthServiceAPPLE, nil
	case v1.SignInProvider_SIGN_IN_PROVIDER_GOOGLE:
		return db.AuthServiceGOOGLE, nil
	default:
		return "", connect.NewError(connect.CodeInvalidArgument, errors.New("choose Apple or Google"))
	}
}

func (s *authServer) BeginSignIn(ctx context.Context, req *connect.Request[v1.BeginSignInRequest]) (*connect.Response[v1.BeginSignInResponse], error) {
	provider, err := authService(req.Msg.Provider)
	if err != nil {
		return nil, err
	}
	if !s.identities.Enabled(string(provider)) {
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("this sign-in provider is not configured yet"))
	}
	nonce, hash, err := identity.NewNonce()
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.queries.CreateSignInChallenge(ctx, db.CreateSignInChallengeParams{
		NonceHash: hash, AuthService: provider, InstallID: req.Msg.InstallId,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.BeginSignInResponse{Nonce: nonce}), nil
}

func (s *authServer) SignIn(ctx context.Context, req *connect.Request[v1.SignInRequest]) (*connect.Response[v1.SignInResponse], error) {
	provider, err := authService(req.Msg.Provider)
	if err != nil {
		return nil, err
	}
	verified, err := s.identities.Verify(ctx, string(provider), req.Msg.IdentityToken, req.Msg.Nonce)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("couldn't verify your sign-in; please try again"))
	}
	subject := verified.Subject
	platform, err := devicePlatformToDB(req.Msg.GetDevicePlatform())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
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

	refreshToken, refreshHash, err := auth.GenerateRefreshToken(s.refreshTokenHMACKey)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)

	if _, err := qtx.ConsumeSignInChallenge(ctx, db.ConsumeSignInChallengeParams{
		NonceHash: identity.HashNonce(req.Msg.Nonce), AuthService: provider, InstallID: req.Msg.InstallId,
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("sign-in expired; please try again"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := qtx.LockAuthIdentity(ctx, string(provider)+":"+subject); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	var (
		user      db.User
		isNewUser bool
	)
	method, err := qtx.GetAuthMethod(ctx, db.GetAuthMethodParams{
		AuthService: provider,
		Subject:     subject,
	})
	switch {
	case err == nil:
		user, err = qtx.GetUser(ctx, method.UserID)
		if err != nil {
			// A deleted account cannot prevent this identity from signing up again.
			if !errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load user: %w", err))
			}
			user, isNewUser, err = s.createAccount(ctx, qtx, provider, subject, req.Msg.TimeZone, true)
			if err != nil {
				return nil, err
			}
		} else if err := qtx.TouchAuthMethod(ctx, db.TouchAuthMethodParams{
			AuthService: provider,
			Subject:     subject,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("touch auth method: %w", err))
		}
	case errors.Is(err, pgx.ErrNoRows):
		user, isNewUser, err = s.createAccount(ctx, qtx, provider, subject, req.Msg.TimeZone, false)
		if err != nil {
			return nil, err
		}
	default:
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("lookup auth method: %w", err))
	}

	if firstName != nil || lastName != nil || displayName != nil {
		user, err = qtx.FillMissingUserNames(ctx, db.FillMissingUserNamesParams{
			ID: user.ID, FirstName: firstName, LastName: lastName, DisplayName: displayName,
		})
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("save profile names: %w", err))
		}
	}

	if verified.VerifiedEmail != "" {
		if err := qtx.SetUserEmail(ctx, db.SetUserEmailParams{ID: user.ID, Email: verified.VerifiedEmail}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("save account email: %w", err))
		}
	}

	// The install is looked up before the session is made, so signing in again
	// on a phone that already has one keeps its Facebook and push state instead
	// of starting a second row beside it.
	device, err := qtx.UpsertDevice(ctx, db.UpsertDeviceParams{
		UserID:    user.ID,
		InstallID: req.Msg.GetInstallId(),
		Platform:  platform,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("upsert device: %w", err))
	}

	session, err := qtx.CreateSession(ctx, db.CreateSessionParams{
		UserID:                user.ID,
		RefreshTokenHash:      refreshHash,
		RefreshTokenExpiresAt: timestamptz(time.Now().Add(s.refreshTTL)),
		DevicePlatform:        platform,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create session: %w", err))
	}
	if err := qtx.SetSessionDevice(ctx, db.SetSessionDeviceParams{
		ID:       session.ID,
		DeviceID: &device.ID,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("link session to device: %w", err))
	}

	accessToken, err := auth.SignAccessToken(user.ID, session.ID, s.jwtSecret, s.accessTTL)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	s.logger.Info("signed in",
		zap.String("user_id", user.ID.String()),
		zap.String("device_id", device.ID.String()),
		zap.Bool("is_new_user", isNewUser),
		zap.Bool("facebook_connected", device.FacebookConnected),
	)

	return connect.NewResponse(&v1.SignInResponse{
		AccessToken:                 accessToken,
		RefreshToken:                refreshToken,
		AccessTokenExpiresInSeconds: int32(s.accessTTL.Seconds()),
		Viewer:                      viewerProto(user, provider, subject),
		IsNewUser:                   isNewUser,
		Device:                      deviceProto(device),
	}), nil
}

func (s *authServer) createAccount(
	ctx context.Context,
	qtx *db.Queries,
	provider db.AuthService,
	subject string,
	timeZone *string,
	reclaim bool,
) (db.User, bool, error) {
	if reclaim {
		if err := qtx.DeleteAuthMethodBySubject(ctx, db.DeleteAuthMethodBySubjectParams{
			AuthService: provider,
			Subject:     subject,
		}); err != nil {
			return db.User{}, false, connect.NewError(connect.CodeInternal, fmt.Errorf("release stale auth method: %w", err))
		}
	}

	user, err := qtx.CreateUser(ctx, timeZone)
	if err != nil {
		return db.User{}, false, connect.NewError(connect.CodeInternal, fmt.Errorf("create user: %w", err))
	}
	if _, err := qtx.CreateAuthMethod(ctx, db.CreateAuthMethodParams{
		UserID:      user.ID,
		AuthService: provider,
		Subject:     subject,
	}); err != nil {
		return db.User{}, false, connect.NewError(connect.CodeInternal, fmt.Errorf("create auth method: %w", err))
	}
	return user, true, nil
}

// RefreshToken rotates a refresh token and mints a new access token.
func (s *authServer) RefreshToken(
	ctx context.Context,
	req *connect.Request[v1.RefreshTokenRequest],
) (*connect.Response[v1.RefreshTokenResponse], error) {
	oldHash := auth.HashRefreshToken(req.Msg.GetRefreshToken(), s.refreshTokenHMACKey)

	session, err := s.queries.GetSessionByRefreshTokenHash(ctx, oldHash)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("session expired"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load session: %w", err))
	}

	newToken, newHash, err := auth.GenerateRefreshToken(s.refreshTokenHMACKey)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Conditional on the old hash, which is what makes a race safe: two clients
	// refreshing the same token both run this and only one matches a row.
	if _, err := s.queries.RotateRefreshToken(ctx, db.RotateRefreshTokenParams{
		RefreshTokenHash:      oldHash,
		RefreshTokenHash_2:    newHash,
		RefreshTokenExpiresAt: timestamptz(time.Now().Add(s.refreshTTL)),
	}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("session expired"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("rotate refresh token: %w", err))
	}

	accessToken, err := auth.SignAccessToken(session.UserID, session.ID, s.jwtSecret, s.accessTTL)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	return connect.NewResponse(&v1.RefreshTokenResponse{
		AccessToken:                 accessToken,
		RefreshToken:                newToken,
		AccessTokenExpiresInSeconds: int32(s.accessTTL.Seconds()),
	}), nil
}

// Logout revokes the calling session only. Other devices stay signed in.
func (s *authServer) Logout(
	ctx context.Context,
	_ *connect.Request[v1.LogoutRequest],
) (*connect.Response[v1.LogoutResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if err := s.queries.RevokeSession(ctx, db.RevokeSessionParams{ID: sessionID, UserID: userID}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("revoke session: %w", err))
	}
	return connect.NewResponse(&v1.LogoutResponse{}), nil
}

func devicePlatformToDB(p v1.DevicePlatform) (db.DevicePlatform, error) {
	switch p {
	case v1.DevicePlatform_DEVICE_PLATFORM_IOS:
		return db.DevicePlatformIOS, nil
	case v1.DevicePlatform_DEVICE_PLATFORM_ANDROID:
		return db.DevicePlatformANDROID, nil
	case v1.DevicePlatform_DEVICE_PLATFORM_WEB:
		return db.DevicePlatformWEB, nil
	default:
		return "", fmt.Errorf("device_platform must be set")
	}
}

func timestamptz(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}
