package llm

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	"github.com/google/uuid"
	"go.uber.org/zap"
)

// fakeStore records what the runner wrote, and can be made to fail.
type fakeStore struct {
	runs      []db.RecordLLMRunParams
	count     int64
	countErr  error
	recordErr error
}

func (f *fakeStore) RecordLLMRun(_ context.Context, arg db.RecordLLMRunParams) (db.LlmRun, error) {
	f.runs = append(f.runs, arg)
	if f.recordErr != nil {
		return db.LlmRun{}, f.recordErr
	}
	return db.LlmRun{}, nil
}

func (f *fakeStore) CountLLMRunsForUser(_ context.Context, _ db.CountLLMRunsForUserParams) (int64, error) {
	return f.count, f.countErr
}

// scriptedProvider returns the next scripted outcome on each call.
type scriptedProvider struct {
	results []scriptedResult
	calls   int
	delay   time.Duration
}

type scriptedResult struct {
	usage Usage
	err   error
}

func (p *scriptedProvider) Name() string { return "scripted" }

func (p *scriptedProvider) Identify(ctx context.Context, _ IdentifyInput) (IdentifiedItem, Usage, error) {
	if p.delay > 0 {
		select {
		case <-ctx.Done():
			return IdentifiedItem{}, Usage{}, ctx.Err()
		case <-time.After(p.delay):
		}
	}
	r := p.results[min(p.calls, len(p.results)-1)]
	p.calls++
	return IdentifiedItem{Name: "thing"}, r.usage, r.err
}

func (p *scriptedProvider) Price(context.Context, PriceInput) (PricedItem, Usage, error) {
	return PricedItem{}, Usage{}, nil
}

func newTestRunner(t *testing.T, p Provider, s Store, cfg Config) *Runner {
	t.Helper()
	if cfg.Window == 0 {
		cfg.Window = time.Hour
	}
	if cfg.Timeout == 0 {
		cfg.Timeout = time.Second
	}
	return NewRunner(p, s, zap.NewNop(), cfg)
}

func i32(v int32) *int32 { return &v }

func TestRecordsUsageOnSuccess(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{{
		usage: Usage{InputTokens: i32(1840), OutputTokens: i32(120), Model: "served-model-v2"},
	}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 2})

	checkID := uuid.New()
	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New(), PriceCheckID: &checkID}, IdentifyInput{}); err != nil {
		t.Fatalf("Identify: %v", err)
	}

	if len(store.runs) != 1 {
		t.Fatalf("recorded %d runs, want 1", len(store.runs))
	}
	run := store.runs[0]
	if run.Status != db.LlmRunStatusOK {
		t.Errorf("status = %v, want OK", run.Status)
	}
	if run.ErrorCode != nil {
		t.Errorf("error_code = %v, want nil on success", *run.ErrorCode)
	}
	if run.Stage != db.LlmRunStageIDENTIFY {
		t.Errorf("stage = %v, want IDENTIFY", run.Stage)
	}
	if run.Attempt != 1 {
		t.Errorf("attempt = %d, want 1", run.Attempt)
	}
	// The served model, not the configured one — that is what was billed.
	if run.Model != "served-model-v2" {
		t.Errorf("model = %q, want the model the provider reported", run.Model)
	}
	if run.InputTokens == nil || *run.InputTokens != 1840 {
		t.Errorf("input_tokens = %v, want 1840", run.InputTokens)
	}
	if run.CachedInputTokens != nil {
		t.Errorf("cached_input_tokens = %v, want nil when unreported", *run.CachedInputTokens)
	}
	if run.PriceCheckID == nil || *run.PriceCheckID != checkID {
		t.Errorf("price_check_id = %v, want %v", run.PriceCheckID, checkID)
	}
}

// A retried call is two rows, not one. The provider is paid for both, so a
// table that recorded only the successful attempt would report a number below
// the invoice — which is the failure this table exists to prevent.
func TestRetryRecordsEveryAttempt(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{
		{err: Errorf(ErrorCodeUnavailable, "boom")},
		{usage: Usage{InputTokens: i32(10), Model: "m"}},
	}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 2})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err != nil {
		t.Fatalf("Identify: %v", err)
	}

	if len(store.runs) != 2 {
		t.Fatalf("recorded %d runs, want 2 (the failure and the retry)", len(store.runs))
	}
	if store.runs[0].Status != db.LlmRunStatusERROR || store.runs[0].Attempt != 1 {
		t.Errorf("first row = %v attempt %d, want ERROR attempt 1", store.runs[0].Status, store.runs[0].Attempt)
	}
	if store.runs[0].ErrorCode == nil || *store.runs[0].ErrorCode != "unavailable" {
		t.Errorf("first row error_code = %v, want unavailable", store.runs[0].ErrorCode)
	}
	if store.runs[1].Status != db.LlmRunStatusOK || store.runs[1].Attempt != 2 {
		t.Errorf("second row = %v attempt %d, want OK attempt 2", store.runs[1].Status, store.runs[1].Attempt)
	}
}

// A safety refusal is a decision about the input, so a second identical call
// gets the same answer. Retrying it spends money to be told no twice.
func TestRefusalIsNotRetried(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{{err: Errorf(ErrorCodeRefused, "declined")}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 3})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err == nil {
		t.Fatal("Identify: want error")
	}
	if provider.calls != 1 {
		t.Errorf("provider called %d times, want 1", provider.calls)
	}
	if len(store.runs) != 1 {
		t.Errorf("recorded %d runs, want 1", len(store.runs))
	}
}

// A 400 is our request being wrong, so every retry buys the identical 400 —
// twice the latency and twice the rows for the same answer. Alongside
// TestRefusalIsNotRetried because they are the two non-retryable codes and they
// stop for opposite reasons: that one is a decision, this one is a bug.
func TestBadRequestIsNotRetried(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{{err: Errorf(ErrorCodeBadRequest, "schema rejected")}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 3})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err == nil {
		t.Fatal("Identify: want error")
	}
	if provider.calls != 1 {
		t.Errorf("provider called %d times, want 1", provider.calls)
	}
	if len(store.runs) != 1 {
		t.Fatalf("recorded %d runs, want 1", len(store.runs))
	}
	if got := store.runs[0].ErrorCode; got == nil || *got != string(ErrorCodeBadRequest) {
		t.Errorf("error_code = %v, want bad_request", got)
	}
}

func TestCeilingRefusesBeforeCallingProvider(t *testing.T) {
	store := &fakeStore{count: 60}
	provider := &scriptedProvider{results: []scriptedResult{{}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 60, MaxAttempts: 2})

	_, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{})
	if !errors.Is(err, ErrCeilingReached) {
		t.Fatalf("err = %v, want ErrCeilingReached", err)
	}
	if provider.calls != 0 {
		t.Errorf("provider called %d times, want 0 — the ceiling has to bite before the spend", provider.calls)
	}
	if len(store.runs) != 0 {
		t.Errorf("recorded %d runs, want 0 — a refused call is not a call", len(store.runs))
	}
}

// Failing closed. A counting query that errors means the database is
// unreachable, in which case the price check row could not have been written
// either.
func TestCeilingFailsClosed(t *testing.T) {
	store := &fakeStore{countErr: errors.New("connection refused")}
	provider := &scriptedProvider{results: []scriptedResult{{}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 1})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err == nil {
		t.Fatal("want error when the ceiling cannot be counted")
	}
	if provider.calls != 0 {
		t.Errorf("provider called %d times, want 0", provider.calls)
	}
}

// The provider has already been paid by the time the insert runs. Throwing the
// answer away because bookkeeping failed turns a logging problem into a
// user-visible one.
func TestRecordFailureDoesNotFailTheCall(t *testing.T) {
	store := &fakeStore{recordErr: errors.New("insert failed")}
	provider := &scriptedProvider{results: []scriptedResult{{usage: Usage{Model: "m"}}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 1})

	item, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}
	if item.Name != "thing" {
		t.Errorf("item.Name = %q, want the provider's answer", item.Name)
	}
}

// A provider that hangs is recorded as a timeout even if it reports the
// cancellation some other way, because the deadline is the fact.
func TestTimeoutIsRecordedAsTimeout(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{{}}, delay: 50 * time.Millisecond}
	runner := newTestRunner(t, provider, store, Config{
		MaxCallsPerUser: 10, MaxAttempts: 1, Timeout: 5 * time.Millisecond,
	})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err == nil {
		t.Fatal("want a timeout error")
	}
	if len(store.runs) != 1 {
		t.Fatalf("recorded %d runs, want 1 — a timed-out call still cost something", len(store.runs))
	}
	if store.runs[0].ErrorCode == nil || *store.runs[0].ErrorCode != "timeout" {
		t.Errorf("error_code = %v, want timeout", store.runs[0].ErrorCode)
	}
}

// An unclassified error is still recorded, as "unknown". A nil error_code on a
// failed row would read as success.
func TestUnclassifiedErrorRecordsUnknown(t *testing.T) {
	store := &fakeStore{}
	provider := &scriptedProvider{results: []scriptedResult{{err: errors.New("something odd")}}}
	runner := newTestRunner(t, provider, store, Config{MaxCallsPerUser: 10, MaxAttempts: 1})

	if _, err := runner.Identify(context.Background(), Subject{UserID: uuid.New()}, IdentifyInput{}); err == nil {
		t.Fatal("want error")
	}
	if store.runs[0].ErrorCode == nil || *store.runs[0].ErrorCode != "unknown" {
		t.Errorf("error_code = %v, want unknown", store.runs[0].ErrorCode)
	}
}

func TestStubSearchTermDropsFiller(t *testing.T) {
	got := stubSearchTerm("A white IKEA Malm dresser, six drawers, barely used, from a pet-free home")
	want := "white ikea malm dresser"
	if got != want {
		t.Errorf("stubSearchTerm = %q, want %q", got, want)
	}
}

// The stub is the default dev provider and it cannot see, so a photo-only run
// would otherwise hand the phone an empty query — which is not a weak search,
// it is a search for the whole marketplace. It has to answer with something
// real, and it has to say the answer is a placeholder.
func TestStubPhotoOnlyRunReturnsAQueryAndAdmitsItGuessed(t *testing.T) {
	item, _, err := StubProvider{}.Identify(context.Background(), IdentifyInput{
		Photos: []Photo{{Data: []byte{0xff, 0xd8}, MediaType: "image/jpeg"}},
	})
	if err != nil {
		t.Fatalf("Identify: %v", err)
	}
	if item.Name == "" || len(item.SearchQueries) == 0 || item.SearchQueries[0] == "" {
		t.Fatalf("photo-only stub gave nothing to search: %+v", item)
	}
	var admits bool
	for _, attr := range item.KeyAttributes {
		if strings.Contains(attr, "cannot see") {
			admits = true
		}
	}
	if !admits {
		t.Error("the stub should say the name is a placeholder, not look like it read the photo")
	}
}

func TestStubPricesAtTheMedian(t *testing.T) {
	item, _, err := StubProvider{}.Price(context.Background(), PriceInput{
		Item:  IdentifiedItem{Name: "Dresser"},
		Stats: MarketStats{MedianMinor: 7700, PricedCount: 14},
	})
	if err != nil {
		t.Fatalf("Price: %v", err)
	}
	if item.PriceMinor != 7700 {
		t.Errorf("PriceMinor = %d, want the median 7700", item.PriceMinor)
	}
}
