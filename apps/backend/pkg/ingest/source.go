package ingest

import v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"

// source is what a capture is *able* to tell us, which is fixed by the page and
// the extraction method rather than by how recently it arrived.
//
// Recency alone is the wrong merge rule here. A rendered card scrolled into a
// feed carries a truncated title and no exact timestamp; the embedded payload
// on the same page carries both. Letting the later of the two win would make
// every scroll degrade the listing it just re-observed.
type source struct {
	route   v1.FacebookMarketplacePageRoute
	method  v1.FacebookMarketplaceExtractionMethod
	auth    v1.FacebookAuthenticationState
	settled bool
}

func (s source) isItemPage() bool {
	return s.route == v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_ITEM
}

func (s source) isDiscover() bool {
	return s.route == v1.FacebookMarketplacePageRoute_FACEBOOK_MARKETPLACE_PAGE_ROUTE_DISCOVER
}

// carriesExactListedAt reports whether Facebook's own creation_time was
// available. Only the structured payload has it; a rendered card has "Listed 3
// weeks ago" at best, and writing that into the same column would make an
// estimate indistinguishable from a fact.
func (s source) carriesExactListedAt() bool {
	if s.isDiscover() {
		return false
	}
	return s.method == v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_EMBEDDED_GRAPHQL ||
		s.method == v1.FacebookMarketplaceExtractionMethod_FACEBOOK_MARKETPLACE_EXTRACTION_METHOD_HYBRID
}

// carriesAvailability reports whether sold and pending mean anything from here.
// A Discover card has no usable payload on any page, signed in or out, so it
// has no sold state to read (docs/discover.md §4.6).
func (s source) carriesAvailability() bool { return !s.isDiscover() }

// canShrinkGallery reports whether a missing photo is evidence of removal.
//
// A search card carries one cover photo and an unsettled item page carries
// whatever had loaded, so treating either as a complete gallery would delete
// most of a listing's photos on every pass.
func (s source) canShrinkGallery() bool { return s.isItemPage() && s.settled }

// carriesDetailFields reports whether the description, condition and seller
// section were reachable at all.
func (s source) carriesDetailFields() bool { return s.isItemPage() }
