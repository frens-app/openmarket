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

// Stage is which call a run belongs to. The values match the `llm_run_stage`
// enum in migration 00004.
//
// There is only one stage now. `StagePrice` stays defined because rows carrying
// it are already in the table and a reader that does not know the value cannot
// interpret them — the constant is how those rows stay legible, not a hint that
// something still writes them. Dropping the value from the Postgres enum would
// be worse still: it would fail against the existing data.
type Stage string

const (
	StageIdentify Stage = "IDENTIFY"
	// Written by the pricing call, which was removed. Historical only.
	StagePrice Stage = "PRICE"
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

// IdentifiedItem is everything the model produces: what the thing is, what to
// search for, and the listing to paste.
//
// All of it from the photo and the seller's words, and none of it from the
// market — because the model never sees the market. The on-device version this
// replaces did, and took the item's identity from it, titling a stroller "IKEA
// Malm 4 Drawer Dresser White" on three runs out of three. Writing the copy
// here rather than after the search is what makes that unreachable instead of
// prompted against.
type IdentifiedItem struct {
	Name string
	// One or two. The second is a fallback phrasing of the same item, never a
	// second item.
	SearchQueries []string
	// Distinguishing facts it could see or was told. Kept beside the listing
	// rather than folded into it, so the observations can be checked against the
	// prose built from them.
	KeyAttributes []string
	// The listing. Empty is survivable — the price is arithmetic and never
	// depended on these.
	ListingTitle string
	ListingBody  string
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

// Provider is one vendor's implementation of the one call.
//
// Narrow on purpose, and narrower than it was: everything a caller needs to
// swap Gemini for GPT or for a gateway is behind these two methods, and nothing
// above this line knows which one is configured. `Price` used to sit here. The
// price is a median now, so it is Swift's, not a vendor's.
type Provider interface {
	// Name is the vendor, recorded on every run: "google", "openai", "stub".
	Name() string
	Identify(ctx context.Context, in IdentifyInput) (IdentifiedItem, Usage, error)
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
	// We sent something the provider would not accept — a schema it rejects, a
	// key it does not recognise, a model id it cannot route. Separate from
	// `refused` because the two are indistinguishable in the column and opposite
	// in meaning: `refused` is a judgement about the user's item and the honest
	// advice is to reword it, while this is a bug in our request that no wording
	// will fix and every user hits at once.
	//
	// Earned: an empty string in the `condition` enum is legal JSON Schema and
	// illegal to Vertex, which 400s. Filed as `refused`, that read as "the model
	// declined this photo" — advice that would have sent every user rewording a
	// description while the real fault sat in a Go map.
	ErrorCodeBadRequest ErrorCode = "bad_request"
	ErrorCodeUnknown    ErrorCode = "unknown"
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
// input, and neither is bad_request, which retries into the identical 400.
// Everything unknown is retried once — the cost of one wasted call is lower
// than the cost of a transient fault the classifier didn't recognise ending the
// run.
func retryable(code ErrorCode) bool {
	switch code {
	case ErrorCodeRefused, ErrorCodeBadRequest:
		return false
	default:
		return true
	}
}
