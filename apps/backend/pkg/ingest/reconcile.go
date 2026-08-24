package ingest

import (
	"strings"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
)

// merged is the outcome of applying one observation to one canonical row.
type merged struct {
	params  db.UpdateListingFromObservationParams
	changed []string
	// needsCorroboration is set when the observation proposes moving
	// availability backwards and the caller has not yet established whether a
	// second submitter agrees. The caller re-runs the merge with corroborated
	// set rather than guessing.
	needsCorroboration bool
}

// mergeListing applies the rule that governs every field group:
//
//	A partial Facebook observation can add knowledge or refresh a volatile
//	fact; it cannot erase a richer fact.
//
// Which is why almost nothing here writes a nil over a value. The exceptions
// are price and availability, which are volatile by nature, and both are gated
// on the source being able to see them at all.
func mergeListing(cur db.Listing, c Candidate, src source, observedAt time.Time, corroborated bool) merged {
	out := merged{params: db.UpdateListingFromObservationParams{
		ID: cur.ID,

		// Carried forward by default. The UPDATE writes every column, so a
		// field this observation cannot speak to has to be restated.
		Title:               cur.Title,
		Description:         cur.Description,
		Condition:           cur.Condition,
		CategoryPath:        cur.CategoryPath,
		FacebookCategoryID:  cur.FacebookCategoryID,
		PriceMinor:          cur.PriceMinor,
		PriceCurrency:       cur.PriceCurrency,
		PriceFormatted:      cur.PriceFormatted,
		PreviousPriceMinor:  cur.PreviousPriceMinor,
		PriceChangedAt:      cur.PriceChangedAt,
		Availability:        cur.Availability,
		AvailabilityRaw:     cur.AvailabilityRaw,
		SoldNotBefore:       cur.SoldNotBefore,
		SoldNotAfter:        cur.SoldNotAfter,
		DeliveryTypes:       cur.DeliveryTypes,
		ListingLocationText: cur.ListingLocationText,
		ListingCity:         cur.ListingCity,
		ListingRegion:       cur.ListingRegion,
		ListingCountry:      cur.ListingCountry,
		FacebookPlaceID:     cur.FacebookPlaceID,
		ListingApproxLat:    cur.ListingApproxLat,
		ListingApproxLon:    cur.ListingApproxLon,
		SellerID:            cur.SellerID,
		ListedAt:            cur.ListedAt,
		ListedAtText:        cur.ListedAtText,
		ListedAtPrecision:   cur.ListedAtPrecision,
		FirstObservedAt:     cur.FirstObservedAt,
		LastObservedAt:      cur.LastObservedAt,
		DetailObservedAt:    cur.DetailObservedAt,
	}}

	at := timestamp(observedAt)
	out.params.FirstObservedAt = earliest(cur.FirstObservedAt, at)
	out.params.LastObservedAt = latest(cur.LastObservedAt, at)
	if src.isItemPage() {
		out.params.DetailObservedAt = latest(cur.DetailObservedAt, at)
	}

	var (
		title    string
		price    *v1.FacebookMarketplacePriceObservation
		place    *v1.FacebookMarketplacePlaceObservation
		delivery []string
	)

	if s := c.Search; s != nil {
		title, price, place, delivery = s.GetTitle(), s.GetPrice(), s.GetListingLocation(), s.GetDeliveryTypes()
		if s.FacebookCategoryId != nil {
			out.params.FacebookCategoryID = fillString(cur.FacebookCategoryID, s.GetFacebookCategoryId())
		}
		if s.Condition != nil {
			out.params.Condition = fillString(cur.Condition, s.GetCondition())
		}
		// Exact creation_time, and only from a source that has one. A coarse
		// estimate never replaces it and never enters this column.
		if s.ListedAt != nil && src.carriesExactListedAt() {
			out.params.ListedAt = timestamp(s.GetListedAt().AsTime())
			out.params.ListedAtPrecision = precision(db.ListedAtPrecisionExact)
		}
	}

	if d := c.Detail; d != nil {
		title, price, place, delivery = d.GetTitle(), d.GetPrice(), d.GetListingLocation(), d.GetDeliveryTypes()
		out.params.Description = richerString(cur.Description, d.GetDescription())
		out.params.Condition = fillString(cur.Condition, d.GetCondition())
		if d.ListedAtText != nil {
			out.params.ListedAtText = fillString(cur.ListedAtText, d.GetListedAtText())
			// The coarse text does not overwrite an exact instant, and it does
			// not claim a precision it cannot support. "Listed 3 weeks ago"
			// bounds a date; it does not name one.
			if !cur.ListedAt.Valid && out.params.ListedAtPrecision == nil {
				out.params.ListedAtPrecision = precision(db.ListedAtPrecisionWeek)
			}
		}
	}

	// A search card truncates its title where the embedded payload does not, so
	// "at least as rich" is the test rather than "newer".
	out.params.Title = richerString(cur.Title, title)

	if len(delivery) > 0 {
		out.params.DeliveryTypes = delivery
	}

	applyPrice(&out, cur, c, price, observedAt)
	applyPlace(&out, cur, place)
	applyAvailability(&out, cur, c, src, observedAt, corroborated)

	return out
}

// applyPrice overwrites from any observation that carried one, and records the
// move. Price is volatile: unlike a description, the newest reading is the
// right one even when it comes from a poorer source.
func applyPrice(
	out *merged,
	cur db.Listing,
	c Candidate,
	price *v1.FacebookMarketplacePriceObservation,
	observedAt time.Time,
) {
	if price == nil {
		return
	}
	if f := price.GetFormattedAmount(); f != "" {
		out.params.PriceFormatted = &f
	}
	if prev, err := parsePreviousPrice(price); err == nil && prev != nil {
		out.params.PreviousPriceMinor = prev
	}
	if c.PriceMinor == nil {
		return
	}
	out.params.PriceMinor = c.PriceMinor
	out.params.PriceCurrency = c.PriceCurrency
	if cur.PriceMinor == nil || *cur.PriceMinor != *c.PriceMinor {
		out.params.PriceChangedAt = timestamp(observedAt)
		if cur.PriceMinor != nil {
			out.changed = append(out.changed, "price")
		}
	}
}

// applyPlace fills gaps only. The coordinate belongs to the listing and must
// never reach a seller row; keeping the two in separate columns is what makes
// that a type error rather than a judgement call.
func applyPlace(out *merged, cur db.Listing, place *v1.FacebookMarketplacePlaceObservation) {
	if place == nil {
		return
	}
	out.params.ListingLocationText = fillString(cur.ListingLocationText, place.GetDisplayText())
	out.params.ListingCity = fillString(cur.ListingCity, place.GetCity())
	out.params.ListingRegion = fillString(cur.ListingRegion, place.GetRegion())
	out.params.ListingCountry = fillString(cur.ListingCountry, place.GetCountry())
	out.params.FacebookPlaceID = fillString(cur.FacebookPlaceID, place.GetFacebookPlaceId())
	if place.Latitude != nil && cur.ListingApproxLat == nil {
		lat, lon := place.GetLatitude(), place.GetLongitude()
		out.params.ListingApproxLat = &lat
		out.params.ListingApproxLon = &lon
	}
}

// availabilityRank orders the states a listing moves through. Movement up the
// order is where listings go; movement down is a relist, which is real but far
// rarer than a stale card arriving late.
func availabilityRank(a db.ListingAvailability) int {
	switch a {
	case db.ListingAvailabilityAvailable:
		return 1
	case db.ListingAvailabilityPending:
		return 2
	case db.ListingAvailabilitySold:
		return 3
	default:
		return 0
	}
}

func applyAvailability(
	out *merged,
	cur db.Listing,
	c Candidate,
	src source,
	observedAt time.Time,
	corroborated bool,
) {
	if !src.carriesAvailability() || c.Availability == db.ListingAvailabilityUnknown {
		return
	}

	forward := availabilityRank(c.Availability) >= availabilityRank(cur.Availability)
	if !forward && !src.isItemPage() && !corroborated {
		// A single search card cannot resurrect a sold listing. The caller
		// counts distinct submitters and comes back.
		out.needsCorroboration = true
		return
	}

	if c.Availability != cur.Availability {
		out.changed = append(out.changed, "availability")
	}
	out.params.Availability = c.Availability
	out.params.AvailabilityRaw = c.AvailabilityRaw

	at := timestamp(observedAt)
	switch {
	case c.Availability == db.ListingAvailabilitySold:
		// First sighting of sold closes the upper bound. A later sighting does
		// not move it: the earliest observation of sold is the tightest true
		// statement we have.
		out.params.SoldNotAfter = earliest(cur.SoldNotAfter, at)
	case !forward:
		// A relist. The old bracket described a sale that was undone, so it is
		// cleared rather than carried into a listing that is for sale again.
		out.params.SoldNotBefore = at
		out.params.SoldNotAfter = pgtype.Timestamptz{}
	default:
		// Observed not sold. Every such sighting raises the lower bound, which
		// is the only thing that narrows the interval on a listing nobody has
		// opened.
		out.params.SoldNotBefore = latest(cur.SoldNotBefore, at)
	}
}

// mediaPlan is what to write for one listing's photos.
type mediaPlan struct {
	upsert []db.UpsertListingMediaParams
	// keep is non-nil only when the capture is entitled to delete. An empty,
	// non-nil slice would delete everything, so the caller must check for nil
	// rather than for length.
	keep []string
}

func planMedia(listingID uuid.UUID, c Candidate, src source, observedAt time.Time) mediaPlan {
	var observed []*v1.FacebookMarketplaceMediaObservation
	switch {
	case c.Detail != nil:
		observed = c.Detail.GetMedia()
	case c.Search != nil && c.Search.GetPrimaryPhoto() != nil:
		observed = []*v1.FacebookMarketplaceMediaObservation{c.Search.GetPrimaryPhoto()}
	}

	plan := mediaPlan{}
	at := timestamp(observedAt)
	for _, m := range observed {
		id := m.GetFacebookPhotoId()
		if id == "" {
			// An fbcdn URL is a locator, not identity. A photo we cannot name
			// is a photo we cannot deduplicate, and inserting it would grow the
			// gallery by one on every capture.
			continue
		}
		params := db.UpsertListingMediaParams{
			ListingID:       listingID,
			FacebookPhotoID: &id,
			Position:        m.Position,
			LastSourceUrlAt: at,
		}
		if u := m.GetUrl(); u != "" {
			params.LastSourceUrl = &u
		}
		plan.upsert = append(plan.upsert, params)
		if plan.keep != nil || src.canShrinkGallery() {
			plan.keep = append(plan.keep, id)
		}
	}
	if src.canShrinkGallery() && plan.keep == nil {
		// A settled item page that showed no photos at all. Still entitled to
		// empty the gallery, and the non-nil empty slice is how that is said.
		plan.keep = []string{}
	}
	return plan
}

// sellerObservation is the part of a detail capture that may reach a seller
// row: a key to group on, and the reputation that hangs off it.
type sellerObservation struct {
	clusterKey  []byte
	displayName *string
	rating      *float32
	joinedText  *string
	joinedYear  *int32
	ratingCount *int32
	highlyRated *bool
}

func (o *sellerObservation) empty() bool {
	return o.clusterKey == nil && o.displayName == nil && o.rating == nil &&
		o.joinedText == nil && o.joinedYear == nil && o.ratingCount == nil &&
		o.highlyRated == nil
}

// sellerFrom extracts what may be stored, and drops what may not.
//
// The one field that is dropped is the profile id. It is hashed here and never
// persisted: it names a specific Facebook account, and it is only readable with
// a session. Everything else describes how a seller trades rather than who they
// are, and it hangs off a key that already names nobody
// (docs/ingest-attribution.md §1.4).
//
// The seller's *location* is not read at all, on any surface. The item page's
// city and coordinate belong to the listing and are stored there.
func sellerFrom(s *v1.FacebookMarketplaceSellerObservation, secret []byte) *sellerObservation {
	if s == nil || s.GetSectionStatus() != v1.FacebookMarketplaceSellerSectionStatus_FACEBOOK_MARKETPLACE_SELLER_SECTION_STATUS_OBSERVED {
		return nil
	}
	out := &sellerObservation{}
	if id := s.GetFacebookProfileId(); id != "" {
		out.clusterKey = ClusterKey(secret, id)
	}
	if name := strings.TrimSpace(s.GetDisplayName()); name != "" {
		out.displayName = &name
	}
	if s.Rating != nil {
		r := float32(s.GetRating())
		out.rating = &r
	}
	if text := strings.TrimSpace(s.GetJoinedText()); text != "" {
		out.joinedText = &text
	}
	if s.JoinedYear != nil {
		year := s.GetJoinedYear()
		out.joinedYear = &year
	}
	if s.RatingCount != nil {
		count := s.GetRatingCount()
		out.ratingCount = &count
	}
	// Facebook's own badge, carried through as observed. It is never recomputed
	// from rating and rating_count: the threshold behind it is unpublished, so a
	// derived badge would appear on sellers Facebook does not give it to.
	if s.HighlyRated != nil {
		badge := s.GetHighlyRated()
		out.highlyRated = &badge
	}
	if out.empty() {
		return nil
	}
	return out
}

func fillString(current *string, observed string) *string {
	if observed == "" {
		return current
	}
	if current != nil {
		return current
	}
	v := observed
	return &v
}

// richerString replaces only when the new value says at least as much.
//
// Length is a proxy and it is the right one here: the failure it guards against
// is a rendered card's truncated title overwriting the payload's full one, and
// truncation is exactly a loss of characters.
func richerString(current *string, observed string) *string {
	if observed == "" {
		return current
	}
	if current == nil || len([]rune(observed)) >= len([]rune(*current)) {
		v := observed
		return &v
	}
	return current
}

func timestamp(t time.Time) pgtype.Timestamptz {
	return pgtype.Timestamptz{Time: t, Valid: true}
}

func precision(p db.ListedAtPrecision) *db.ListedAtPrecision { return &p }

func earliest(a, b pgtype.Timestamptz) pgtype.Timestamptz {
	if !a.Valid {
		return b
	}
	if !b.Valid || a.Time.Before(b.Time) {
		return a
	}
	return b
}

func latest(a, b pgtype.Timestamptz) pgtype.Timestamptz {
	if !a.Valid {
		return b
	}
	if !b.Valid || a.Time.After(b.Time) {
		return a
	}
	return b
}
