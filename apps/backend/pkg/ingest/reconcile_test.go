package ingest

import (
	"testing"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"google.golang.org/protobuf/types/known/timestamppb"
)

func embeddedSearch() source {
	return source{
		route:  v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
		method: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL,
	}
}

func renderedSearch() source {
	return source{
		route:  v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH,
		method: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_RENDERED_DOM,
	}
}

func itemPage(settled bool) source {
	return source{
		route:   v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM,
		method:  v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_HYBRID,
		settled: settled,
	}
}

func candidate(s *v1.FacebookMarketplaceSearchListingObservation) Candidate {
	c := Candidate{Search: s}
	c.Availability, c.AvailabilityRaw = reconcileAvailability(s.GetAvailability())
	return c
}

// A rendered card truncates the title the embedded payload carries whole, so
// arriving later must not be enough to win.
func TestMergeKeepsTheRicherTitle(t *testing.T) {
	cur := db.Listing{ID: uuid.New(), Title: ptr("Solid oak six-drawer dresser, white")}
	got := mergeListing(cur, candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Title: ptr("Solid oak six-drawer…"),
	}), renderedSearch(), observedAt, false)

	if *got.params.Title != *cur.Title {
		t.Fatalf("title = %q, want the longer one", *got.params.Title)
	}
}

func TestFormattedOnlyObservationDoesNotSplitCanonicalPrice(t *testing.T) {
	minor, currency, formatted := int64(10_000), "USD", "$100"
	cur := db.Listing{
		ID: uuid.New(), PriceMinor: &minor, PriceCurrency: &currency,
		PriceFormatted: &formatted, PriceObservedAt: timestamp(observedAt),
	}
	c := Candidate{Search: &v1.FacebookMarketplaceSearchListingObservation{
		Price: &v1.FacebookMarketplacePriceObservation{FormattedAmount: ptr("$80")},
	}}

	got := mergeListing(cur, c, renderedSearch(), observedAt.Add(time.Hour), false)
	if *got.params.PriceMinor != minor || *got.params.PriceFormatted != formatted {
		t.Fatalf("formatted-only evidence split the price: %+v", got.params)
	}
}

func TestStaleObservationCannotRevertVolatileFields(t *testing.T) {
	minor, currency, formatted := int64(8_000), "USD", "$80"
	cur := db.Listing{
		ID: uuid.New(), PriceMinor: &minor, PriceCurrency: &currency,
		PriceFormatted: &formatted, PriceObservedAt: timestamp(observedAt),
		Availability:           db.ListingAvailabilityAvailable,
		AvailabilityObservedAt: timestamp(observedAt),
	}
	olderMinor := int64(10_000)
	stale := candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Price: &v1.FacebookMarketplacePriceObservation{
			AmountDecimal: ptr("100.00"), CurrencyCode: &currency,
			FormattedAmount: ptr("$100"),
		},
		Availability: &v1.FacebookMarketplaceAvailabilityObservation{
			Sold: ptr(true), Pending: ptr(false),
		},
	})
	stale.PriceMinor = &olderMinor
	stale.PriceCurrency = &currency

	got := mergeListing(cur, stale, embeddedSearch(), observedAt.Add(-time.Hour), false)
	if *got.params.PriceMinor != minor || got.params.Availability != db.ListingAvailabilityAvailable {
		t.Fatalf("stale evidence reverted canonical state: %+v", got.params)
	}
	if len(got.changed) != 0 {
		t.Fatalf("stale evidence created changes: %v", got.changed)
	}
}

// listed_at is Facebook's exact creation_time. A source that does not carry one
// must not write the column, and a coarse estimate must never land in it.
func TestMergeOnlyWritesExactListedAtFromAPayload(t *testing.T) {
	listedAt := time.Date(2026, 8, 1, 9, 0, 0, 0, time.UTC)
	obs := &v1.FacebookMarketplaceSearchListingObservation{ListedAt: timestamppb.New(listedAt)}

	fromPayload := mergeListing(db.Listing{ID: uuid.New()}, candidate(obs), embeddedSearch(), observedAt, false)
	if !fromPayload.params.ListedAt.Valid || !fromPayload.params.ListedAt.Time.Equal(listedAt) {
		t.Fatalf("listed_at = %v, want %v", fromPayload.params.ListedAt, listedAt)
	}
	if *fromPayload.params.ListedAtPrecision != db.ListedAtPrecisionExact {
		t.Fatalf("precision = %v", *fromPayload.params.ListedAtPrecision)
	}

	fromDOM := mergeListing(db.Listing{ID: uuid.New()}, candidate(obs), renderedSearch(), observedAt, false)
	if fromDOM.params.ListedAt.Valid {
		t.Fatal("a rendered card must not write an exact listed_at")
	}
}

func TestSoldBracket(t *testing.T) {
	id := uuid.New()
	earlier := observedAt.Add(-48 * time.Hour)

	available := candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Availability: &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(false), Pending: ptr(false)},
	})
	sold := candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Availability: &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(true), Pending: ptr(false)},
	})

	// Seeing it unsold raises the lower bound and says nothing else.
	first := mergeListing(db.Listing{ID: id}, available, embeddedSearch(), earlier, false)
	if !first.params.SoldNotBefore.Time.Equal(earlier) || first.params.SoldNotAfter.Valid {
		t.Fatalf("after an available sighting: %+v", first.params)
	}

	// Seeing it sold closes the upper bound, and the interval is now real.
	cur := db.Listing{ID: id, Availability: db.ListingAvailabilityAvailable, SoldNotBefore: first.params.SoldNotBefore}
	second := mergeListing(cur, sold, embeddedSearch(), observedAt, false)
	if !second.params.SoldNotBefore.Time.Equal(earlier) || !second.params.SoldNotAfter.Time.Equal(observedAt) {
		t.Fatalf("after a sold sighting: %+v", second.params)
	}

	// A later sighting of sold does not move the upper bound: the earliest
	// observation of sold is the tightest true statement available.
	cur = db.Listing{
		ID: id, Availability: db.ListingAvailabilitySold,
		SoldNotBefore: second.params.SoldNotBefore, SoldNotAfter: second.params.SoldNotAfter,
	}
	third := mergeListing(cur, sold, embeddedSearch(), observedAt.Add(72*time.Hour), false)
	if !third.params.SoldNotAfter.Time.Equal(observedAt) {
		t.Fatalf("sold_not_after moved to %v", third.params.SoldNotAfter.Time)
	}
	if len(third.changed) != 0 {
		t.Fatalf("re-observing the same state is not a change: %v", third.changed)
	}
}

// A stale search card must not resurrect a sold listing on its own. Relisting is
// real, so the transition has to be reachable — with a second submitter, or from
// the item page itself.
func TestBackwardTransitionNeedsCorroborationOrAnItemPage(t *testing.T) {
	cur := db.Listing{ID: uuid.New(), Availability: db.ListingAvailabilitySold, SoldNotAfter: timestamp(observedAt)}
	available := candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Availability: &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(false), Pending: ptr(false)},
	})
	later := observedAt.Add(24 * time.Hour)

	alone := mergeListing(cur, available, renderedSearch(), later, false)
	if !alone.needsCorroboration {
		t.Fatal("want corroboration to be required")
	}
	if alone.params.Availability != db.ListingAvailabilitySold {
		t.Fatalf("availability moved to %v without corroboration", alone.params.Availability)
	}

	agreed := mergeListing(cur, available, renderedSearch(), later, true)
	if agreed.params.Availability != db.ListingAvailabilityAvailable {
		t.Fatalf("availability = %v", agreed.params.Availability)
	}
	if agreed.params.SoldNotAfter.Valid {
		t.Fatal("a relist clears the bracket; it described a sale that was undone")
	}
	if !agreed.params.SoldNotBefore.Time.Equal(later) {
		t.Fatalf("sold_not_before = %v", agreed.params.SoldNotBefore.Time)
	}
}

// A Discover card carries no sold state on any page, signed in or out, so it
// must not be read as one.
func TestDiscoverNeverWritesAvailability(t *testing.T) {
	cur := db.Listing{ID: uuid.New(), Availability: db.ListingAvailabilitySold}
	c := candidate(&v1.FacebookMarketplaceSearchListingObservation{
		Availability: &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(false), Pending: ptr(false)},
	})
	src := source{
		route:  v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_DISCOVER,
		method: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_RENDERED_DOM,
	}
	got := mergeListing(cur, c, src, observedAt, false)
	if got.params.Availability != db.ListingAvailabilitySold || got.needsCorroboration {
		t.Fatalf("params = %+v", got.params)
	}
}

func TestPlanMediaOnlyShrinksFromASettledItemPage(t *testing.T) {
	id := uuid.New()
	photo := func(fbid string) *v1.FacebookMarketplaceMediaObservation {
		return &v1.FacebookMarketplaceMediaObservation{FacebookPhotoId: &fbid}
	}

	card := Candidate{Search: &v1.FacebookMarketplaceSearchListingObservation{PrimaryPhoto: photo("111")}}
	if plan := planMedia(id, card, embeddedSearch(), observedAt); plan.keep != nil {
		t.Fatal("a search card carries one cover photo, not a gallery")
	}

	partial := Candidate{Detail: &v1.FacebookMarketplaceListingDetailObservation{
		Media: []*v1.FacebookMarketplaceMediaObservation{photo("111")},
	}}
	if plan := planMedia(id, partial, itemPage(false), observedAt); plan.keep != nil {
		t.Fatal("an unsettled capture must not delete photos that had not loaded")
	}

	settled := Candidate{Detail: &v1.FacebookMarketplaceListingDetailObservation{
		Media: []*v1.FacebookMarketplaceMediaObservation{photo("111"), photo("222")},
	}}
	plan := planMedia(id, settled, itemPage(true), observedAt)
	if len(plan.keep) != 2 || len(plan.upsert) != 2 {
		t.Fatalf("plan = %+v", plan)
	}
}

// An fbcdn URL is an expiring locator. The same photo id with a new URL is
// expiry, not a new photo, and a photo with no id cannot be deduplicated at all.
func TestPlanMediaSkipsPhotosItCannotName(t *testing.T) {
	url := "https://scontent.example/expiring.jpg"
	c := Candidate{Detail: &v1.FacebookMarketplaceListingDetailObservation{
		Media: []*v1.FacebookMarketplaceMediaObservation{{Url: &url}},
	}}
	if plan := planMedia(uuid.New(), c, itemPage(true), observedAt); len(plan.upsert) != 0 {
		t.Fatalf("upserted an unnameable photo: %+v", plan.upsert)
	}
}
