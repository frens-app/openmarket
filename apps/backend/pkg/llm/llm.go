// Package llm wraps the model calls behind Price Check, and records what they
// cost.
//
// Two things live here and nothing else does: an interface narrow enough that
// swapping providers is a config change, and the bookkeeping that makes a call
// visible afterwards. Prompt text, JSON schemas and HTTP live in the per-
// provider files; the RPC handlers live in cmd/api and translate proto to the
// plain structs below.
//
// The structs are deliberately not the generated protobuf types. `verify` does
// the same thing for the same reason: a provider package that imports the wire
// schema ends up shaped by it, and the two change for entirely unrelated
// reasons.
package llm

import (
	"context"
	"errors"
	"fmt"
)

// Stage is which of the two calls a run belongs to. The values match the
// `llm_run_stage` enum in migration 00004.
type Stage string

const (
	StageIdentify Stage = "IDENTIFY"
	StagePrice    Stage = "PRICE"
)

// Photo is one image on its way to the model.
type Photo struct {
	// JPEG bytes, already downscaled by the client.
	Data []byte
	// IANA media type, e.g. "image/jpeg".
	MediaType string
}

// IdentifyInput is what the seller gave us: their words, and what they
// photographed. Photos may be empty — the call runs on the description alone,
// which is roughly what the tool could do before it could see anything.
type IdentifyInput struct {
	Description string
	Photos      []Photo
}

// IdentifiedItem is the model's read of the item, before it has seen a single
// comparable. That ordering is the point: the on-device model this replaces
// took the item's identity from the comparables when it had them, titling a
// stroller "IKEA Malm 4 Drawer Dresser White" on three runs out of three.
type IdentifiedItem struct {
	Name string
	// One or two. The second is a fallback phrasing of the same item, never a
	// second item.
	SearchQueries []string
	// A guess, and never used to narrow the search: condition words narrow the
	// query without narrowing the market. Empty when the model won't commit.
	Condition string
	// Distinguishing facts it could see or was told. The listing description is
	// built from these so that it describes the item rather than inventing it.
	KeyAttributes []string
}

// Comparable is one listing the phone read off a search card.
type Comparable struct {
	Title string
	// Minor units. Nil when the card carried no price we could read — which is
	// different from zero, and zero means Free.
	PriceMinor *int64
	// Seller-marked: "no longer for sale", never "sold for this".
	IsSold bool
	// Nil unless the card was dated. On a sold card this bounds how long the
	// item took to sell, because Facebook publishes no sale date.
	DaysListed *int32
	City       string
}

// MarketStats is the market reduced to numbers by PriceGuide, on the device.
//
// Passed in rather than derived, because the model must not do arithmetic about
// evidence it was just shown. Asked to justify its own figure against fourteen
// prices, the previous model wrote "you are asking CA$20 more than the median
// price of CA$80" — the median was CA$77 and the gap was CA$33.
type MarketStats struct {
	PricedCount   int32
	MedianMinor   int64
	LowestMinor   int64
	HighestMinor  int64
	LowerQuartile *int64
	UpperQuartile *int64
	// The symbol the cards used — "$", "CA$", "£". Not an ISO code.
	CurrencySymbol string

	// The sold half. It can support "this price worked" and can never support
	// "this price is too high": it is filtered on having sold, so the listings
	// that failed to sell at a price are exactly the ones missing.
	SoldCount        int32
	MedianDaysToSell *int32
}

// PriceInput is everything the pricing call sees.
type PriceInput struct {
	Item        IdentifiedItem
	Description string
	MarketName  string
	Comparables []Comparable
	Stats       MarketStats
}

// PricedItem is the answer. No rationale field: the sentence under the price is
// written in Swift from the numbers Swift computed, and is true by
// construction.
type PricedItem struct {
	// Minor units. A judgement, not a calculation — and clamped to the observed
	// range by the client before anybody sees it.
	PriceMinor int64
	Title      string
	Body       string
}

// Usage is what the provider said the call cost. Every field is a pointer
// because "not reported" and "zero" are different facts, and the columns they
// land in are nullable for the same reason.
//
// No money here, deliberately. Cost is a pure function of these counts and
// Model, so it can be computed retroactively over rows written long before a
// rate table exists — whereas a token count that was never written down is gone.
type Usage struct {
	InputTokens  *int32
	OutputTokens *int32
	// Reasoning tokens, where the provider reports them separately. Billed at
	// the output rate, and it is **not documented** whether OutputTokens
	// already includes them — see migration 00005. Recorded rather than folded
	// into OutputTokens so that whichever way it turns out, the number is still
	// there.
	ThoughtTokens     *int32
	CachedInputTokens *int32
	// The model string the provider actually served, which is not always the
	// one that was asked for — aliases resolve, and a version can move under a
	// stable name. Recorded because it, not our config, is what was billed.
	Model string
}

// Provider is one vendor's implementation of the two calls.
//
// Narrow on purpose. Everything a caller needs to swap Gemini for GPT or for a
// gateway is behind these three methods, and nothing above this line knows
// which one is configured.
type Provider interface {
	// Name is the vendor, recorded on every run: "google", "openai", "stub".
	Name() string
	Identify(ctx context.Context, in IdentifyInput) (IdentifiedItem, Usage, error)
	Price(ctx context.Context, in PriceInput) (PricedItem, Usage, error)
}

// ErrorCode is our classification of a failed call, stored on the run.
//
// Ours, not the provider's: the string in the column has to mean the same thing
// across vendors for the row to be worth querying, and a provider's own message
// is prose that belongs in the log line beside it.
type ErrorCode string

const (
	ErrorCodeTimeout       ErrorCode = "timeout"
	ErrorCodeRateLimited   ErrorCode = "rate_limited"
	ErrorCodeUnavailable   ErrorCode = "unavailable"
	ErrorCodeInvalidOutput ErrorCode = "invalid_output"
	// The provider's safety filter declined. Not retryable: it is a decision
	// about the input, so a second identical call gets the same answer. Worth
	// its own code because it is reachable in ordinary use — the previous model
	// refused "WhiteIKEAMalm dressed", which is just a keyboard swallowing
	// spaces.
	ErrorCodeRefused ErrorCode = "refused"
	ErrorCodeUnknown ErrorCode = "unknown"
)

// Error carries a classified failure up from a provider.
type Error struct {
	Code ErrorCode
	Err  error
}

func (e *Error) Error() string { return fmt.Sprintf("%s: %v", e.Code, e.Err) }
func (e *Error) Unwrap() error { return e.Err }

// Errorf builds a classified provider error.
func Errorf(code ErrorCode, format string, args ...any) *Error {
	return &Error{Code: code, Err: fmt.Errorf(format, args...)}
}

// CodeOf classifies an error, defaulting to unknown. An unclassified error is
// recorded rather than dropped: "unknown" appearing in the column is a prompt to
// come back and classify it, where a nil error_code would look like success.
func CodeOf(err error) ErrorCode {
	var e *Error
	if errors.As(err, &e) {
		return e.Code
	}
	return ErrorCodeUnknown
}

// retryable reports whether a second attempt could plausibly differ.
//
// invalid_output is on the list because a schema violation is usually a reroll
// away from being fine. refused is not, because it is a decision about the
// input. Everything unknown is retried once — the cost of one wasted call is
// lower than the cost of a transient fault the classifier didn't recognise
// ending the run.
func retryable(code ErrorCode) bool {
	switch code {
	case ErrorCodeRefused:
		return false
	default:
		return true
	}
}
