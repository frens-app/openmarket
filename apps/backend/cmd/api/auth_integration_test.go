package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/identity"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
)

type testIdentityVerifier struct{}

func (testIdentityVerifier) Enabled(string) bool { return true }
func (testIdentityVerifier) Verify(_ context.Context, _, token, _ string) (identity.Identity, error) {
	if token == "invalid" {
		return identity.Identity{}, errors.New("invalid token")
	}
	subject, email, _ := strings.Cut(token, "|")
	return identity.Identity{Subject: subject, VerifiedEmail: email}, nil
}

// Run only against a new disposable database, never a development/production DB.
func TestSocialAuthIntegration(t *testing.T) {
	databaseURL := os.Getenv("AUTH_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set AUTH_TEST_DATABASE_URL to a new disposable database ending in _auth_test")
	}
	ctx := context.Background()
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(config.ConnConfig.Database, "_auth_test") {
		t.Fatal("database name must end in _auth_test")
	}
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer sqlDB.Close()
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatal(err)
	}
	goose.SetLogger(goose.NopLogger())
	if err := goose.UpTo(sqlDB, "../../deployments/migrations", 14); err != nil {
		t.Fatal(err)
	}
	queries := db.New(pool)
	var oldUserID uuid.UUID
	err = pool.QueryRow(ctx, "INSERT INTO users (display_name,onboarding_completed_at) VALUES ('Phone user',CURRENT_TIMESTAMP) RETURNING id").Scan(&oldUserID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "INSERT INTO user_auth_methods (user_id,auth_service,subject) VALUES ($1,'PHONE','+15005550100')", oldUserID); err != nil {
		t.Fatal(err)
	}
	oldRefresh, oldHash, err := auth.GenerateRefreshToken("refresh-secret")
	if err != nil {
		t.Fatal(err)
	}
	oldSession, err := queries.CreateSession(ctx, db.CreateSessionParams{UserID: oldUserID, RefreshTokenHash: oldHash, RefreshTokenExpiresAt: timestamptz(time.Now().Add(time.Hour)), DevicePlatform: db.DevicePlatformIOS})
	if err != nil {
		t.Fatal(err)
	}
	oldAccess, err := auth.SignAccessToken(oldUserID, oldSession.ID, "access-secret", time.Hour)
	if err != nil {
		t.Fatal(err)
	}
	oldDevice, err := queries.UpsertDevice(ctx, db.UpsertDeviceParams{UserID: oldUserID, InstallID: "phone-install", Platform: db.DevicePlatformIOS})
	if err != nil {
		t.Fatal(err)
	}
	if err := queries.SetSessionDevice(ctx, db.SetSessionDeviceParams{ID: oldSession.ID, DeviceID: &oldDevice.ID}); err != nil {
		t.Fatal(err)
	}
	if _, err := queries.SetDeviceFacebookConnection(ctx, db.SetDeviceFacebookConnectionParams{ID: oldDevice.ID, Connected: true}); err != nil {
		t.Fatal(err)
	}
	if err := queries.UpdateDevicePushToken(ctx, db.UpdateDevicePushTokenParams{ID: oldDevice.ID, PushToken: stringPointer("existing-push-token"), NotificationPermissionStatus: db.NotificationPermissionStatusENABLED}); err != nil {
		t.Fatal(err)
	}
	if err := queries.RecordVerificationSend(ctx); err != nil {
		t.Fatal(err)
	}
	var oldCheckID uuid.UUID
	if err := pool.QueryRow(ctx, "INSERT INTO price_checks (user_id, device_id, description) VALUES ($1,$2,'Test item') RETURNING id", oldUserID, oldDevice.ID).Scan(&oldCheckID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "INSERT INTO price_check_photos (price_check_id,ordinal,sha256,bytes,width,height) VALUES ($1,0,decode('00','hex'),1,1,1)", oldCheckID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "INSERT INTO llm_runs (user_id,price_check_id,stage,provider,model,latency_ms,status) VALUES ($1,$2,'IDENTIFY','test','test',1,'OK')", oldUserID, oldCheckID); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpTo(sqlDB, "../../deployments/migrations", 15); err != nil {
		t.Fatal(err)
	}
	var existingUserID uuid.UUID
	if err := pool.QueryRow(ctx, "INSERT INTO users (display_name) VALUES ('Existing display') RETURNING id").Scan(&existingUserID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO user_devices (user_id,install_id,platform,facebook_connected,facebook_connected_at)
		VALUES ($1,'existing-1','IOS',true,'2026-01-01T00:00:00Z'),
		       ($1,'existing-2','IOS',false,'2026-02-01T00:00:00Z')`, existingUserID); err != nil {
		t.Fatal(err)
	}
	if err := goose.Up(sqlDB, "../../deployments/migrations"); err != nil {
		t.Fatal(err)
	}
	migratedUser, err := queries.GetUser(ctx, existingUserID)
	if err != nil || migratedUser.DisplayName == nil || *migratedUser.DisplayName != "Existing display" || migratedUser.FirstName != nil || migratedUser.LastName != nil || migratedUser.Email != nil {
		t.Fatalf("name migration changed existing data: %+v %v", migratedUser, err)
	}
	if !migratedUser.FacebookLastConnectedAt.Valid || migratedUser.FacebookLastConnectedAt.Time.UTC().Format(time.RFC3339) != "2026-02-01T00:00:00Z" {
		t.Fatalf("Facebook migration did not preserve latest connection history: %+v", migratedUser)
	}
	server := &authServer{pool: pool, queries: queries, logger: zap.NewNop(), identities: testIdentityVerifier{}, jwtSecret: "access-secret", refreshTokenHMACKey: "refresh-secret", accessTTL: time.Hour, refreshTTL: time.Hour}
	users := &userServer{pool: pool, queries: queries, logger: zap.NewNop()}
	t.Run("phone accounts data and sessions survive migration", func(t *testing.T) {
		header := http.Header{"Authorization": []string{"Bearer " + oldAccess}}
		oldCtx, err := authenticate(ctx, apiv1connect.UserServiceGetViewerProcedure, header, server.jwtSecret, queries)
		if err != nil {
			t.Fatalf("old access rejected: %v", err)
		}
		viewer, err := users.GetViewer(oldCtx, connect.NewRequest(&v1.GetViewerRequest{}))
		if err != nil {
			t.Fatal(err)
		}
		if viewer.Msg.Viewer.Id != oldUserID.String() || viewer.Msg.Viewer.PhoneNumber != "+15005550100" || viewer.Msg.Viewer.SignInProvider != "phone" || !viewer.Msg.Viewer.OnboardingCompleted || !viewer.Msg.Device.FacebookConnected || viewer.Msg.Device.Id != oldDevice.ID.String() {
			t.Fatalf("existing account state changed: %v", viewer.Msg)
		}
		device, err := queries.GetDeviceForSession(oldCtx, oldSession.ID)
		if err != nil || device.PushToken == nil || *device.PushToken != "existing-push-token" {
			t.Fatalf("push state lost: %v", err)
		}
		refreshed, err := server.RefreshToken(ctx, connect.NewRequest(&v1.RefreshTokenRequest{RefreshToken: oldRefresh}))
		if err != nil {
			t.Fatalf("old refresh rejected: %v", err)
		}
		if _, err := authenticate(ctx, apiv1connect.UserServiceGetViewerProcedure, http.Header{"Authorization": []string{"Bearer " + refreshed.Msg.AccessToken}}, server.jwtSecret, queries); err != nil {
			t.Fatal(err)
		}
		if _, err := server.RefreshToken(ctx, connect.NewRequest(&v1.RefreshTokenRequest{RefreshToken: oldRefresh})); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("used refresh token still accepted: %v", err)
		}
		var count int
		for _, table := range []string{"user_devices", "price_checks", "llm_runs", "user_sessions", "user_auth_methods"} {
			if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+table+" WHERE user_id=$1", oldUserID).Scan(&count); err != nil || count != 1 {
				t.Fatalf("phone data lost in %s: %d %v", table, count, err)
			}
		}
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM price_check_photos WHERE price_check_id=$1", oldCheckID).Scan(&count); err != nil || count != 1 {
			t.Fatalf("photo metadata lost: %d %v", count, err)
		}
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM verification_sends").Scan(&count); err != nil || count != 1 {
			t.Fatalf("verification ledger lost: %d %v", count, err)
		}
	})
	t.Run("phone login is retired", func(t *testing.T) {
		mux := http.NewServeMux()
		options := connect.WithInterceptors(validate.NewInterceptor(), newAuthInterceptor(server.jwtSecret, queries))
		mux.Handle(apiv1connect.NewAuthServiceHandler(server, options))
		httpServer := httptest.NewServer(mux)
		defer httpServer.Close()
		client := apiv1connect.NewAuthServiceClient(httpServer.Client(), httpServer.URL, connect.WithProtoJSON())
		res, err := client.GetSignInOptions(ctx, connect.NewRequest(&v1.GetSignInOptionsRequest{}))
		if err != nil || len(res.Msg.PhoneCountryCallingCodes) != 0 {
			t.Fatalf("phone options: %v", err)
		}
		for _, number := range []string{"+15005550100", "+15005550101"} {
			_, err := client.StartPhoneVerification(ctx, connect.NewRequest(&v1.StartPhoneVerificationRequest{PhoneNumber: number}))
			if connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatalf("send: %v", err)
			}
			_, err = client.VerifyPhone(ctx, connect.NewRequest(&v1.VerifyPhoneRequest{PhoneNumber: number, Code: "123456", InstallId: "phone-install"}))
			if connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatalf("verify: %v", err)
			}
		}
	})
	t.Run("phone account linking", func(t *testing.T) {
		testPhoneAccountLinking(t, server, users, oldUserID, oldAccess)
	})
	begin := func(t *testing.T, p v1.SignInProvider, install string) string {
		t.Helper()
		r, err := server.BeginSignIn(ctx, connect.NewRequest(&v1.BeginSignInRequest{Provider: p, InstallId: install}))
		if err != nil {
			t.Fatal(err)
		}
		return r.Msg.Nonce
	}
	request := func(p v1.SignInProvider, nonce, install string) *connect.Request[v1.SignInRequest] {
		return connect.NewRequest(&v1.SignInRequest{Provider: p, Nonce: nonce, InstallId: install, IdentityToken: "same-subject", DevicePlatform: v1.DevicePlatform_DEVICE_PLATFORM_IOS})
	}
	google := v1.SignInProvider_SIGN_IN_PROVIDER_GOOGLE
	apple := v1.SignInProvider_SIGN_IN_PROVIDER_APPLE
	nonce := begin(t, google, "install-1")
	first, err := server.SignIn(ctx, request(google, nonce, "install-1"))
	if err != nil {
		t.Fatal(err)
	}
	if !first.Msg.IsNewUser {
		t.Fatal("first login did not create account")
	}
	t.Run("Facebook history is account-wide but current state is per install", func(t *testing.T) {
		users := &userServer{pool: pool, queries: queries, logger: zap.NewNop()}
		login := func(install string) *v1.SignInResponse {
			t.Helper()
			req := request(google, begin(t, google, install), install)
			req.Msg.IdentityToken = "facebook-history"
			response, err := server.SignIn(ctx, req)
			if err != nil {
				t.Fatal(err)
			}
			return response.Msg
		}
		first := login("facebook-install-1")
		userID := uuid.MustParse(first.Viewer.Id)
		userContext := func(token string) context.Context {
			t.Helper()
			result, err := authenticate(ctx, apiv1connect.UserServiceGetViewerProcedure, http.Header{"Authorization": []string{"Bearer " + token}}, server.jwtSecret, queries)
			if err != nil {
				t.Fatal(err)
			}
			return result
		}
		firstCtx := userContext(first.AccessToken)
		report := func(reportCtx context.Context, connected bool) {
			t.Helper()
			response, err := users.SetFacebookConnection(reportCtx, connect.NewRequest(&v1.SetFacebookConnectionRequest{Connected: connected}))
			if err != nil || response.Msg.Device.FacebookConnected != connected {
				t.Fatalf("connection report: %v", err)
			}
		}
		history := func() time.Time {
			t.Helper()
			user, err := queries.GetUser(ctx, userID)
			if err != nil || !user.FacebookLastConnectedAt.Valid {
				t.Fatalf("missing connection history: %+v %v", user, err)
			}
			return user.FacebookLastConnectedAt.Time
		}
		if first.Viewer.FacebookLastConnectedAt != nil || first.Device.FacebookConnected {
			t.Fatal("new account has fabricated connection")
		}
		report(firstCtx, true)
		connectedAt := history()
		report(firstCtx, true)
		if !history().Equal(connectedAt) {
			t.Fatal("duplicate report changed connection date")
		}
		second := login("facebook-install-2")
		if second.Device.FacebookConnected || second.Viewer.FacebookLastConnectedAt == nil {
			t.Fatal("history and current-device state are not independent")
		}
		secondCtx := userContext(second.AccessToken)
		report(secondCtx, false)
		if !history().Equal(connectedAt) {
			t.Fatal("disconnected device erased another install's history")
		}
		report(firstCtx, false)
		if !history().Equal(connectedAt) {
			t.Fatal("disconnect erased connection history")
		}
		report(secondCtx, true)
		if !history().After(connectedAt) {
			t.Fatal("new connection did not advance history")
		}
		latest := history()
		if err := queries.RecordUserFacebookConnection(ctx, db.RecordUserFacebookConnectionParams{ID: userID, ConnectedAt: timestamptz(connectedAt)}); err != nil {
			t.Fatal(err)
		}
		if !history().Equal(latest) {
			t.Fatal("older report moved account history backwards")
		}
		viewer, err := users.GetViewer(firstCtx, connect.NewRequest(&v1.GetViewerRequest{}))
		if err != nil || viewer.Msg.Viewer.FacebookLastConnectedAt == nil || viewer.Msg.Device.FacebookConnected {
			t.Fatalf("viewer mixed account history and device state: %v", err)
		}
		if _, err := users.DeleteAccount(firstCtx, connect.NewRequest(&v1.DeleteAccountRequest{})); err != nil {
			t.Fatal(err)
		}
		var cleared bool
		if err := pool.QueryRow(ctx, "SELECT facebook_last_connected_at IS NULL FROM users WHERE id=$1", userID).Scan(&cleared); err != nil || !cleared {
			t.Fatalf("deleted account retained connection history: %v", err)
		}
	})
	t.Run("single use bound challenge", func(t *testing.T) {
		if _, err := server.SignIn(ctx, request(google, nonce, "install-1")); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("replay: %v", err)
		}
		nonce := begin(t, google, "install-1")
		for _, req := range []*connect.Request[v1.SignInRequest]{request(apple, nonce, "install-1"), request(google, nonce, "install-2")} {
			if _, err := server.SignIn(ctx, req); connect.CodeOf(err) != connect.CodeUnauthenticated {
				t.Fatalf("mismatch: %v", err)
			}
		}
		if _, err := pool.Exec(ctx, "UPDATE sign_in_challenges SET expires_at=CURRENT_TIMESTAMP-interval '1 second' WHERE nonce_hash=$1", identity.HashNonce(nonce)); err != nil {
			t.Fatal(err)
		}
		if _, err := server.SignIn(ctx, request(google, nonce, "install-1")); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("expired: %v", err)
		}
	})
	t.Run("existing account and separate provider", func(t *testing.T) {
		repeat, err := server.SignIn(ctx, request(google, begin(t, google, "install-2"), "install-2"))
		if err != nil {
			t.Fatal(err)
		}
		if repeat.Msg.IsNewUser || repeat.Msg.Viewer.Id != first.Msg.Viewer.Id {
			t.Fatal("existing identity got another account")
		}
		other, err := server.SignIn(ctx, request(apple, begin(t, apple, "install-1"), "install-1"))
		if err != nil {
			t.Fatal(err)
		}
		if !other.Msg.IsNewUser || other.Msg.Viewer.Id == first.Msg.Viewer.Id {
			t.Fatal("providers were incorrectly linked")
		}
		if _, err := authenticate(ctx, apiv1connect.UserServiceGetViewerProcedure, http.Header{"Authorization": []string{"Bearer " + repeat.Msg.AccessToken}}, server.jwtSecret, queries); err != nil {
			t.Fatal(err)
		}
	})
	t.Run("concurrent first login", func(t *testing.T) {
		reqs := []*connect.Request[v1.SignInRequest]{request(google, begin(t, google, "install-a"), "install-a"), request(google, begin(t, google, "install-b"), "install-b")}
		for _, req := range reqs {
			req.Msg.IdentityToken = "concurrent-identity"
		}
		var wg sync.WaitGroup
		results := make(chan *v1.SignInResponse, 2)
		errs := make(chan error, 2)
		for _, req := range reqs {
			wg.Go(func() {
				r, err := server.SignIn(ctx, req)
				if err != nil {
					errs <- err
					return
				}
				results <- r.Msg
			})
		}
		wg.Wait()
		close(results)
		close(errs)
		for err := range errs {
			t.Fatal(err)
		}
		var id string
		newCount := 0
		for r := range results {
			if id != "" && r.Viewer.Id != id {
				t.Fatal("duplicate accounts")
			}
			id = r.Viewer.Id
			if r.IsNewUser {
				newCount++
			}
		}
		if newCount != 1 {
			t.Fatalf("created %d accounts", newCount)
		}
	})
	t.Run("provider emails persist without linking accounts", func(t *testing.T) {
		for _, provider := range []v1.SignInProvider{apple, google} {
			t.Run(provider.String(), func(t *testing.T) {
				login := func(subject, email string) *v1.SignInResponse {
					t.Helper()
					req := request(provider, begin(t, provider, "email-install"), "email-install")
					req.Msg.IdentityToken = subject + "|" + email
					response, err := server.SignIn(ctx, req)
					if err != nil {
						t.Fatal(err)
					}
					return response.Msg
				}
				assertEmail := func(id, expected string) {
					t.Helper()
					user, err := queries.GetUser(ctx, uuid.MustParse(id))
					if err != nil {
						t.Fatal(err)
					}
					if expected == "" {
						if user.Email != nil {
							t.Fatalf("unexpected email: %q", *user.Email)
						}
					} else if user.Email == nil || *user.Email != expected {
						t.Fatalf("email not saved: %+v", user.Email)
					}
				}
				initial := login("email-account", "first@example.com")
				assertEmail(initial.Viewer.Id, "first@example.com")
				returning := login("email-account", "")
				if returning.IsNewUser || returning.Viewer.Id != initial.Viewer.Id {
					t.Fatal("email absence changed identity")
				}
				assertEmail(initial.Viewer.Id, "first@example.com")
				updated := login("email-account", "relay@privaterelay.appleid.com")
				if updated.IsNewUser || updated.Viewer.Id != initial.Viewer.Id {
					t.Fatal("email change created another account")
				}
				assertEmail(initial.Viewer.Id, "relay@privaterelay.appleid.com")
				other := login("another-email-account", "relay@privaterelay.appleid.com")
				if other.Viewer.Id == initial.Viewer.Id {
					t.Fatal("matching emails linked accounts")
				}
				missing := login("email-added-later", "")
				assertEmail(missing.Viewer.Id, "")
				login("email-added-later", "later@example.com")
				assertEmail(missing.Viewer.Id, "later@example.com")
				userID := uuid.MustParse(initial.Viewer.Id)
				if err := queries.SoftDeleteUser(ctx, userID); err != nil {
					t.Fatal(err)
				}
				var cleared bool
				if err := pool.QueryRow(ctx, "SELECT email IS NULL FROM users WHERE id=$1", userID).Scan(&cleared); err != nil || !cleared {
					t.Fatalf("deleted account retained email: %v", err)
				}
			})
		}
	})

	t.Run("provider names persist and profile edits survive later login", func(t *testing.T) {
		for _, provider := range []v1.SignInProvider{apple, google} {
			t.Run(provider.String(), func(t *testing.T) {
				text := func(value string) *string { return &value }
				login := func(firstName, lastName, displayName *string) *v1.SignInResponse {
					t.Helper()
					req := request(provider, begin(t, provider, "names-install"), "names-install")
					req.Msg.IdentityToken = "names-" + provider.String()
					req.Msg.FirstName, req.Msg.LastName, req.Msg.DisplayName = firstName, lastName, displayName
					response, err := server.SignIn(ctx, req)
					if err != nil {
						t.Fatal(err)
					}
					return response.Msg
				}
				initial := login(text("  María José  "), text("García López"), text("María José García López"))
				if !initial.IsNewUser || initial.Viewer.GetFirstName() != "María José" || initial.Viewer.GetLastName() != "García López" || initial.Viewer.GetDisplayName() != "María José García López" {
					t.Fatalf("provider names missing: %v", initial.Viewer)
				}
				stored, err := queries.GetUser(ctx, uuid.MustParse(initial.Viewer.Id))
				if err != nil || stored.FirstName == nil || *stored.FirstName != "María José" || stored.LastName == nil || *stored.LastName != "García López" || stored.DisplayName == nil || *stored.DisplayName != "María José García López" {
					t.Fatalf("database names missing: %+v %v", stored, err)
				}
				returning := login(nil, nil, nil)
				if returning.IsNewUser || returning.Viewer.GetFirstName() != "María José" || returning.Viewer.GetLastName() != "García López" || returning.Viewer.GetDisplayName() != "María José García López" {
					t.Fatal("returning login erased the names")
				}
				userID := uuid.MustParse(initial.Viewer.Id)
				userCtx := auth.WithUserID(ctx, userID)
				users := &userServer{pool: pool, queries: queries, logger: zap.NewNop()}
				updated, err := users.UpdateViewer(userCtx, connect.NewRequest(&v1.UpdateViewerRequest{FirstName: text("MJ"), DisplayName: text("My name")}))
				if err != nil {
					t.Fatal(err)
				}
				if updated.Msg.Viewer.GetFirstName() != "MJ" || updated.Msg.Viewer.GetLastName() != "García López" {
					t.Fatal("partial update erased an omitted name")
				}
				returning = login(text("Provider first"), text("Provider last"), text("Provider display"))
				if returning.Viewer.GetFirstName() != "MJ" || returning.Viewer.GetLastName() != "García López" || returning.Viewer.GetDisplayName() != "My name" {
					t.Fatal("provider overwrote saved profile")
				}
				updated, err = users.UpdateViewer(userCtx, connect.NewRequest(&v1.UpdateViewerRequest{LastName: text("  ")}))
				if err != nil {
					t.Fatal(err)
				}
				if updated.Msg.Viewer.LastName != nil || updated.Msg.Viewer.GetFirstName() != "MJ" {
					t.Fatal("explicit clearing failed")
				}
				returning = login(nil, text("Supplied later"), nil)
				if returning.Viewer.GetLastName() != "Supplied later" || returning.Viewer.GetFirstName() != "MJ" {
					t.Fatal("missing name was not filled")
				}
				_, err = users.UpdateViewer(userCtx, connect.NewRequest(&v1.UpdateViewerRequest{FirstName: text(strings.Repeat("é", 257))}))
				if connect.CodeOf(err) != connect.CodeInvalidArgument {
					t.Fatalf("accepted oversized name: %v", err)
				}
				if err := queries.SoftDeleteUser(ctx, userID); err != nil {
					t.Fatal(err)
				}
				var firstName, lastName, displayName *string
				if err := pool.QueryRow(ctx, "SELECT first_name, last_name, display_name FROM users WHERE id=$1", userID).Scan(&firstName, &lastName, &displayName); err != nil {
					t.Fatal(err)
				}
				if firstName != nil || lastName != nil || displayName != nil {
					t.Fatal("deleted account retained profile names")
				}
			})
		}
	})
	t.Run("missing names do not prevent signup", func(t *testing.T) {
		blank := "  "
		req := request(google, begin(t, google, "nameless-install"), "nameless-install")
		req.Msg.IdentityToken = "nameless"
		req.Msg.FirstName, req.Msg.LastName, req.Msg.DisplayName = &blank, &blank, &blank
		response, err := server.SignIn(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		if !response.Msg.IsNewUser || response.Msg.Viewer.FirstName != nil || response.Msg.Viewer.LastName != nil || response.Msg.Viewer.DisplayName != nil {
			t.Fatal("empty names should be NULL")
		}
	})
	t.Run("deletion revokes sessions", func(t *testing.T) {
		claims, err := auth.ValidateAccessToken(first.Msg.AccessToken, server.jwtSecret)
		if err != nil {
			t.Fatal(err)
		}
		userID := uuid.MustParse(first.Msg.Viewer.Id)
		sessionCtx := auth.WithSessionID(auth.WithUserID(ctx, userID), claims.SessionID)
		users := &userServer{pool: pool, queries: queries, logger: zap.NewNop()}
		if _, err := users.DeleteAccount(sessionCtx, connect.NewRequest(&v1.DeleteAccountRequest{})); err != nil {
			t.Fatal(err)
		}
		if _, err := authenticate(ctx, apiv1connect.UserServiceGetViewerProcedure, http.Header{"Authorization": []string{"Bearer " + first.Msg.AccessToken}}, server.jwtSecret, queries); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("deleted session accepted: %v", err)
		}
		if _, err := server.RefreshToken(ctx, connect.NewRequest(&v1.RefreshTokenRequest{RefreshToken: first.Msg.RefreshToken})); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("deleted refresh accepted: %v", err)
		}
	})
}

func stringPointer(value string) *string { return &value }
