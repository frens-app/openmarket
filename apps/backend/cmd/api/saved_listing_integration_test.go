package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func TestSavedListingIntegration(t *testing.T) {
	databaseURL := os.Getenv("SAVED_LISTING_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set SAVED_LISTING_TEST_DATABASE_URL to a disposable database ending in _saved_listing_test")
	}
	ctx := context.Background()
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(config.ConnConfig.Database, "_saved_listing_test") {
		t.Fatal("database name must end in _saved_listing_test")
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
	if err := goose.Up(sqlDB, "../../deployments/migrations"); err != nil {
		t.Fatal(err)
	}
	q := db.New(pool)
	mux := http.NewServeMux()
	mux.Handle(apiv1connect.NewSavedListingServiceHandler(&savedListingServer{queries: q, pool: pool}, connect.WithInterceptors(validate.NewInterceptor(), newAuthInterceptor("test-secret", q))))
	mux.Handle(apiv1connect.NewListingViewServiceHandler(&listingViewServer{queries: q, pool: pool}, connect.WithInterceptors(validate.NewInterceptor(), newAuthInterceptor("test-secret", q))))
	server := httptest.NewServer(mux)
	defer server.Close()
	client := apiv1connect.NewSavedListingServiceClient(server.Client(), server.URL)
	newAccount := func() (db.User, string) {
		t.Helper()
		user, err := q.CreateUser(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		session, err := q.CreateSession(ctx, db.CreateSessionParams{UserID: user.ID, RefreshTokenHash: user.ID.String(), RefreshTokenExpiresAt: timestamptz(time.Now().Add(time.Hour)), DevicePlatform: db.DevicePlatformIOS})
		if err != nil {
			t.Fatal(err)
		}
		token, err := auth.SignAccessToken(user.ID, session.ID, "test-secret", time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		// No device or Facebook connection exists for this OpenMarket account.
		return user, token
	}
	userA, tokenA := newAccount()
	userB, tokenB := newAccount()
	makeSave := func(id string) *v1.SavedListingChange {
		now := timestamppb.Now()
		return &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: id, Saved: proto.Bool(true), SavedAt: now, Snapshot: &v1.SavedListingSnapshot{FacebookListingId: id, Title: proto.String("Desk"), PriceText: proto.String("$20"), CardObservedAt: now, PriceObservedAt: now}}
	}
	apply := func(token string, changes ...*v1.SavedListingChange) (*v1.ApplySavedListingChangesResponse, error) {
		request := connect.NewRequest(&v1.ApplySavedListingChangesRequest{Changes: changes})
		if token != "" {
			request.Header().Set("Authorization", "Bearer "+token)
		}
		response, err := client.ApplySavedListingChanges(ctx, request)
		if err != nil {
			return nil, err
		}
		return response.Msg, nil
	}
	list := func(token, after string) *v1.ListSavedListingsResponse {
		t.Helper()
		request := connect.NewRequest(&v1.ListSavedListingsRequest{AfterId: after})
		request.Header().Set("Authorization", "Bearer "+token)
		response, err := client.ListSavedListings(ctx, request)
		if err != nil {
			t.Fatal(err)
		}
		return response.Msg
	}
	assertApply := func(token string, changes ...*v1.SavedListingChange) {
		t.Helper()
		response, err := apply(token, changes...)
		if err != nil {
			t.Fatal(err)
		}
		for _, result := range response.Results {
			if result.Error != "" {
				t.Fatal(result.Error)
			}
		}
	}
	first := makeSave("123456789")
	if _, err := apply("", first); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("anonymous save", err)
	}
	assertApply(tokenA, first)
	assertApply(tokenA, first)
	assertApply(tokenB, makeSave(first.FacebookListingId))
	if len(list(tokenA, "").Listings) != 1 || len(list(tokenB, "").Listings) != 1 {
		t.Fatal("save count")
	}
	a, b := list(tokenA, "").Listings[0], list(tokenB, "").Listings[0]
	if a.ListingId != b.ListingId || a.Snapshot.GetTitle() != "Desk" {
		t.Fatal("shared metadata not restored")
	}
	remove := &v1.SavedListingChange{MutationId: uuid.NewString(), FacebookListingId: first.FacebookListingId, Saved: proto.Bool(false)}
	assertApply(tokenA, remove)
	// An acknowledged-but-lost response cannot replay a save after a removal.
	assertApply(tokenA, first)
	refresh := makeSave(first.FacebookListingId)
	refresh.Saved = nil
	refresh.SavedAt = nil
	assertApply(tokenA, refresh)
	if len(list(tokenA, "").Listings) != 0 || len(list(tokenB, "").Listings) != 1 {
		t.Fatal("retry or metadata refresh resurrected a save")
	}
	changed := proto.Clone(first).(*v1.SavedListingChange)
	changed.Snapshot.Title = proto.String("Changed")
	response, err := apply(tokenA, changed)
	if err != nil || response.Results[0].Error == "" {
		t.Fatal("reused mutation accepted", err)
	}
	// Entry-level validation does not reject valid peers in the same batch.
	invalid := makeSave("222")
	invalid.Snapshot.ThumbnailUrl = proto.String("file:///tmp/image")
	invalidID := makeSave("p:photo")
	response, err = apply(tokenA, invalid, invalidID, makeSave("333"))
	if err != nil || response.Results[0].Error == "" || response.Results[1].Error == "" || response.Results[2].Error != "" {
		t.Fatal("partial validation", response, err)
	}
	// Exercise all pages and preserve each original saved_at on repeated saves.
	original := list(tokenA, "").Listings[0].SavedAt
	assertApply(tokenA, makeSave("333"))
	if !list(tokenA, "").Listings[0].SavedAt.AsTime().Equal(original.AsTime()) {
		t.Fatal("save moved on retry")
	}
	for i := 0; i < 100; i++ {
		assertApply(tokenA, makeSave(fmt.Sprintf("8%03d", i)))
	}
	page := list(tokenA, "")
	last := list(tokenA, page.NextAfterId)
	if len(page.Listings) != 100 || len(last.Listings) != 1 || last.NextAfterId != "" {
		t.Fatal("pagination")
	}

	viewClient := apiv1connect.NewListingViewServiceClient(server.Client(), server.URL)
	viewAt := time.Now().Add(-time.Minute).Truncate(time.Microsecond)
	submitView := func(token string, at time.Time, snapshot *v1.SavedListingSnapshot) {
		t.Helper()
		r := &v1.SubmitListingViewRequest{FacebookListingId: first.FacebookListingId, ViewedAt: timestamppb.New(at), Snapshot: snapshot}
		if snapshot != nil {
			r.Source = v1.ListingViewSource_LISTING_VIEW_SOURCE_ANONYMOUS_GRAPHQL
		}
		request := connect.NewRequest(r)
		if token != "" {
			request.Header().Set("Authorization", "Bearer "+token)
		}
		if _, err := viewClient.SubmitListingView(ctx, request); err != nil {
			t.Fatal(err)
		}
	}

	guestRequest := connect.NewRequest(&v1.SubmitListingViewRequest{FacebookListingId: "777777777", ViewedAt: timestamppb.New(viewAt)})
	if _, err := viewClient.SubmitListingView(ctx, guestRequest); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("anonymous view accepted", err)
	}
	var guestRows int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM listings WHERE facebook_listing_id = '777777777'").Scan(&guestRows); err != nil || guestRows != 0 {
		t.Fatal("anonymous request created a listing", err)
	}
	submitView(tokenB, viewAt.Add(time.Second), nil)
	detailAt := time.Now().Truncate(time.Microsecond)
	submitView(tokenB, viewAt.Add(time.Second), &v1.SavedListingSnapshot{FacebookListingId: first.FacebookListingId, Description: proto.String("Fresh detail"), DetailObservedAt: timestamppb.New(detailAt)})
	previous, err := q.LockListing(ctx, first.FacebookListingId)
	if err != nil {
		t.Fatal(err)
	}
	// The next account's clock is behind: receipt order still decides attribution.
	submitView(tokenA, viewAt, &v1.SavedListingSnapshot{FacebookListingId: first.FacebookListingId, Description: proto.String("Cached detail"), DetailObservedAt: timestamppb.New(detailAt.Add(-time.Hour))})
	row, err := q.LockListing(ctx, first.FacebookListingId)
	if err != nil {
		t.Fatal(err)
	}
	if row.LastViewedBy == nil || *row.LastViewedBy != userA.ID || !row.LastViewedAt.Time.Equal(viewAt) || !row.LastViewReceivedAt.Time.After(previous.LastViewReceivedAt.Time) {
		t.Fatal("view attribution did not follow server receipt time", row)
	}
	if row.LastDetailUpdatedBy == nil || *row.LastDetailUpdatedBy != userA.ID || !row.LastDetailReceivedAt.Time.After(previous.LastDetailReceivedAt.Time) || !row.LastDetailObservedAt.Time.Equal(detailAt.Add(-time.Hour)) {
		t.Fatal("data attribution did not follow server receipt time", row)
	}
	if row.LastDetailSource == nil || *row.LastDetailSource != "LISTING_VIEW_SOURCE_ANONYMOUS_GRAPHQL" {
		t.Fatal("lost provenance")
	}
	restored := &v1.SavedListingSnapshot{}
	if err := protojson.Unmarshal(row.Snapshot, restored); err != nil || restored.GetDescription() != "Fresh detail" {
		t.Fatal("cached snapshot replaced fresh detail", err)
	}
	// A click without a payload changes only the viewer, not the data submitter.
	submitView(tokenB, viewAt.Add(-time.Hour), nil)
	clicked, err := q.LockListing(ctx, first.FacebookListingId)
	if err != nil || clicked.LastViewedBy == nil || *clicked.LastViewedBy != userB.ID || clicked.LastDetailUpdatedBy == nil || *clicked.LastDetailUpdatedBy != userA.ID || !clicked.LastDetailReceivedAt.Time.Equal(row.LastDetailReceivedAt.Time) {
		t.Fatal("click changed data attribution", err)
	}
	if len(list(tokenB, "").Listings) != 1 {
		t.Fatal("view changed bookmarks")
	}
	if _, err := q.CreateAuthMethod(ctx, db.CreateAuthMethodParams{UserID: userA.ID, AuthService: db.AuthServiceGOOGLE, Subject: userA.ID.String()}); err != nil {
		t.Fatal(err)
	}
	users := &userServer{queries: q, pool: pool, logger: zap.NewNop()}
	if _, err := users.DeleteAccount(auth.WithUserID(ctx, userA.ID), connect.NewRequest(&v1.DeleteAccountRequest{})); err != nil {
		t.Fatal(err)
	}
	row, err = q.LockListing(ctx, first.FacebookListingId)
	if err != nil || row.LastDetailUpdatedBy != nil || row.LastViewedBy == nil || *row.LastViewedBy != userB.ID {
		t.Fatal("deletion failed to clear observer or cleared another viewer", err)
	}
	for _, table := range []string{"saved_listings", "saved_listing_mutations"} {
		var count int
		if err := pool.QueryRow(ctx, "SELECT count(*) FROM "+table+" WHERE user_id=$1", userA.ID).Scan(&count); err != nil || count != 0 {
			t.Fatal("account data survived deletion", table, count, err)
		}
	}
	if len(list(tokenB, "").Listings) != 1 {
		t.Fatal("deleted another account's saves")
	}
	if _, err := apply(tokenA, makeSave("999")); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatal("deleted account can write", err)
	}
	t.Run("regional prices round trip through PostgreSQL", func(t *testing.T) {
		for i, sample := range []struct{ code, amount, formatted string }{
			{"CAD", "1234.56", "CA$1,234.56"}, {"EUR", "1234.56", "1.234,56 €"},
			{"INR", "123456.78", "₹1,23,456.78"}, {"IDR", "550000000", "IDR550M"},
			{"VND", "9007199254740993", "VND9,007,199,254,740,993"}, {"COP", "0", "Free"},
		} {
			change := makeSave(fmt.Sprintf("88880000%d", i))
			change.Snapshot.PriceText = proto.String(sample.formatted)
			change.Snapshot.PriceAmountDecimal = proto.String(sample.amount)
			change.Snapshot.PriceCurrencyCode = proto.String(sample.code)
			change.Snapshot.OriginalPriceText = proto.String(sample.formatted)
			change.Snapshot.OriginalPriceAmountDecimal = proto.String(sample.amount)
			assertApply(tokenB, change)
			row, err := q.LockListing(ctx, change.FacebookListingId)
			if err != nil {
				t.Fatal(err)
			}
			var amount, code string
			if err := pool.QueryRow(ctx, "SELECT snapshot->>'priceAmountDecimal', snapshot->>'priceCurrencyCode' FROM listings WHERE id=$1", row.ID).Scan(&amount, &code); err != nil {
				t.Fatal(err)
			}
			if amount != sample.amount || code != sample.code {
				t.Fatalf("database changed price: %s %s", code, amount)
			}
			found := false
			for _, saved := range list(tokenB, "").Listings {
				if saved.Snapshot.FacebookListingId != change.FacebookListingId {
					continue
				}
				found = true
				if saved.Snapshot.GetPriceAmountDecimal() != sample.amount || saved.Snapshot.GetPriceCurrencyCode() != sample.code || saved.Snapshot.GetPriceText() != sample.formatted || saved.Snapshot.GetOriginalPriceAmountDecimal() != sample.amount {
					t.Fatal(saved)
				}
			}
			if !found {
				t.Fatal("saved price missing from API response")
			}
		}
	})

}
