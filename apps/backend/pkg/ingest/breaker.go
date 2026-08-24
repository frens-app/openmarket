package ingest

// Breaker refuses a whole source once its quarantine rate says the extractor no
// longer matches the page.
//
// A per-card gate is not enough on its own. When Facebook changes something the
// failure is not one bad card; it is every card from every device on that
// build, arriving at whatever rate the fleet browses. Refusing them one at a
// time still lets a systematically wrong extractor keep writing whatever it
// happens to get right, which is worse than nothing — a corpus with a bad patch
// in it and no marker where the patch starts.
type Breaker struct {
	// Rate at which the source stops being accepted, in [0, 1].
	Rate float64
	// Cards that must have been seen in the window before the rate is believed.
	// Without it, the first batch of a new extractor revision decides its fate:
	// three cards, two refused, and a working parser is switched off.
	MinCards int64
}

// Open reports whether this source's cards should be stored rather than merged.
func (b Breaker) Open(submitted, quarantined int64) bool {
	if submitted < b.MinCards {
		return false
	}
	return float64(quarantined)/float64(submitted) >= b.Rate
}
