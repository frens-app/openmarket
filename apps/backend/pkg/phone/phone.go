// Package phone normalises and screens the one identifier this service
// authenticates against.
package phone

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

// e164 is deliberately strict. The client composes the number from a country
// picker, so anything that doesn't already look like E.164 is a client bug
// rather than a user typo to be rescued.
var e164 = regexp.MustCompile(`^\+[1-9][0-9]{6,14}$`)

// Number is a phone number that has passed normalisation and the country
// allowlist.
type Number struct {
	// E164 including the leading '+'. This is what goes in
	// user_auth_methods.subject.
	E164 string
	// CountryCode is the calling code without the '+', e.g. "1" or "44".
	CountryCode string
}

// Allowlist screens numbers by calling code.
//
// This is not a nicety. SMS pumping works by cycling numbers on premium ranges
// in countries the product has no users in, and the bill lands before any
// alert does — so the cheapest effective control is refusing to send anywhere
// we don't serve. The list is config, so opening a new market is an env var
// rather than a deploy.
type Allowlist struct {
	// Sorted longest-first so lookup is a longest-prefix match: "1" and "1242"
	// (Bahamas) are both valid codes and the longer one has to win.
	codes []string
}

// NewAllowlist builds an allowlist from a comma-separated list of calling
// codes, with or without leading '+' ("1, +44").
//
// An empty list is an error rather than "allow everything". Defaulting open
// here would mean a missing env var silently unlocks every premium range on
// earth, which is the failure this type exists to prevent.
func NewAllowlist(raw string) (*Allowlist, error) {
	seen := map[string]bool{}
	var codes []string
	for _, part := range strings.Split(raw, ",") {
		code := strings.TrimPrefix(strings.TrimSpace(part), "+")
		if code == "" {
			continue
		}
		if !isDigits(code) || len(code) > 3 {
			return nil, fmt.Errorf("invalid country calling code %q", part)
		}
		if !seen[code] {
			seen[code] = true
			codes = append(codes, code)
		}
	}
	if len(codes) == 0 {
		return nil, fmt.Errorf("country allowlist is empty; set allowed_country_codes (e.g. \"1\")")
	}
	sort.Slice(codes, func(i, j int) bool { return len(codes[i]) > len(codes[j]) })
	return &Allowlist{codes: codes}, nil
}

// Codes returns the configured calling codes, longest first.
func (a *Allowlist) Codes() []string { return append([]string(nil), a.codes...) }

// ErrNotAllowed is returned for a syntactically valid number whose country is
// not served.
type ErrNotAllowed struct{ E164 string }

func (e ErrNotAllowed) Error() string {
	return fmt.Sprintf("phone number %s is not in a served country", mask(e.E164))
}

// Parse normalises a client-supplied number and screens it.
//
// Normalisation is intentionally shallow — strip formatting, require E.164 —
// rather than the full libphonenumber treatment. The provider does the real
// reachability check on send, and carrying a 10MB metadata table to reformat
// something the client already formatted correctly is not a trade worth making
// at this size. If national-format entry ever ships, this is where
// libphonenumber goes.
func (a *Allowlist) Parse(raw string) (Number, error) {
	normalized := strings.Map(func(r rune) rune {
		switch {
		case r >= '0' && r <= '9', r == '+':
			return r
		default:
			return -1
		}
	}, strings.TrimSpace(raw))

	if !e164.MatchString(normalized) {
		return Number{}, fmt.Errorf("phone number must be E.164, e.g. +14155550123")
	}

	// Length beyond E.164's own floor is deliberately not checked here. National
	// number lengths vary from 4 digits to 12 and the only authority on whether
	// a given number is reachable is the carrier, which the provider asks on
	// send. A stricter local rule buys nothing and would reject real numbers in
	// small territories.
	digits := normalized[1:]
	for _, code := range a.codes {
		if strings.HasPrefix(digits, code) {
			return Number{E164: normalized, CountryCode: code}, nil
		}
	}
	return Number{}, ErrNotAllowed{E164: normalized}
}

// Mask renders a number for logs and errors: country code, then the last two
// digits. Enough to correlate a support report, not enough to be a phone number
// sitting in a log aggregator.
func (n Number) Mask() string { return mask(n.E164) }

func mask(e164Number string) string {
	if len(e164Number) < 4 {
		return "***"
	}
	return e164Number[:2] + strings.Repeat("*", len(e164Number)-4) + e164Number[len(e164Number)-2:]
}

func isDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return s != ""
}
