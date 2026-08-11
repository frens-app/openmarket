// Package verify wraps SMS code delivery and checking.
//
// The service never generates, stores, or compares a code itself. That is the
// whole point of buying this: code generation, delivery, expiry, attempt limits
// and fraud scoring are one provider's problem, and we keep only the users
// table and our own sessions.
package verify

import (
	"context"
	"errors"
)

// Result of checking a submitted code.
type Result int

const (
	// ResultApproved means the code was correct and the number is verified.
	ResultApproved Result = iota
	// ResultDenied means the code was wrong, expired, or already used.
	// Deliberately one value: telling a caller *which* of those it was tells an
	// attacker whether a guess was close.
	ResultDenied
)

// ErrTooManyAttempts is returned when the provider has locked the verification
// after repeated wrong codes. Distinct from ResultDenied because the client
// should send the user back to the start rather than let them keep typing.
var ErrTooManyAttempts = errors.New("too many verification attempts")

// ErrUndeliverable is returned when the provider will not send to this number
// at all — unroutable, a landline, or blocked by its own fraud scoring.
var ErrUndeliverable = errors.New("phone number cannot receive verification codes")

// Signals is optional per-request context the provider's fraud scoring uses.
//
// Prelude scores every verification on these, and a device identifier plus a
// platform is the difference between its model seeing a request from a real app
// install and seeing an anonymous phone number. Every field is optional: a
// missing signal costs some scoring accuracy, and refusing to send a code over
// one would be worse.
//
// Nothing here is stored. StartPhoneVerification runs before any account
// exists, so these values are forwarded to the provider and then dropped.
type Signals struct {
	// DeviceID identifies an app install, not a person and not hardware. This
	// is the same install_id the session is later keyed on.
	DeviceID string
	// DevicePlatform is "ios", "android", or "web"; empty when unknown.
	DevicePlatform string
}

// Sender delivers and checks verification codes.
type Sender interface {
	// Start requests delivery of a code to the number. Signals may be zero.
	Start(ctx context.Context, e164 string, signals Signals) error
	// Check validates a submitted code.
	Check(ctx context.Context, e164, code string) (Result, error)
	// CodeLength is how many digits the provider sends, so the client can size
	// its entry field from the server rather than hardcoding it.
	CodeLength() int
}
