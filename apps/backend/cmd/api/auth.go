package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/phone"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/verify"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type authServer struct {
	queries   *db.Queries
	pool      *pgxpool.Pool
	logger    *zap.Logger
	sender    verify.Sender
	allowlist *phone.Allowlist
	ceiling   *sendCeiling

	jwtSecret           string
	refreshTokenHMACKey string
	accessTTL           time.Duration
	refreshTTL          time.Duration
	resendCooldown      time.Duration
}

// StartPhoneVerification asks the provider to deliver a code.
func (s *authServer) StartPhoneVerification(
	ctx context.Context,
	req *connect.Request[v1.StartPhoneVerificationRequest],
) (*connect.Response[v1.StartPhoneVerificationResponse], error) {
	num, err := s.allowlist.Parse(req.Msg.GetPhoneNumber())
	if err != nil {
		var notAllowed phone.ErrNotAllowed
		if errors.As(err, &notAllowed) {
			// Named distinctly from a malformed number so the client can say
			// "we don't serve that country yet" instead of "check the number".
			return nil, connect.NewError(connect.CodeFailedPrecondition, errors.New("that country isn't supported yet"))
		}
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}

	if err := s.ceiling.allow(ctx); err != nil {
		var ceiling *errCeilingReached
		if errors.As(err, &ceiling) {
			// Worth alerting on: this is a global budget, so hitting it means
			// either an attack or a badly wrong ceiling, and in both cases real
			// users are being turned away.
			s.logger.Error("verification send ceiling reached",
				zap.String("phone_number", num.Mask()),
				zap.Duration("window", ceiling.window),
			)
			return nil, connect.NewError(connect.CodeResourceExhausted,
				errors.New("too many verification requests right now; try again shortly"))
		}
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	signals := verify.Signals{
		DeviceID:       req.Msg.GetInstallId(),
		DevicePlatform: devicePlatformSignal(req.Msg.GetDevicePlatform()),
	}

	if err := s.sender.Start(ctx, num.E164, signals); err != nil {
		switch {
		case errors.Is(err, verify.ErrUndeliverable):
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("that number can't receive text messages"))
		case errors.Is(err, verify.ErrTooManyAttempts):
			return nil, connect.NewError(connect.CodeResourceExhausted, errors.New("too many attempts; try again later"))
		}
		// The provider's own message can name internal resources, so it is
		// logged and not returned.
		s.logger.Error("start verification", zap.String("phone_number", num.Mask()), zap.Error(err))
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("couldn't send a code right now"))
	}

	return connect.NewResponse(&v1.StartPhoneVerificationResponse{
		ResendAvailableInSeconds: int32(s.resendCooldown.Seconds()),
		CodeLength:               int32(s.sender.CodeLength()),
	}), nil
}

// VerifyPhone exchanges a code for a session, creating the account if this is
// the first time the number has been seen.
func (s *authServer) VerifyPhone(
	ctx context.Context,
	req *connect.Request[v1.VerifyPhoneRequest],
) (*connect.Response[v1.VerifyPhoneResponse], error) {
	num, err := s.allowlist.Parse(req.Msg.GetPhoneNumber())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}

	result, err := s.sender.Check(ctx, num.E164, req.Msg.GetCode())
	if err != nil {
		if errors.Is(err, verify.ErrTooManyAttempts) {
			return nil, connect.NewError(connect.CodeResourceExhausted, errors.New("too many attempts; request a new code"))
		}
		s.logger.Error("check verification", zap.String("phone_number", num.Mask()), zap.Error(err))
		return nil, connect.NewError(connect.CodeUnavailable, errors.New("couldn't check that code right now"))
	}
	if result != verify.ResultApproved {
		// One error for wrong, expired, and already-used. Distinguishing them
		// tells an attacker whether a number has a live verification in flight.
		return nil, connect.NewError(connect.CodeUnauthenticated, errors.New("that code isn't right"))
	}

	platform, err := devicePlatformToDB(req.Msg.GetDevicePlatform())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
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

	var (
		user      db.User
		isNewUser bool
	)
	method, err := qtx.GetAuthMethod(ctx, db.GetAuthMethodParams{
		AuthService: db.AuthServicePHONE,
		Subject:     num.E164,
	})
	switch {
	case err == nil:
		user, err = qtx.GetUser(ctx, method.UserID)
		if err != nil {
			// The auth method outlived its user, which DeleteAccount is written
			// to prevent. Treat it as an unclaimed number rather than a dead
			// end, so the person can sign up again.
			if !errors.Is(err, pgx.ErrNoRows) {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load user: %w", err))
			}
			user, isNewUser, err = s.createAccount(ctx, qtx, num, req.Msg.TimeZone, true)
			if err != nil {
				return nil, err
			}
		} else if err := qtx.TouchAuthMethod(ctx, db.TouchAuthMethodParams{
			AuthService: db.AuthServicePHONE,
			Subject:     num.E164,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("touch auth method: %w", err))
		}
	case errors.Is(err, pgx.ErrNoRows):
		user, isNewUser, err = s.createAccount(ctx, qtx, num, req.Msg.TimeZone, false)
		if err != nil {
			return nil, err
		}
	default:
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("lookup auth method: %w", err))
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

	s.logger.Info("phone verified",
		zap.String("user_id", user.ID.String()),
		zap.String("device_id", device.ID.String()),
		zap.Bool("is_new_user", isNewUser),
		zap.Bool("facebook_connected", device.FacebookConnected),
	)

	return connect.NewResponse(&v1.VerifyPhoneResponse{
		AccessToken:                 accessToken,
		RefreshToken:                refreshToken,
		AccessTokenExpiresInSeconds: int32(s.accessTTL.Seconds()),
		Viewer:                      viewerProto(user, num.E164),
		IsNewUser:                   isNewUser,
		Device:                      deviceProto(device),
	}), nil
}

// createAccount makes the user and its phone auth method. reclaim is set when a
// stale auth-method row for this number has to be replaced.
func (s *authServer) createAccount(
	ctx context.Context,
	qtx *db.Queries,
	num phone.Number,
	timeZone *string,
	reclaim bool,
) (db.User, bool, error) {
	if reclaim {
		if err := qtx.DeleteAuthMethodBySubject(ctx, db.DeleteAuthMethodBySubjectParams{
			AuthService: db.AuthServicePHONE,
			Subject:     num.E164,
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
		AuthService: db.AuthServicePHONE,
		Subject:     num.E164,
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

// devicePlatformSignal renders the platform the way verification providers
// spell it. Separate from devicePlatformToDB because that one is the storage
// encoding and must reject an unset value; here an unset value is a signal we
// simply do not have, and refusing to send a code over it would be absurd.
func devicePlatformSignal(p v1.DevicePlatform) string {
	switch p {
	case v1.DevicePlatform_DEVICE_PLATFORM_IOS:
		return "ios"
	case v1.DevicePlatform_DEVICE_PLATFORM_ANDROID:
		return "android"
	case v1.DevicePlatform_DEVICE_PLATFORM_WEB:
		return "web"
	default:
		return ""
	}
}

func timestamptz(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}
