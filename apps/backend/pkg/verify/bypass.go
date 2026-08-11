package verify

import (
	"context"
	"crypto/subtle"
	"fmt"
	"strings"

	"go.uber.org/zap"
)

// BypassSender lets a fixed list of numbers skip the provider, and passes
// everything else through.
//
// It **wraps** a real sender rather than replacing one, and that is the whole
// design. The previous version substituted the entire sender when a flag was
// set, which meant a developer chose between a login they could actually use and
// a login that ran the production code path — so form encoding, the auth header,
// status parsing and provider-error mapping were only ever exercised in
// production. Now the bypass covers exactly the numbers on the list and nothing
// else takes a different route.
//
// What it is for: the dev skip button on the login screen, and a demo account
// for App Review, who have no way to receive a code on our behalf. Both are
// cases where a specific known number must work without SMS, not cases where SMS
// should stop happening.
//
// config.requireAPIValues panics if the list is non-empty with env=production.
type BypassSender struct {
	numbers map[string]struct{}
	code    string
	next    Sender
	logger  *zap.Logger
}

// NewBypassSender wraps next so that the listed E.164 numbers accept code
// without contacting the provider. An empty list returns next unchanged, so
// production carries none of this.
func NewBypassSender(numbers []string, code string, next Sender, logger *zap.Logger) (Sender, error) {
	set := map[string]struct{}{}
	for _, raw := range numbers {
		if n := strings.TrimSpace(raw); n != "" {
			set[n] = struct{}{}
		}
	}
	if len(set) == 0 {
		return next, nil
	}
	if next == nil {
		return nil, fmt.Errorf("bypass sender needs a real sender to fall through to")
	}
	if strings.TrimSpace(code) == "" {
		return nil, fmt.Errorf("bypass code must not be empty")
	}

	listed := make([]string, 0, len(set))
	for n := range set {
		listed = append(listed, n)
	}
	// Loud on purpose: these numbers are a way into any account they own, and
	// the boot log is where somebody notices the list is wrong.
	logger.Warn("verification bypass active for specific numbers",
		zap.Strings("phone_numbers", listed),
		zap.String("code", code),
	)

	return &BypassSender{numbers: set, code: code, next: next, logger: logger}, nil
}

func (b *BypassSender) bypasses(e164 string) bool {
	_, ok := b.numbers[e164]
	return ok
}

// Start implements Sender.
func (b *BypassSender) Start(ctx context.Context, e164 string, signals Signals) error {
	if !b.bypasses(e164) {
		return b.next.Start(ctx, e164, signals)
	}
	b.logger.Info("bypassed verification send", zap.String("phone_number", e164))
	return nil
}

// Check implements Sender.
func (b *BypassSender) Check(ctx context.Context, e164, code string) (Result, error) {
	if !b.bypasses(e164) {
		return b.next.Check(ctx, e164, code)
	}
	if subtle.ConstantTimeCompare([]byte(code), []byte(b.code)) == 1 {
		return ResultApproved, nil
	}
	return ResultDenied, nil
}

// CodeLength implements Sender.
//
// The wrapped sender's, not the bypass code's: the client uses this to size its
// entry field, and it asks once, before any number has been typed.
func (b *BypassSender) CodeLength() int { return b.next.CodeLength() }
