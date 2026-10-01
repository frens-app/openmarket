package ingest

import (
	"fmt"
	"math"
	"strings"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

// The plausibility envelopes.
//
// protovalidate on listing.proto is syntactic: an eight-digit id, a
// three-letter currency, a rating within zero and five. Syntax does not catch a
// value that is well-formed and absurd, and that is the shape a Facebook change
// arrives in — if creation_time ever moves from seconds to milliseconds, every
// pattern in the schema still passes and the corpus fills with listings from
// 1970.
var (
	// Marketplace launched in 2016. A listing older than that is a unit error.
	earliestListedAt = time.Date(2016, 1, 1, 0, 0, 0, 0, time.UTC)
	// Ten million major units, in minor units at the commonest exponent. A real
	// listing above this is rarer than a parser that dropped a decimal point.
	maxPriceMinor int64 = 1_000_000_000
	maxTitleRunes       = 500
	maxMediaItems       = 60
)

// Rejection names one refused observation. It carries an index and a field
// path, never any of the card's content: the client already has the card, and
// echoing it back would put listing text in a response body for no reason.
type Rejection struct {
	Index     int
	Reason    v1.ObservationRejectionReason
	FieldPath string
}

// Candidate is an observation that passed every gate, with the values the
// reconciler would otherwise have to re-derive.
type Candidate struct {
	Index  int
	Search *v1.FacebookMarketplaceSearchListingObservation
	Detail *v1.FacebookMarketplaceListingDetailObservation

	FacebookListingID *string
	CoverPhotoFBID    *string

	// Nil when the price could not be expressed in minor units, which happens
	// whenever the currency is unknown — see parsePrice.
	PriceMinor         *int64
	PriceCurrency      *string
	PreviousPriceMinor *int64

	Availability    db.ListingAvailability
	AvailabilityRaw *string
}

// Key returns the alias pair, for logging and for the collision check.
func (c Candidate) key() string {
	if c.FacebookListingID != nil {
		return "l:" + *c.FacebookListingID
	}
	return "p:" + *c.CoverPhotoFBID
}

// Validate runs every gate that does not need the database.
//
// The governing rule: a field that is **present and does not parse** fails the
// whole card, not the field. A field Facebook stops sending arrives absent and
// degrades harmlessly, because a partial observation is already forbidden from
// erasing a richer fact. A field Facebook changes the shape of is the dangerous
// one, and it fails loudly here (docs/ingest-attribution.md §3.1).
func Validate(req *v1.SubmitObservationsRequest, observedAt time.Time) ([]Candidate, []Rejection) {
	var (
		candidates []Candidate
		rejections []Rejection
	)
	route := req.GetContext().GetPageRoute()

	for i, obs := range req.GetObservations() {
		cand, rej := validateOne(i, obs, route, observedAt)
		if rej != nil {
			rejections = append(rejections, *rej)
			continue
		}
		candidates = append(candidates, *cand)
	}

	return rejectCollisions(candidates, rejections)
}

// rejectCollisions drops every card sharing an alias with another card in the
// same batch.
//
// Not "keep the first": a repeated key is evidence the extractor attributed one
// listing's fields to another, which is the failure mode that has already cost
// this project coordinates, condition, sold state and photos separately
// (docs/parsing-conventions.md §3). Neither copy can be trusted, so neither is
// kept.
func rejectCollisions(candidates []Candidate, rejections []Rejection) ([]Candidate, []Rejection) {
	seen := make(map[string]int, len(candidates))
	for _, c := range candidates {
		seen[c.key()]++
	}

	kept := candidates[:0]
	for _, c := range candidates {
		if seen[c.key()] > 1 {
			rejections = append(rejections, Rejection{
				Index:     c.Index,
				Reason:    v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_KEY_COLLISION,
				FieldPath: "key",
			})
			continue
		}
		kept = append(kept, c)
	}
	return kept, rejections
}

func validateOne(
	index int,
	obs *v1.FacebookMarketplaceListingObservation,
	route v1.FacebookMarketplacePageRoute,
	observedAt time.Time,
) (*Candidate, *Rejection) {
	reject := func(reason v1.ObservationRejectionReason, path string) (*Candidate, *Rejection) {
		return nil, &Rejection{Index: index, Reason: reason, FieldPath: path}
	}
	malformed := func(path string) (*Candidate, *Rejection) {
		return reject(v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_MALFORMED_FIELD, path)
	}
	implausible := func(path string) (*Candidate, *Rejection) {
		return reject(v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_IMPLAUSIBLE_VALUE, path)
	}
	contradictory := func(path string) (*Candidate, *Rejection) {
		return reject(v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_CONTRADICTORY_FIELDS, path)
	}

	cand := Candidate{Index: index}

	var (
		key          *v1.FacebookListingKey
		title        string
		price        *v1.FacebookMarketplacePriceObservation
		place        *v1.FacebookMarketplacePlaceObservation
		availability *v1.FacebookMarketplaceAvailabilityObservation
		media        []*v1.FacebookMarketplaceMediaObservation
	)

	switch body := obs.GetObservation().(type) {
	case *v1.FacebookMarketplaceListingObservation_Search:
		if !isFeedRoute(route) {
			return reject(v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ROUTE_MISMATCH, "")
		}
		s := body.Search
		cand.Search = s
		key, title, price, place, availability = s.GetKey(), s.GetTitle(), s.GetPrice(), s.GetListingLocation(), s.GetAvailability()
		if p := s.GetPrimaryPhoto(); p != nil {
			media = []*v1.FacebookMarketplaceMediaObservation{p}
		}
		if s.ListedAt != nil {
			at := s.GetListedAt().AsTime()
			if at.Before(earliestListedAt) || at.After(observedAt.Add(24*time.Hour)) {
				return implausible("listed_at")
			}
		}
	case *v1.FacebookMarketplaceListingObservation_Detail:
		if route != v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM {
			return reject(v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ROUTE_MISMATCH, "")
		}
		d := body.Detail
		cand.Detail = d
		key, title, price, place, availability = d.GetKey(), d.GetTitle(), d.GetPrice(), d.GetListingLocation(), d.GetAvailability()
		media = d.GetMedia()
	default:
		return malformed("observation")
	}

	if id := key.GetFacebookListingId(); id != "" {
		cand.FacebookListingID = &id
	}
	if id := key.GetCoverPhotoFbid(); id != "" {
		cand.CoverPhotoFBID = &id
	}
	if cand.FacebookListingID == nil && cand.CoverPhotoFBID == nil {
		return malformed("key")
	}

	// Present and empty is a parse that produced nothing, which is different
	// from a surface that carried no title at all.
	if title != "" {
		trimmed := strings.TrimSpace(title)
		if trimmed == "" || len([]rune(trimmed)) > maxTitleRunes {
			return malformed("title")
		}
	}

	minor, currency, err := parsePrice(price)
	if err != nil {
		return malformed("price")
	}
	if minor != nil && (*minor < 0 || *minor > maxPriceMinor) {
		return implausible("price.amount_decimal")
	}
	cand.PriceMinor, cand.PriceCurrency = minor, currency
	previousMinor, err := parsePreviousPrice(price)
	if err != nil {
		return malformed("price.previous_amount_decimal")
	}
	if previousMinor != nil && (*previousMinor < 0 || *previousMinor > maxPriceMinor) {
		return implausible("price.previous_amount_decimal")
	}
	cand.PreviousPriceMinor = previousMinor

	if place != nil {
		lat, lon := place.Latitude, place.Longitude
		if (lat == nil) != (lon == nil) {
			return malformed("listing_location")
		}
		if lat != nil {
			if math.Abs(*lat) > 90 || math.Abs(*lon) > 180 {
				return implausible("listing_location")
			}
		}
	}

	if len(media) > maxMediaItems {
		return implausible("media")
	}
	positions := make(map[int32]struct{}, len(media))
	for _, m := range media {
		if m.Position == nil {
			continue
		}
		if _, dup := positions[*m.Position]; dup {
			return contradictory("media.position")
		}
		positions[*m.Position] = struct{}{}
	}

	cand.Availability, cand.AvailabilityRaw = reconcileAvailability(availability)
	if cand.Availability == availabilityInvalid {
		return contradictory("availability")
	}

	return &cand, nil
}

func isFeedRoute(route v1.FacebookMarketplacePageRoute) bool {
	return route == v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_SEARCH ||
		route == v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_DISCOVER
}

// availabilityInvalid is the sentinel for sold and pending both true, which is
// not a state Facebook has ever been observed publishing.
const availabilityInvalid db.ListingAvailability = "invalid"

// reconcileAvailability collapses Facebook's three independent booleans.
//
// is_live is not part of the derivation: it has been observed true on sold
// cards, so reading it as availability would call every sold listing available
// (docs/filter-parameters.md §10).
func reconcileAvailability(a *v1.FacebookMarketplaceAvailabilityObservation) (db.ListingAvailability, *string) {
	if a == nil || (a.Sold == nil && a.Pending == nil) {
		return db.ListingAvailabilityUnknown, nil
	}
	raw := fmt.Sprintf("sold=%s pending=%s live=%s",
		formatTristate(a.Sold), formatTristate(a.Pending), formatTristate(a.Live))

	sold, pending := a.GetSold(), a.GetPending()
	switch {
	case sold && pending:
		return availabilityInvalid, &raw
	case sold:
		return db.ListingAvailabilitySold, &raw
	case pending:
		return db.ListingAvailabilityPending, &raw
	default:
		// Both explicitly false is a positive statement that the listing is
		// available, which is not the same as neither being present.
		if a.Sold == nil || a.Pending == nil {
			return db.ListingAvailabilityUnknown, &raw
		}
		return db.ListingAvailabilityAvailable, &raw
	}
}

func formatTristate(b *bool) string {
	if b == nil {
		return "absent"
	}
	if *b {
		return "true"
	}
	return "false"
}
