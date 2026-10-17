package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
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
)

// Invoked after TestSocialAuthIntegration installs the phone-only schema,
// seeds a phone account and its history, then applies the additive migrations.
func testPhoneAccountLinking(t *testing.T, server *authServer, users *userServer, oldUserID uuid.UUID, oldAccess string) {
	ctx := context.Background()
	pool, queries := server.pool, server.queries
	mux := http.NewServeMux()
	options := connect.WithInterceptors(validate.NewInterceptor(), newAuthInterceptor(server.jwtSecret, queries))
	mux.Handle(apiv1connect.NewAuthServiceHandler(server, options))
	mux.Handle(apiv1connect.NewUserServiceHandler(users, options))
	httpServer := httptest.NewServer(mux)
	defer httpServer.Close()
	client := apiv1connect.NewAuthServiceClient(httpServer.Client(), httpServer.URL, connect.WithProtoJSON())
	userClient := apiv1connect.NewUserServiceClient(httpServer.Client(), httpServer.URL, connect.WithProtoJSON())
	google, apple := v1.SignInProvider_SIGN_IN_PROVIDER_GOOGLE, v1.SignInProvider_SIGN_IN_PROVIDER_APPLE
	begin := func(t *testing.T, access string, provider v1.SignInProvider) string {
		t.Helper()
		req := connect.NewRequest(&v1.BeginLinkSignInRequest{Provider: provider})
		req.Header().Set("Authorization", "Bearer "+access)
		res, err := client.BeginLinkSignIn(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		return res.Msg.Nonce
	}
	link := func(access string, provider v1.SignInProvider, nonce, subject string) (*connect.Response[v1.LinkSignInResponse], error) {
		req := connect.NewRequest(&v1.LinkSignInRequest{
			Provider: provider, Nonce: nonce, IdentityToken: subject,
			FirstName: stringPointer("Alex"), LastName: stringPointer("Rivera"), DisplayName: stringPointer("Alex R."),
		})
		req.Header().Set("Authorization", "Bearer "+access)
		return client.LinkSignIn(ctx, req)
	}
	signIn := func(provider v1.SignInProvider, nonce, subject string) (*connect.Response[v1.SignInResponse], error) {
		return client.SignIn(ctx, connect.NewRequest(&v1.SignInRequest{Provider: provider, Nonce: nonce, IdentityToken: subject, InstallId: "phone-install", DevicePlatform: v1.DevicePlatform_DEVICE_PLATFORM_IOS}))
	}
	beginSignIn := func(t *testing.T, provider v1.SignInProvider) string {
		t.Helper()
		res, err := client.BeginSignIn(ctx, connect.NewRequest(&v1.BeginSignInRequest{Provider: provider, InstallId: "phone-install"}))
		if err != nil {
			t.Fatal(err)
		}
		return res.Msg.Nonce
	}
	viewer := func(t *testing.T, access string) *v1.Viewer {
		t.Helper()
		req := connect.NewRequest(&v1.GetViewerRequest{})
		req.Header().Set("Authorization", "Bearer "+access)
		res, err := userClient.GetViewer(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		return res.Msg.Viewer
	}
	assertRetainedPhone := func(t *testing.T, userID uuid.UUID, subject string) {
		t.Helper()
		method, err := queries.GetAuthMethod(ctx, db.GetAuthMethodParams{AuthService: db.AuthServicePHONE, Subject: subject})
		if err != nil || method.UserID != userID {
			t.Fatalf("phone identity not retained on original account: %v", err)
		}
		var methods int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM user_auth_methods WHERE user_id=$1", userID).Scan(&methods); err != nil || methods != 2 {
			t.Fatalf("expected phone plus one social identity: %d %v", methods, err)
		}
	}
	newPhone := func(t *testing.T) (uuid.UUID, string, string) {
		t.Helper()
		user, err := queries.CreateUser(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = queries.CreateAuthMethod(ctx, db.CreateAuthMethodParams{UserID: user.ID, AuthService: db.AuthServicePHONE, Subject: "fixture-phone-" + user.ID.String()}); err != nil {
			t.Fatal(err)
		}
		device, err := queries.UpsertDevice(ctx, db.UpsertDeviceParams{UserID: user.ID, InstallID: "link-" + user.ID.String(), Platform: db.DevicePlatformIOS})
		if err != nil {
			t.Fatal(err)
		}
		refresh, hash, err := auth.GenerateRefreshToken(server.refreshTokenHMACKey)
		if err != nil {
			t.Fatal(err)
		}
		session, err := queries.CreateSession(ctx, db.CreateSessionParams{UserID: user.ID, RefreshTokenHash: hash, RefreshTokenExpiresAt: timestamptz(time.Now().Add(time.Hour)), DevicePlatform: db.DevicePlatformIOS})
		if err != nil {
			t.Fatal(err)
		}
		if err := queries.SetSessionDevice(ctx, db.SetSessionDeviceParams{ID: session.ID, DeviceID: &device.ID}); err != nil {
			t.Fatal(err)
		}
		access, err := auth.SignAccessToken(user.ID, session.ID, server.jwtSecret, time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		return user.ID, access, refresh
	}
	t.Run("challenges require the same authenticated session and purpose", func(t *testing.T) {
		_, err := client.BeginLinkSignIn(ctx, connect.NewRequest(&v1.BeginLinkSignInRequest{Provider: google}))
		if connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("anonymous begin: %v", err)
		}
		nonce := begin(t, oldAccess, google)
		if _, err := link("", google, nonce, "linked-google"); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("anonymous link: %v", err)
		}
		_, otherAccess, _ := newPhone(t)
		if _, err := link(otherAccess, google, nonce, "linked-google"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("cross-session challenge: %v", err)
		}
		if _, err := link(oldAccess, apple, nonce, "linked-google"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("cross-provider challenge: %v", err)
		}
		if _, err := signIn(google, nonce, "linked-google"); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("link challenge accepted for sign-in: %v", err)
		}
		if _, err := link(oldAccess, google, beginSignIn(t, google), "linked-google"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("sign-in challenge accepted for linking: %v", err)
		}
		if _, err := link(oldAccess, google, nonce, "invalid"); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("invalid token accepted: %v", err)
		}
		expired := begin(t, oldAccess, google)
		if _, err := pool.Exec(ctx, "UPDATE sign_in_challenges SET expires_at=now()-interval '1 minute' WHERE nonce_hash=$1", identity.HashNonce(expired)); err != nil {
			t.Fatal(err)
		}
		if _, err := link(oldAccess, google, expired, "linked-google"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("expired challenge: %v", err)
		}
		if viewer(t, oldAccess).SignInProvider != "phone" {
			t.Fatal("failed linking changed phone account")
		}
	})
	t.Run("Google linking preserves user ID history sessions and device", func(t *testing.T) {
		var listingID uuid.UUID
		if err := pool.QueryRow(ctx, "INSERT INTO listings (facebook_listing_id,last_viewed_by,last_viewed_at) VALUES ('987654321',$1,now()) RETURNING id", oldUserID).Scan(&listingID); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "INSERT INTO saved_listings (user_id,listing_id,saved_at) VALUES ($1,$2,now())", oldUserID, listingID); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "INSERT INTO facebook_sellers (id,name) VALUES ('987654321','Linked seller')"); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, "INSERT INTO seller_follows (user_id,seller_id) VALUES ($1,'987654321')", oldUserID); err != nil {
			t.Fatal(err)
		}
		nonce := begin(t, oldAccess, google)
		res, err := link(oldAccess, google, nonce, "linked-google|linked@example.com")
		if err != nil {
			t.Fatal(err)
		}
		if res.Msg.Viewer.Id != oldUserID.String() || res.Msg.Viewer.SignInProvider != "google" || res.Msg.Viewer.PhoneNumber != "" || !res.Msg.Viewer.OnboardingCompleted {
			t.Fatalf("wrong linked viewer: %v", res.Msg.Viewer)
		}
		if v := res.Msg.Viewer; v.GetFirstName() != "Alex" || v.GetLastName() != "Rivera" || v.GetDisplayName() != "Phone user" {
			t.Fatalf("link must fill separate names and preserve the saved display name: %v", v)
		}
		if _, err := link(oldAccess, google, nonce, "linked-google"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("nonce replay: %v", err)
		}
		if _, err := link(oldAccess, google, begin(t, oldAccess, google), "linked-google"); err != nil {
			t.Fatalf("retry same identity: %v", err)
		}
		if _, err := link(oldAccess, apple, begin(t, oldAccess, apple), "new-apple"); connect.CodeOf(err) != connect.CodeFailedPrecondition {
			t.Fatalf("second provider replacement allowed: %v", err)
		}
		for _, table := range []string{"saved_listings", "seller_follows", "price_checks", "user_devices", "user_sessions", "llm_runs"} {
			var count int
			if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+table+" WHERE user_id=$1", oldUserID).Scan(&count); err != nil || count != 1 {
				t.Fatalf("history/session changed in %s: %d %v", table, count, err)
			}
		}
		assertRetainedPhone(t, oldUserID, "+15005550100")
		var viewOwner uuid.UUID
		if err := pool.QueryRow(ctx, "SELECT last_viewed_by FROM listings WHERE id=$1", listingID).Scan(&viewOwner); err != nil || viewOwner != oldUserID {
			t.Fatalf("view history changed: %v", err)
		}
		user, err := queries.GetUser(ctx, oldUserID)
		if err != nil || user.Email == nil || *user.Email != "linked@example.com" || user.DisplayName == nil || *user.DisplayName != "Phone user" {
			t.Fatalf("profile lost: %+v %v", user, err)
		}
		if v := viewer(t, oldAccess); v.SignInProvider != "google" || v.GetFirstName() != "Alex" || v.GetLastName() != "Rivera" || v.GetDisplayName() != "Phone user" {
			t.Fatalf("original session did not retain provider and profile: %v", v)
		}
		login, err := signIn(google, beginSignIn(t, google), "linked-google")
		if err != nil || login.Msg.IsNewUser || login.Msg.Viewer.Id != oldUserID.String() || !login.Msg.Device.FacebookConnected {
			t.Fatalf("later provider login lost original account/device: %v", err)
		}
	})
	t.Run("provider conflict leaves both accounts unchanged", func(t *testing.T) {
		id, access, _ := newPhone(t)
		if _, err := link(access, google, begin(t, access, google), "linked-google"); connect.CodeOf(err) != connect.CodeAlreadyExists {
			t.Fatalf("existing identity not rejected: %v", err)
		}
		if v := viewer(t, access); v.Id != id.String() || v.SignInProvider != "phone" {
			t.Fatal("conflict changed phone account")
		}
		if v := viewer(t, oldAccess); v.Id != oldUserID.String() || v.SignInProvider != "google" {
			t.Fatal("conflict changed owner")
		}
	})
	t.Run("Apple linking retains refresh token and requires Apple for deletion", func(t *testing.T) {
		id, access, refresh := newPhone(t)
		res, err := link(access, apple, begin(t, access, apple), "linked-apple")
		if err != nil || res.Msg.Viewer.Id != id.String() || res.Msg.Viewer.SignInProvider != "apple" {
			t.Fatalf("Apple linking: %v", err)
		}
		if v := res.Msg.Viewer; v.GetFirstName() != "Alex" || v.GetLastName() != "Rivera" || v.GetDisplayName() != "Alex R." {
			t.Fatalf("Apple link did not return separate names: %v", v)
		}
		assertRetainedPhone(t, id, "fixture-phone-"+id.String())
		refreshed, err := client.RefreshToken(ctx, connect.NewRequest(&v1.RefreshTokenRequest{RefreshToken: refresh}))
		if err != nil || viewer(t, refreshed.Msg.AccessToken).Id != id.String() {
			t.Fatalf("refresh changed account: %v", err)
		}
		if v := viewer(t, refreshed.Msg.AccessToken); v.SignInProvider != "apple" || v.GetFirstName() != "Alex" || v.GetLastName() != "Rivera" || v.GetDisplayName() != "Alex R." {
			t.Fatalf("Apple link did not persist provider and separate names: %v", v)
		}
		login, err := signIn(apple, beginSignIn(t, apple), "linked-apple")
		if err != nil || login.Msg.IsNewUser || login.Msg.Viewer.Id != id.String() {
			t.Fatalf("Apple login changed account: %v", err)
		}
		users.identities = testIdentityVerifier{}
		req := connect.NewRequest(&v1.DeleteAccountRequest{AppleIdentityToken: "invalid"})
		req.Header().Set("Authorization", "Bearer "+access)
		if _, err := userClient.DeleteAccount(ctx, req); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("Apple revocation bypassed: %v", err)
		}
		if viewer(t, access).Id != id.String() {
			t.Fatal("failed deletion removed account")
		}
	})
	t.Run("competing requests attach one social identity and retain phone", func(t *testing.T) {
		id, access, _ := newPhone(t)
		nonces := []string{begin(t, access, google), begin(t, access, apple)}
		providers := []v1.SignInProvider{google, apple}
		errs := make([]error, 2)
		var wg sync.WaitGroup
		for i := range providers {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				_, errs[i] = link(access, providers[i], nonces[i], fmt.Sprintf("race-%d", i))
			}(i)
		}
		wg.Wait()
		successes := 0
		for _, err := range errs {
			if err == nil {
				successes++
			} else if connect.CodeOf(err) != connect.CodeFailedPrecondition {
				t.Fatal(err)
			}
		}
		assertRetainedPhone(t, id, "fixture-phone-"+id.String())
		if successes != 1 {
			t.Fatalf("expected one social link to succeed: %d", successes)
		}
	})
	t.Run("logout rejects a pending link", func(t *testing.T) {
		_, access, _ := newPhone(t)
		nonce := begin(t, access, google)
		req := connect.NewRequest(&v1.LogoutRequest{})
		req.Header().Set("Authorization", "Bearer "+access)
		if _, err := client.Logout(ctx, req); err != nil {
			t.Fatal(err)
		}
		if _, err := link(access, google, nonce, "logged-out"); connect.CodeOf(err) != connect.CodeUnauthenticated {
			t.Fatalf("revoked session linked: %v", err)
		}
	})
}
