package main

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
)

type userServer struct {
	queries *db.Queries
	pool    *pgxpool.Pool
	logger  *zap.Logger
}

func (s *userServer) GetViewer(
	ctx context.Context,
	_ *connect.Request[v1.GetViewerRequest],
) (*connect.Response[v1.GetViewerResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	user, err := s.queries.GetUser(ctx, userID)
	if err != nil {
		return nil, notFoundOrInternal(err, "load user")
	}
	phoneNumber, err := s.queries.GetPhoneNumberForUser(ctx, userID)
	if err != nil {
		return nil, notFoundOrInternal(err, "load phone number")
	}

	response := &v1.GetViewerResponse{Viewer: viewerProto(user, phoneNumber)}

	// device_id is nullable — a deleted device row sets it null rather than
	// taking the session with it — so a viewer without a device is possible.
	// Returning one beats failing the call: the client re-reports its Facebook
	// state on the next foreground, and signing in again recreates the row.
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	switch {
	case err == nil:
		response.Device = deviceProto(device)
	case !errors.Is(err, pgx.ErrNoRows):
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load device: %w", err))
	}

	return connect.NewResponse(response), nil
}

// SetFacebookConnection records whether the Facebook webview session exists on
// this install.
//
// The client is the only thing that can know this — the state is a cookie jar in
// its own container, and there is no server-side way to observe it — so this
// endpoint takes the client's word for it. That is fine for what the flag is
// for: knowing whether to prompt on this device. It would not be fine as an
// authorisation input, and nothing treats it as one.
func (s *userServer) SetFacebookConnection(
	ctx context.Context,
	req *connect.Request[v1.SetFacebookConnectionRequest],
) (*connect.Response[v1.SetFacebookConnectionResponse], error) {
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// The device comes from the session, not from the request. A client cannot
	// report on an install that isn't the one it signed in from.
	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition,
				errors.New("this session has no device; sign in again"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load device: %w", err))
	}

	updated, err := s.queries.SetDeviceFacebookConnection(ctx, db.SetDeviceFacebookConnectionParams{
		ID:        device.ID,
		Connected: req.Msg.GetConnected(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("set facebook connection: %w", err))
	}

	if updated.FacebookConnected != device.FacebookConnected {
		s.logger.Info("facebook connection changed",
			zap.String("device_id", device.ID.String()),
			zap.Bool("connected", updated.FacebookConnected),
		)
	}

	return connect.NewResponse(&v1.SetFacebookConnectionResponse{
		Device: deviceProto(updated),
	}), nil
}

func (s *userServer) UpdateViewer(
	ctx context.Context,
	req *connect.Request[v1.UpdateViewerRequest],
) (*connect.Response[v1.UpdateViewerResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Three states, and they have to stay distinct: field absent means leave
	// it, present-and-empty means clear it, present-and-set means write it.
	// Collapsing the first two is why partial updates usually end up wiping
	// data.
	var (
		displayName *string
		clearName   bool
	)
	if req.Msg.DisplayName != nil {
		trimmed := strings.TrimSpace(req.Msg.GetDisplayName())
		if trimmed == "" {
			clearName = true
		} else {
			if len([]rune(trimmed)) > 64 {
				return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("display_name is too long"))
			}
			displayName = &trimmed
		}
	}

	var markComplete *bool
	if req.Msg.OnboardingCompleted != nil && req.Msg.GetOnboardingCompleted() {
		t := true
		markComplete = &t
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)

	if clearName {
		if _, err := qtx.ClearUserDisplayName(ctx, userID); err != nil {
			return nil, notFoundOrInternal(err, "clear display name")
		}
	}
	user, err := qtx.UpdateUser(ctx, db.UpdateUserParams{
		ID:                     userID,
		DisplayName:            displayName,
		MarkOnboardingComplete: markComplete,
	})
	if err != nil {
		return nil, notFoundOrInternal(err, "update user")
	}
	phoneNumber, err := qtx.GetPhoneNumberForUser(ctx, userID)
	if err != nil {
		return nil, notFoundOrInternal(err, "load phone number")
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	return connect.NewResponse(&v1.UpdateViewerResponse{Viewer: viewerProto(user, phoneNumber)}), nil
}

func (s *userServer) RegisterDeviceToken(
	ctx context.Context,
	req *connect.Request[v1.RegisterDeviceTokenRequest],
) (*connect.Response[v1.RegisterDeviceTokenResponse], error) {
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	token := strings.TrimSpace(req.Msg.GetPushToken())

	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition,
				errors.New("this session has no device; sign in again"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load device: %w", err))
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)

	// A refusal arrives with no token, and it is stored as NULL rather than "".
	// The unique index on push_token would otherwise collide the second time any
	// device declined — and an empty string is not an address anyway.
	var pushToken *string
	if token != "" {
		pushToken = &token

		// The same token moves between rows — one phone, two accounts. The
		// unique index would reject the new holder, so the old one is cleared
		// first, in the same transaction: a crash between the two would leave
		// the token on a row that can no longer be pushed to.
		if err := qtx.ClearDevicePushTokenElsewhere(ctx, db.ClearDevicePushTokenElsewhereParams{
			PushToken: pushToken,
			ID:        device.ID,
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("clear stale push token: %w", err))
		}
	}

	if err := qtx.UpdateDevicePushToken(ctx, db.UpdateDevicePushTokenParams{
		ID:                           device.ID,
		PushToken:                    pushToken,
		NotificationPermissionStatus: permissionStatusToDB(req.Msg.GetPermissionStatus()),
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("update push token: %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	return connect.NewResponse(&v1.RegisterDeviceTokenResponse{}), nil
}

// DeleteAccount soft-deletes the user, releases the phone number, and revokes
// every session.
//
// Releasing the auth method is the part that is easy to skip and expensive to
// get wrong: the row's primary key is the phone number, so leaving it behind
// would mean the person can never sign up again with the number they own.
func (s *userServer) DeleteAccount(
	ctx context.Context,
	_ *connect.Request[v1.DeleteAccountRequest],
) (*connect.Response[v1.DeleteAccountResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("begin tx: %w", err))
	}
	defer func() { _ = tx.Rollback(ctx) }()
	qtx := s.queries.WithTx(tx)

	if err := qtx.SoftDeleteUser(ctx, userID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("soft delete user: %w", err))
	}
	if err := qtx.DeleteAuthMethodsForUser(ctx, userID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("delete auth methods: %w", err))
	}
	if err := qtx.RevokeAllSessionsForUser(ctx, userID); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("revoke sessions: %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("commit: %w", err))
	}

	s.logger.Info("account deleted", zap.String("user_id", userID.String()))
	return connect.NewResponse(&v1.DeleteAccountResponse{}), nil
}

func viewerProto(user db.User, phoneNumber string) *v1.Viewer {
	viewer := &v1.Viewer{
		Id:                  user.ID.String(),
		PhoneNumber:         phoneNumber,
		DisplayName:         user.DisplayName,
		OnboardingCompleted: user.OnboardingCompletedAt.Valid,
	}
	if user.CreatedAt.Valid {
		viewer.CreatedAt = user.CreatedAt.Time.UTC().Format("2006-01-02T15:04:05Z07:00")
	}
	return viewer
}

func deviceProto(device db.UserDevice) *v1.Device {
	proto := &v1.Device{
		Id:                device.ID.String(),
		FacebookConnected: device.FacebookConnected,
	}
	if device.FacebookConnectedAt.Valid {
		at := device.FacebookConnectedAt.Time.UTC().Format(time.RFC3339)
		proto.FacebookConnectedAt = &at
	}
	return proto
}

func permissionStatusToDB(s v1.NotificationPermissionStatus) db.NotificationPermissionStatus {
	switch s {
	case v1.NotificationPermissionStatus_NOTIFICATION_PERMISSION_STATUS_ENABLED:
		return db.NotificationPermissionStatusENABLED
	case v1.NotificationPermissionStatus_NOTIFICATION_PERMISSION_STATUS_DISABLED:
		return db.NotificationPermissionStatusDISABLED
	default:
		return db.NotificationPermissionStatusUNKNOWN
	}
}

// notFoundOrInternal maps a missing row onto NotFound. A user whose row is gone
// mid-session is a deleted account, and the client should sign out rather than
// retry.
func notFoundOrInternal(err error, what string) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return connect.NewError(connect.CodeNotFound, errors.New("account no longer exists"))
	}
	return connect.NewError(connect.CodeInternal, fmt.Errorf("%s: %w", what, err))
}
