package verify

import (
	"context"
	"errors"
	"testing"

	"go.uber.org/zap"
)

// recordingSender stands in for the wrapped provider so a test can tell whether
// a call reached it.
type recordingSender struct {
	started    []string
	gotSignals Signals
	checked    []string
	result     Result
	err        error
}

func (r *recordingSender) Start(_ context.Context, e164 string, signals Signals) error {
	r.started = append(r.started, e164)
	r.gotSignals = signals
	return r.err
}

func (r *recordingSender) Check(_ context.Context, e164, _ string) (Result, error) {
	r.checked = append(r.checked, e164)
	return r.result, r.err
}

func (r *recordingSender) CodeLength() int { return 6 }

const bypassed = "+15005550100"
const normal = "+14155550123"

func newBypass(t *testing.T, next Sender) Sender {
	t.Helper()
	s, err := NewBypassSender([]string{bypassed}, "111111", next, zap.NewNop())
	if err != nil {
		t.Fatalf("NewBypassSender: %v", err)
	}
	return s
}

// The property the whole redesign exists for: a number that isn't on the list
// goes to the provider unchanged, so dev runs the same path production does.
func TestBypassPassesUnlistedNumbersThrough(t *testing.T) {
	next := &recordingSender{result: ResultApproved}
	s := newBypass(t, next)

	if err := s.Start(context.Background(), normal, Signals{}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if got, err := s.Check(context.Background(), normal, "999999"); err != nil || got != ResultApproved {
		t.Fatalf("Check = %v, %v", got, err)
	}

	if len(next.started) != 1 || next.started[0] != normal {
		t.Fatalf("provider Start calls = %v, want [%s]", next.started, normal)
	}
	if len(next.checked) != 1 {
		t.Fatalf("provider Check calls = %v, want one", next.checked)
	}
}

func TestBypassInterceptsListedNumbers(t *testing.T) {
	next := &recordingSender{}
	s := newBypass(t, next)

	if err := s.Start(context.Background(), bypassed, Signals{}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if len(next.started) != 0 {
		t.Fatalf("provider was called for a bypassed number: %v", next.started)
	}

	if got, _ := s.Check(context.Background(), bypassed, "111111"); got != ResultApproved {
		t.Fatal("correct bypass code was denied")
	}
	if got, _ := s.Check(context.Background(), bypassed, "222222"); got != ResultDenied {
		t.Fatal("wrong bypass code was approved")
	}
	if len(next.checked) != 0 {
		t.Fatalf("provider was called for a bypassed number: %v", next.checked)
	}
}

// A provider failure has to keep reaching the caller — wrapping must not swallow
// the errors the handler maps to user-facing messages.
func TestBypassPropagatesProviderErrors(t *testing.T) {
	next := &recordingSender{err: ErrUndeliverable}
	s := newBypass(t, next)

	if err := s.Start(context.Background(), normal, Signals{}); !errors.Is(err, ErrUndeliverable) {
		t.Fatalf("Start error = %v, want ErrUndeliverable", err)
	}
}

// An empty list must return the provider itself, so production carries no
// bypass code at all rather than an inert wrapper holding one.
func TestBypassWithNoNumbersReturnsProvider(t *testing.T) {
	next := &recordingSender{}
	s, err := NewBypassSender(nil, "111111", next, zap.NewNop())
	if err != nil {
		t.Fatalf("NewBypassSender: %v", err)
	}
	if s != Sender(next) {
		t.Fatal("empty list did not return the wrapped sender unchanged")
	}
}

// The client sizes its entry field from this before any number is typed, so it
// must describe the provider rather than the bypass code.
func TestBypassReportsProviderCodeLength(t *testing.T) {
	s := newBypass(t, &recordingSender{})
	if s.CodeLength() != 6 {
		t.Fatalf("CodeLength = %d, want the provider's 6", s.CodeLength())
	}
}

func TestBypassRequiresSomethingToFallThroughTo(t *testing.T) {
	if _, err := NewBypassSender([]string{bypassed}, "111111", nil, zap.NewNop()); err == nil {
		t.Fatal("bypass with no wrapped sender = nil error, want error")
	}
}

// "*" is what a laptop runs on: any number the developer types is intercepted,
// so nothing is sent and Prelude's per-number limit never enters into it.
func TestBypassAllInterceptsEveryNumber(t *testing.T) {
	next := &recordingSender{result: ResultApproved}
	s, err := NewBypassSender([]string{BypassAll}, "111111", next, zap.NewNop())
	if err != nil {
		t.Fatalf("NewBypassSender: %v", err)
	}

	if err := s.Start(context.Background(), normal, Signals{}); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if got, _ := s.Check(context.Background(), normal, "111111"); got != ResultApproved {
		t.Fatalf("Check with the dev code = %v, want approved", got)
	}
	// Still the bypass code and not "any code" — a wrong one has to fail, or the
	// code screen can't be tested at all.
	if got, _ := s.Check(context.Background(), normal, "999999"); got != ResultDenied {
		t.Fatalf("Check with a wrong code = %v, want denied", got)
	}

	if len(next.started) != 0 || len(next.checked) != 0 {
		t.Fatalf("provider was contacted: started=%v checked=%v", next.started, next.checked)
	}
}
