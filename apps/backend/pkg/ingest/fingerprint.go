package ingest

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

// fieldSep is ASCII unit separator, which cannot appear in any of the tokens
// being joined. Joining on a character a value could contain would let two
// different queries hash the same.
const fieldSep = "\x1f"

// QueryFingerprint identifies a query without storing one.
//
// It is what makes absence interpretable at all: a listing missing from a
// result set proves nothing in general, and proves a little when the *same*
// query returned it recently (docs/ingest-attribution.md §2.2). Computed here
// rather than trusted from the client, so two clients that describe the same
// query the same way cannot disagree about it.
//
// The query text is already a hash when it arrives; the term itself never
// crosses the ingest boundary.
func QueryFingerprint(q *v1.FacebookMarketplaceQueryContext) []byte {
	if q == nil {
		return nil
	}
	parts := []string{
		hex.EncodeToString(q.GetQueryTextSha256()),
		strconv.Itoa(int(q.GetAvailabilityFilter())),
		optionalInt(q.DaysSinceListed),
		q.GetSortBy(),
		q.GetDeliveryMethod(),
		q.GetFacebookPlaceId(),
		optionalInt(q.RadiusMiles),
	}
	sum := sha256.Sum256([]byte(strings.Join(parts, fieldSep)))
	return sum[:]
}

// optionalInt distinguishes an unset filter from one explicitly set to zero.
// `daysSinceListed=0` and no day filter are different queries.
func optionalInt(v *int32) string {
	if v == nil {
		return ""
	}
	return strconv.Itoa(int(*v))
}
