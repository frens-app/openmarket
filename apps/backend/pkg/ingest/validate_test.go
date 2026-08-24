package ingest

import (
	"testing"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"google.golang.org/protobuf/types/known/timestamppb"
)

var observedAt = time.Date(2026, 8, 22, 12, 0, 0, 0, time.UTC)

func searchObs(mutate func(*v1.FacebookMarketplaceSearchListingObservation)) *v1.FacebookMarketplaceListingObservation {
	id := "1234567890"
	s := &v1.FacebookMarketplaceSearchListingObservation{
		Key:   &v1.FacebookListingKey{FacebookListingId: &id},
		Title: ptr("Oak dresser"),
		Price: price("40.00", "USD"),
	}
	if mutate != nil {
		mutate(s)
	}
	return &v1.FacebookMarketplaceListingObservation{
		Observation: &v1.FacebookMarketplaceListingObservation_Search{Search: s},
	}
}

func request(route v1.FacebookMarketplacePageRoute, obs ...*v1.FacebookMarketplaceListingObservation) *v1.SubmitObservationsRequest {
	return &v1.SubmitObservationsRequest{
		Context: &v1.FacebookMarketplaceObservationContext{
			BrowserVariant:   v1.FacebookMarketplaceBrowserVariant_FACEBOOK_MARKETPLACE_BROWSER_VARIANT_DESKTOP,
			PageRoute:        route,
			ExtractionMethod: v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL,
			ObservedAt:       timestamppb.New(observedAt),
		},
		ExtractorRevision: "test",
		Counts:            &v1.ClientExtractionCounts{CardsSeen: int32(len(obs))},
		Observations:      obs,
	}
}

func TestValidateAcceptsAWellFormedCard(t *testing.T) {
	cands, rejects := Validate(request(v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH, searchObs(nil)), observedAt)
	if len(rejects) != 0 {
		t.Fatalf("unexpected rejections: %+v", rejects)
	}
	if len(cands) != 1 || cands[0].PriceMinor == nil || *cands[0].PriceMinor != 4000 {
		t.Fatalf("candidate = %+v", cands)
	}
}

// The failure this whole gate exists for: a field whose *shape* changed still
// passes every pattern in the schema, and a per-field drop would spread
// listings from 1970 across the corpus instead of emptying one batch.
func TestValidateRejectsImplausibleListedAt(t *testing.T) {
	cases := map[string]time.Time{
		"epoch seconds read as milliseconds": time.Unix(1_700_000, 0).UTC(),
		"ahead of the capture":               observedAt.Add(72 * time.Hour),
	}
	for name, at := range cases {
		t.Run(name, func(t *testing.T) {
			obs := searchObs(func(s *v1.FacebookMarketplaceSearchListingObservation) {
				s.ListedAt = timestamppb.New(at)
			})
			cands, rejects := Validate(request(v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH, obs), observedAt)
			if len(cands) != 0 {
				t.Fatal("want the card refused")
			}
			if len(rejects) != 1 || rejects[0].Reason != v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_IMPLAUSIBLE_VALUE {
				t.Fatalf("rejections = %+v", rejects)
			}
		})
	}
}

// An extractor that attributed one listing's fields to another produces the
// same key twice. Neither copy can be trusted, so neither is kept.
func TestValidateRejectsBothSidesOfAKeyCollision(t *testing.T) {
	req := request(v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH, searchObs(nil), searchObs(nil))
	cands, rejects := Validate(req, observedAt)
	if len(cands) != 0 {
		t.Fatalf("want both refused, kept %d", len(cands))
	}
	if len(rejects) != 2 {
		t.Fatalf("rejections = %+v", rejects)
	}
	for _, r := range rejects {
		if r.Reason != v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_KEY_COLLISION {
			t.Fatalf("reason = %v", r.Reason)
		}
	}
}

func TestValidateRejectsRouteMismatch(t *testing.T) {
	req := request(v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM, searchObs(nil))
	_, rejects := Validate(req, observedAt)
	if len(rejects) != 1 || rejects[0].Reason != v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ROUTE_MISMATCH {
		t.Fatalf("rejections = %+v", rejects)
	}
}

// A plain search returns 0 sold and 0 pending by construction, so a sold card
// from an unfiltered query is a card we cannot label.
func TestValidateRejectsSoldFromAnUnfilteredQuery(t *testing.T) {
	obs := searchObs(func(s *v1.FacebookMarketplaceSearchListingObservation) {
		s.Availability = &v1.FacebookMarketplaceAvailabilityObservation{Sold: ptr(true), Pending: ptr(false)}
	})
	req := request(v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH, obs)
	req.Query = &v1.FacebookMarketplaceQueryContext{
		AvailabilityFilter: v1.FacebookMarketplaceAvailabilityFilter_FACEBOOK_MARKETPLACE_AVAILABILITY_FILTER_UNSPECIFIED,
	}
	_, rejects := Validate(req, observedAt)
	if len(rejects) != 1 || rejects[0].Reason != v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_CONTRADICTORY_FIELDS {
		t.Fatalf("rejections = %+v", rejects)
	}

	// The same card from availability=out of stock is the strongest public
	// evidence of a sale there is.
	req.Query.AvailabilityFilter = v1.FacebookMarketplaceAvailabilityFilter_FACEBOOK_MARKETPLACE_AVAILABILITY_FILTER_OUT_OF_STOCK
	cands, rejects := Validate(req, observedAt)
	if len(rejects) != 0 || len(cands) != 1 {
		t.Fatalf("cands=%d rejects=%+v", len(cands), rejects)
	}
	if cands[0].Availability != db.ListingAvailabilitySold {
		t.Fatalf("availability = %v", cands[0].Availability)
	}
}

func TestReconcileAvailability(t *testing.T) {
	tests := []struct {
		name          string
		sold, pending *bool
		live          *bool
		want          db.ListingAvailability
	}{
		{name: "nothing said", want: db.ListingAvailabilityUnknown},
		{name: "both false is a positive statement", sold: ptr(false), pending: ptr(false), want: db.ListingAvailabilityAvailable},
		{name: "sold", sold: ptr(true), pending: ptr(false), want: db.ListingAvailabilitySold},
		{name: "pending", sold: ptr(false), pending: ptr(true), want: db.ListingAvailabilityPending},
		{name: "both true is not a state Facebook publishes", sold: ptr(true), pending: ptr(true), want: availabilityInvalid},
		// is_live has been observed true on sold cards, so it is not an
		// availability signal and must not move the answer.
		{name: "live does not decide", sold: ptr(true), pending: ptr(false), live: ptr(true), want: db.ListingAvailabilitySold},
		{name: "half a statement is not one", sold: ptr(false), want: db.ListingAvailabilityUnknown},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, _ := reconcileAvailability(&v1.FacebookMarketplaceAvailabilityObservation{
				Sold: tt.sold, Pending: tt.pending, Live: tt.live,
			})
			if got != tt.want {
				t.Fatalf("availability = %v, want %v", got, tt.want)
			}
		})
	}
}
