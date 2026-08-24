package ingest

import (
	"context"
	"os"
	"testing"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"google.golang.org/protobuf/types/known/timestamppb"
)

// The merge rules are unit-tested above; this exercises the parts that only
// exist in Postgres — the partial unique indexes that make two aliases one
// listing, the transaction, and the counters.
//
// Skipped without a database rather than started against one: `make ci` runs on
// a checkout with no Postgres, and a test that boots a container is a different
// thing from a test.
func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	url := os.Getenv("TEST_DATABASE_URL")
	if url == "" {
		t.Skip("set TEST_DATABASE_URL to run ingest integration tests")
	}
	pool, err := pgxpool.New(context.Background(), url)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func testDevice(t *testing.T, pool *pgxpool.Pool) uuid.UUID {
	t.Helper()
	ctx := context.Background()
	var userID, deviceID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO users DEFAULT VALUES RETURNING id`).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	err := pool.QueryRow(ctx,
		`INSERT INTO user_devices (user_id, install_id, platform) VALUES ($1, $2, 'IOS') RETURNING id`,
		userID, uuid.NewString(),
	).Scan(&deviceID)
	if err != nil {
		t.Fatal(err)
	}
	return deviceID
}

func testService(t *testing.T, pool *pgxpool.Pool) *Service {
	t.Helper()
	queries := db.New(pool)
	return NewService(
		pool, queries,
		NewKeyring(queries, week, 2*week),
		[]byte("test-seller-key"),
		Breaker{Rate: 0.4, MinCards: 200},
		Limits{
			MaxObservationAge:   48 * time.Hour,
			MaxClockSkew:        5 * time.Minute,
			CorroborationWindow: week,
			BreakerWindow:       6 * time.Hour,
			ShapeWindow:         2 * week,
		},
		zap.NewNop(),
	)
}

func TestSubmitMergesTwoAliasesIntoOneListing(t *testing.T) {
	pool := testPool(t)
	svc := testService(t, pool)
	device := testDevice(t, pool)
	ctx := context.Background()

	now := time.Now().UTC()
	svc.now = func() time.Time { return now }

	// Both aliases are numeric on the wire, and eight digits at minimum.
	listingID, photoID := "12345678901", "98765432109"

	// A mobile card knows only the cover photo fbid.
	mobile := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:   v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_MOBILE,
			PageRoute:        v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
			ExtractionMethod: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_RENDERED_DOM,
			ObservedAt:       timestamppb.New(now.Add(-time.Hour)),
		},
		ExtractorRevision: "test-1",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 3, DropReasons: []string{"price_unparseable"}},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Search{
				Search: &v1.FacebookMarketplaceSearchListingObservation{
					Key:   &v1.FacebookListingKey{CoverPhotoFbid: &photoID},
					Title: ptr("Oak dresser"),
				},
			}},
		},
	}
	resp, err := svc.Submit(ctx, Submission{DeviceID: device, Request: mobile})
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetAccepted() != 1 {
		t.Fatalf("accepted = %d, rejections %+v", resp.GetAccepted(), resp.GetRejections())
	}

	// A desktop card carries both, and must attach rather than create a second.
	desktop := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:   v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:        v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
			ExtractionMethod: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL,
			ObservedAt:       timestamppb.New(now),
		},
		ExtractorRevision: "test-1",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 1},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Search{
				Search: &v1.FacebookMarketplaceSearchListingObservation{
					Key: &v1.FacebookListingKey{
						FacebookListingId: &listingID,
						CoverPhotoFbid:    &photoID,
					},
					Title:        ptr("Solid oak six-drawer dresser"),
					Price:        price("40.00", "USD"),
					ListedAt:     timestamppb.New(now.Add(-72 * time.Hour)),
					Availability: &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(false), Pending: ptr(false)},
				},
			}},
		},
	}
	if _, err := svc.Submit(ctx, Submission{DeviceID: device, Request: desktop}); err != nil {
		t.Fatal(err)
	}

	var (
		count      int
		title      string
		priceMinor int64
		notBefore  time.Time
	)
	err = pool.QueryRow(ctx,
		`SELECT count(*) FROM listings WHERE cover_photo_fbid = $1 OR facebook_listing_id = $2`,
		photoID, listingID,
	).Scan(&count)
	if err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("listings = %d, want the two aliases to be one row", count)
	}

	err = pool.QueryRow(ctx,
		`SELECT title, price_minor, sold_not_before FROM listings WHERE facebook_listing_id = $1`,
		listingID,
	).Scan(&title, &priceMinor, &notBefore)
	if err != nil {
		t.Fatal(err)
	}
	if title != "Solid oak six-drawer dresser" || priceMinor != 4000 {
		t.Fatalf("title=%q price=%d", title, priceMinor)
	}
	if !notBefore.UTC().Truncate(time.Second).Equal(now.Truncate(time.Second)) {
		t.Fatalf("sold_not_before = %v, want the latest not-sold sighting", notBefore)
	}

	// The client's own drop is legible from here, which is the only reason the
	// counts are on the batch at all.
	var seen, submitted int32
	var reasons []string
	err = pool.QueryRow(ctx,
		`SELECT cards_seen, cards_submitted, client_drop_reasons FROM observation_batches
		 WHERE facebook_browser_variant = 'FACEBOOK_MARKETPLACE_BROWSER_VARIANT_MOBILE'
		 ORDER BY received_at DESC LIMIT 1`,
	).Scan(&seen, &submitted, &reasons)
	if err != nil {
		t.Fatal(err)
	}
	if seen != 3 || submitted != 1 || len(reasons) != 1 {
		t.Fatalf("counts: seen=%d submitted=%d reasons=%v", seen, submitted, reasons)
	}
}

// The device never reaches a batch row; a per-epoch pseudonym does.
func TestSubmitStoresAPseudonymAndNotTheDevice(t *testing.T) {
	pool := testPool(t)
	svc := testService(t, pool)
	device := testDevice(t, pool)
	ctx := context.Background()

	now := time.Now().UTC()
	svc.now = func() time.Time { return now }

	id := "22222222222"
	req := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:   v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:        v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
			ExtractionMethod: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL,
			ObservedAt:       timestamppb.New(now),
		},
		ExtractorRevision: "test-1",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 1},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Search{
				Search: &v1.FacebookMarketplaceSearchListingObservation{
					Key: &v1.FacebookListingKey{FacebookListingId: &id},
				},
			}},
		},
	}
	resp, err := svc.Submit(ctx, Submission{DeviceID: device, Request: req})
	if err != nil {
		t.Fatal(err)
	}

	var submitter []byte
	if err := pool.QueryRow(ctx, `SELECT submitter_id FROM observation_batches WHERE id = $1`, resp.GetBatchId()).Scan(&submitter); err != nil {
		t.Fatal(err)
	}
	if len(submitter) != submitterIDLen {
		t.Fatalf("submitter_id length = %d", len(submitter))
	}
	raw := device
	if string(submitter) == string(raw[:]) {
		t.Fatal("the device id itself must never be the stored value")
	}

	// Volume is counted against the real install, and holds no listing ids.
	var cards int32
	if err := pool.QueryRow(ctx,
		`SELECT cards FROM device_activity WHERE device_id = $1 AND day = CURRENT_DATE`, device,
	).Scan(&cards); err != nil {
		t.Fatal(err)
	}
	if cards != 1 {
		t.Fatalf("device_activity cards = %d", cards)
	}
}

func TestSubmitRefusesAStaleCapture(t *testing.T) {
	pool := testPool(t)
	svc := testService(t, pool)
	device := testDevice(t, pool)

	now := time.Now().UTC()
	svc.now = func() time.Time { return now }
	id := "33333333333"

	req := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:   v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:        v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
			ExtractionMethod: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL,
			ObservedAt:       timestamppb.New(now.Add(-30 * 24 * time.Hour)),
		},
		ExtractorRevision: "test-1",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 1},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Search{
				Search: &v1.FacebookMarketplaceSearchListingObservation{
					Key: &v1.FacebookListingKey{FacebookListingId: &id},
				},
			}},
		},
	}
	if _, err := svc.Submit(context.Background(), Submission{DeviceID: device, Request: req}); err != ErrObservationStale {
		t.Fatalf("err = %v, want ErrObservationStale", err)
	}
}

// A signed-in desktop item page is the only surface with the profile id. The
// row it produces holds the reputation and a hash, and the id itself is nowhere.
func TestSubmitStoresSellerReputationAndNotTheProfileID(t *testing.T) {
	pool := testPool(t)
	svc := testService(t, pool)
	device := testDevice(t, pool)
	ctx := context.Background()

	now := time.Now().UTC()
	svc.now = func() time.Time { return now }

	listingID, profileID := "44444444444", "100000123456789"
	req := &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:              v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:                   v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM,
			ExtractionMethod:            v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_HYBRID,
			FacebookAuthenticationState: v1.FacebookAuthenticationState_FACEBOOK_AUTHENTICATION_STATE_SIGNED_IN,
			ObservedAt:                  timestamppb.New(now),
		},
		ExtractorRevision: "test-1",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: 1},
		Observations: []*v1.FacebookMarketplaceListingObservation{
			{Observation: &v1.FacebookMarketplaceListingObservation_Detail{
				Detail: &v1.FacebookMarketplaceListingDetailObservation{
					Key:            &v1.FacebookListingKey{FacebookListingId: &listingID},
					Title:          ptr("Solid oak six-drawer dresser"),
					CaptureSettled: true,
					Seller: &v1.FacebookMarketplaceSellerObservation{
						SectionStatus:     v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED,
						FacebookProfileId: &profileID,
						DisplayName:       ptr("Kelsey Jones"),
						Rating:            ptr(4.8),
						JoinedText:        ptr("Joined Facebook in 2010"),
						JoinedYear:        ptr(int32(2010)),
						RatingCount:       ptr(int32(44)),
						HighlyRated:       ptr(true),
					},
				},
			}},
		},
	}
	resp, err := svc.Submit(ctx, Submission{DeviceID: device, Request: req})
	if err != nil {
		t.Fatal(err)
	}
	if resp.GetAccepted() != 1 {
		t.Fatalf("accepted = %d, rejections %+v", resp.GetAccepted(), resp.GetRejections())
	}

	var (
		clusterKey  []byte
		name        string
		rating      float32
		joinedText  string
		joinedYear  int32
		ratingCount int32
		highlyRated bool
	)
	err = pool.QueryRow(ctx, `
		SELECT s.seller_cluster_key, s.display_name, s.rating, s.joined_text,
		       s.joined_year, s.rating_count, s.highly_rated
		FROM sellers s JOIN listings l ON l.seller_id = s.id
		WHERE l.facebook_listing_id = $1`, listingID,
	).Scan(&clusterKey, &name, &rating, &joinedText, &joinedYear, &ratingCount, &highlyRated)
	if err != nil {
		t.Fatal(err)
	}

	if string(clusterKey) != string(ClusterKey([]byte("test-seller-key"), profileID)) {
		t.Fatal("cluster key is not the keyed hash of the profile id")
	}
	if name != "Kelsey Jones" || rating != 4.8 || joinedYear != 2010 || ratingCount != 44 || !highlyRated {
		t.Fatalf("seller row: %s %v %d %d %v", name, rating, joinedYear, ratingCount, highlyRated)
	}
	if joinedText != "Joined Facebook in 2010" {
		t.Fatalf("joined_text = %q", joinedText)
	}

	// The identifier must be absent from the whole table, not merely from the
	// column it would have had.
	var leaked int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM sellers WHERE display_name = $1 OR joined_text = $1`, profileID,
	).Scan(&leaked); err != nil {
		t.Fatal(err)
	}
	if leaked != 0 {
		t.Fatal("the profile id reached a stored column")
	}
}
