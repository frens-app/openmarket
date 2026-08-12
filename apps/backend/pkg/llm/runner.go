package llm

import (
	"context"
	"errors"
	"fmt"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"go.uber.org/zap"
)

// Store is the slice of the database this package touches.
//
// An interface rather than *db.Queries, matching activeSessionChecker in the
// auth interceptor: it says exactly which two queries a model call is allowed to
// reach, and it makes the runner testable without a database.
type Store interface {
	RecordLLMRun(context.Context, db.RecordLLMRunParams) (db.LlmRun, error)
	CountLLMRunsForUser(context.Context, db.CountLLMRunsForUserParams) (int64, error)
}

// ErrCeilingReached means this user has made too many model calls in the
// window. Distinct from a provider failure because the caller should say so
// plainly rather than offer a retry that will also be refused.
var ErrCeilingReached = errors.New("model call ceiling reached for this user")

// Subject is who a run is for and what it belongs to.
type Subject struct {
	UserID uuid.UUID
	// Nil for a call not tied to a price check. Nothing does that yet — the
	// column is nullable because this table will outlive being about one
	// feature, and because a spend record should survive its subject.
	PriceCheckID *uuid.UUID
}

// Runner calls the provider, times it, bounds it, and writes down what
// happened.
//
// The ordering of those verbs is the whole design: recording is not something a
// caller can forget to do, because the only way to reach the provider is
// through here.
type Runner struct {
	provider Provider
	store    Store
	logger   *zap.Logger

	// Per user, per window. Calls rather than money: there is no rate table
	// yet, and calls are the right unit for what this actually guards against
	// early on, which is a client stuck in a retry loop rather than a large
	// bill. SumLLMTokensForUser is the query it becomes later.
	maxCallsPerUser int
	window          time.Duration

	// Attempts for one logical call, not retries on top of it: 1 means no
	// retry. Each attempt is its own row.
	maxAttempts int
	timeout     time.Duration
}

// Config is what a Runner needs beyond its collaborators.
type Config struct {
	MaxCallsPerUser int
	Window          time.Duration
	MaxAttempts     int
	Timeout         time.Duration
}

func NewRunner(provider Provider, store Store, logger *zap.Logger, cfg Config) *Runner {
	if cfg.MaxAttempts < 1 {
		cfg.MaxAttempts = 1
	}
	return &Runner{
		provider:        provider,
		store:           store,
		logger:          logger,
		maxCallsPerUser: cfg.MaxCallsPerUser,
		window:          cfg.Window,
		maxAttempts:     cfg.MaxAttempts,
		timeout:         cfg.Timeout,
	}
}

// Provider names the configured vendor, for the handler's logs.
func (r *Runner) Provider() string { return r.provider.Name() }

// Identify runs the vision call — the only model call this feature makes.
func (r *Runner) Identify(ctx context.Context, sub Subject, in IdentifyInput) (IdentifiedItem, error) {
	return call(ctx, r, StageIdentify, sub, func(ctx context.Context) (IdentifiedItem, Usage, error) {
		return r.provider.Identify(ctx, in)
	})
}

// call is the whole of the bookkeeping, generic over what the stage returns.
//
// A package-level function rather than a method because Go has no generic
// methods; the two exported wrappers above are what callers see.
func call[T any](
	ctx context.Context,
	r *Runner,
	stage Stage,
	sub Subject,
	invoke func(context.Context) (T, Usage, error),
) (T, error) {
	var zero T

	if err := r.checkCeiling(ctx, sub.UserID); err != nil {
		return zero, err
	}

	var lastErr error
	for attempt := 1; attempt <= r.maxAttempts; attempt++ {
		attemptCtx, cancel := context.WithTimeout(ctx, r.timeout)
		started := time.Now()
		result, usage, err := invoke(attemptCtx)
		latency := time.Since(started)
		cancel()

		// A deadline that fired is a timeout however the provider described it,
		// and providers vary in whether they say so.
		code := CodeOf(err)
		if err != nil && errors.Is(attemptCtx.Err(), context.DeadlineExceeded) {
			code = ErrorCodeTimeout
		}

		r.record(ctx, stage, sub, attempt, usage, latency, err, code)

		if err == nil {
			return result, nil
		}
		lastErr = err

		// The caller hung up. Stop rather than spend another call on an answer
		// nobody is waiting for.
		if ctx.Err() != nil {
			break
		}
		if !retryable(code) || attempt == r.maxAttempts {
			break
		}

		// Short and linear. Somebody is watching a spinner, so this is a pause
		// to let a blip pass, not a backoff schedule for a batch job.
		select {
		case <-ctx.Done():
			return zero, ctx.Err()
		case <-time.After(time.Duration(attempt) * 250 * time.Millisecond):
		}
	}

	return zero, lastErr
}

// checkCeiling refuses a user who has made too many calls in the window.
//
// Fails closed: a counting query that errors means the database is unreachable,
// and the price check row this call belongs to could not have been written
// either — so the request was already going to fail, and guessing "probably
// under the limit" would only change which error it fails with.
func (r *Runner) checkCeiling(ctx context.Context, userID uuid.UUID) error {
	if r.maxCallsPerUser <= 0 {
		return nil
	}
	window, err := intervalOf(r.window)
	if err != nil {
		return err
	}
	count, err := r.store.CountLLMRunsForUser(ctx, db.CountLLMRunsForUserParams{
		UserID: userID,
		Window: window,
	})
	if err != nil {
		return fmt.Errorf("count model calls: %w", err)
	}
	if count >= int64(r.maxCallsPerUser) {
		return ErrCeilingReached
	}
	return nil
}

// record writes the run, including the failures.
//
// **A failure to record never fails the call.** By the time this runs the
// provider has already been paid and the answer is already in hand; throwing it
// away because a bookkeeping insert failed would turn a logging problem into a
// user-visible one. The log line is the fallback record.
//
// It uses the caller's context deliberately rather than the attempt's, which has
// been cancelled by now.
func (r *Runner) record(
	ctx context.Context,
	stage Stage,
	sub Subject,
	attempt int,
	usage Usage,
	latency time.Duration,
	callErr error,
	code ErrorCode,
) {
	status := db.LlmRunStatusOK
	var errorCode *string
	if callErr != nil {
		status = db.LlmRunStatusERROR
		c := string(code)
		errorCode = &c
	}

	// The model the provider served, falling back to nothing rather than to a
	// guess: an empty string in the column is visibly missing, where our
	// configured name would look authoritative and be wrong.
	model := usage.Model

	// The provider's own words, which the column cannot hold and the client
	// must not be shown. `error_code` says which kind of failure; only this
	// says which schema field, which model id, which key. Without it a failing
	// call leaves a row that names the category and nothing that names the
	// cause, and diagnosis means reconstructing the request by hand against the
	// live provider.
	if callErr != nil {
		r.logger.Warn("model call failed",
			zap.Error(callErr),
			zap.String("stage", string(stage)),
			zap.Int("attempt", attempt),
			zap.String("provider", r.provider.Name()),
			zap.String("model", model),
			zap.String("error_code", string(code)),
			zap.Int64("latency_ms", latency.Milliseconds()),
		)
	}

	if _, err := r.store.RecordLLMRun(ctx, db.RecordLLMRunParams{
		PriceCheckID:      sub.PriceCheckID,
		UserID:            sub.UserID,
		Stage:             db.LlmRunStage(stage),
		Attempt:           int32(attempt),
		Provider:          r.provider.Name(),
		Model:             model,
		InputTokens:       usage.InputTokens,
		OutputTokens:      usage.OutputTokens,
		ThoughtTokens:     usage.ThoughtTokens,
		CachedInputTokens: usage.CachedInputTokens,
		LatencyMs:         int32(latency.Milliseconds()),
		Status:            status,
		ErrorCode:         errorCode,
	}); err != nil {
		r.logger.Error("record model call",
			zap.Error(err),
			zap.String("stage", string(stage)),
			zap.Int("attempt", attempt),
			zap.String("provider", r.provider.Name()),
			zap.String("model", model),
			zap.Int64("latency_ms", latency.Milliseconds()),
			zap.String("status", string(status)),
		)
	}
}

// intervalOf converts a Go duration into the interval the count query takes.
func intervalOf(d time.Duration) (pgtype.Interval, error) {
	if d <= 0 {
		return pgtype.Interval{}, fmt.Errorf("model call window must be positive, got %s", d)
	}
	return pgtype.Interval{Microseconds: d.Microseconds(), Valid: true}, nil
}
