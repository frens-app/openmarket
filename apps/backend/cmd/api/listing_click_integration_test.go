package main

import (
	"context"
	"testing"
	"time"

	"connectrpc.com/connect"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// Uses the disposable database and authenticated HTTP server in TestSavedListingIntegration.
func verifyUserListingClicks(t *testing.T, ctx context.Context, pool *pgxpool.Pool, client apiv1connect.ListingViewServiceClient, userA, userB uuid.UUID, tokenA, tokenB string) {
	t.Helper()
	at := time.Now().Add(-time.Hour).Truncate(time.Microsecond)
	click := func(at time.Time, from string) *v1.SubmitListingViewRequest {
		return &v1.SubmitListingViewRequest{
			FacebookListingId: "880000001", ViewedAt: timestamppb.New(at),
			Referrer: proto.String(from),
		}
	}
	submit := func(token string, r *v1.SubmitListingViewRequest) error {
		req := connect.NewRequest(r)
		req.Header().Set("Authorization", "Bearer "+token)
		_, err := client.SubmitListingView(ctx, req)
		return err
	}
	mustSubmit := func(token string, r *v1.SubmitListingViewRequest) {
		t.Helper()
		if err := submit(token, r); err != nil {
			t.Fatal(err)
		}
	}
	check := func(user uuid.UUID, count int64, firstAt, lastAt time.Time, firstFrom, lastFrom string) {
		t.Helper()
		var gotCount int64
		var gotFirst, gotLast time.Time
		var gotFirstFrom, gotLastFrom string
		err := pool.QueryRow(ctx, `SELECT click_count, first_clicked_at, last_clicked_at,
			first_clicked_from, last_clicked_from FROM user_listing_clicks c
			JOIN listings l ON l.id=c.listing_id WHERE user_id=$1 AND facebook_listing_id='880000001'`, user).
			Scan(&gotCount, &gotFirst, &gotLast, &gotFirstFrom, &gotLastFrom)
		if err != nil || gotCount != count || !gotFirst.Equal(firstAt) || !gotLast.Equal(lastAt) || gotFirstFrom != firstFrom || gotLastFrom != lastFrom {
			t.Fatalf("summary: count=%d first=%v/%s last=%v/%s err=%v", gotCount, gotFirst, gotFirstFrom, gotLast, gotLastFrom, err)
		}
	}

	// One successful fetch submits both the click and the fresh snapshot.
	initial := click(at, "search")
	initial.Source = v1.ListingViewSource_LISTING_VIEW_SOURCE_ANONYMOUS_GRAPHQL
	initial.Snapshot = &v1.SavedListingSnapshot{
		FacebookListingId: initial.FacebookListingId, Description: proto.String("Fresh detail"),
		Sold: proto.Bool(true), DetailObservedAt: timestamppb.Now(), AvailabilityObservedAt: timestamppb.Now(),
	}
	mustSubmit(tokenA, initial)
	check(userA, 1, at, at, "search", "search")
	var description string
	if err := pool.QueryRow(ctx, `SELECT snapshot->>'description' FROM listings WHERE facebook_listing_id='880000001'`).Scan(&description); err != nil || description != "Fresh detail" {
		t.Fatal("lost fetched details", description, err)
	}
	// Failed fetches still report the click without a snapshot.
	mustSubmit(tokenA, click(at.Add(time.Minute), "saved"))
	mustSubmit(tokenA, click(at.Add(-time.Minute), "discover")) // Arrives out of order.
	check(userA, 3, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")

	mustSubmit(tokenB, click(at, "search"))
	check(userB, 1, at, at, "search", "search")
	otherListing := click(at, "search")
	otherListing.FacebookListingId = "880000002"
	mustSubmit(tokenA, otherListing)
	check(userA, 3, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")

	// Older clients send both uploads without a referrer. Do not invent
	// counts from those requests or from the pre-migration last-view columns.
	legacy := proto.Clone(initial).(*v1.SubmitListingViewRequest)
	legacy.Referrer = nil
	mustSubmit(tokenA, legacy)
	check(userA, 3, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")

	// Concurrent opens with identical timestamps all count without overwriting
	// the earliest/latest attribution.
	results := make(chan error, 8)
	for i := 0; i < 8; i++ {
		r := click(at, "listing_alerts")
		go func() { results <- submit(tokenA, r) }()
	}
	for i := 0; i < 8; i++ {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	check(userA, 11, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")

	// A failure saving the details must also roll back the counter.
	rejected := click(at, "search")
	rejected.Source = initial.Source
	rejected.Snapshot = &v1.SavedListingSnapshot{
		FacebookListingId: initial.FacebookListingId, Pending: proto.Bool(true),
		DetailObservedAt: timestamppb.Now(), AvailabilityObservedAt: timestamppb.Now(),
	}
	if err := submit(tokenA, rejected); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatal("expected merged sold/pending conflict", err)
	}
	check(userA, 11, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")
	rejected.Source = v1.ListingViewSource_LISTING_VIEW_SOURCE_UNSPECIFIED
	rejected.Snapshot = nil
	mustSubmit(tokenA, rejected)
	check(userA, 12, at.Add(-time.Minute), at.Add(time.Minute), "discover", "saved")
}
