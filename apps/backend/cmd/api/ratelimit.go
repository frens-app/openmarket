package main

import (
	"context"
	"fmt"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	"github.com/jackc/pgx/v5/pgtype"
)

// sendCeiling is a circuit breaker on the verification bill.
//
// It is not a fairness mechanism and it is not per user. Prelude already
// limits sends per number and blocks pumping via Fraud Guard, and both are
// better than a local reimplementation — see migration 00002 for why this exists
// anyway, and why it counts nothing but sends.
type sendCeiling struct {
	queries *db.Queries
	max     int
	window  time.Duration
}

// errCeilingReached is returned when the window's budget is spent. It carries
// the window so the caller can tell the user roughly how long to wait.
type errCeilingReached struct {
	window time.Duration
}

func (e *errCeilingReached) Error() string {
	return fmt.Sprintf("verification send ceiling reached; retry in up to %s", e.window)
}

// allow counts the window and, if there is room, records the send.
//
// The record is written before the SMS is requested, not after. A send that
// fails still cost an API call, so making failures free would leave the cheapest
// way to burn the budget — hammering numbers the provider rejects — entirely
// unmetered.
func (c *sendCeiling) allow(ctx context.Context) error {
	count, err := c.queries.CountVerificationSends(ctx, interval(c.window))
	if err != nil {
		return fmt.Errorf("count verification sends: %w", err)
	}
	if count >= int64(c.max) {
		return &errCeilingReached{window: c.window}
	}
	if err := c.queries.RecordVerificationSend(ctx); err != nil {
		return fmt.Errorf("record verification send: %w", err)
	}
	return nil
}

// prune deletes rows past the counting window. Called on a timer from main; the
// table is pure counter state and nothing reads a row once its window closes.
func (c *sendCeiling) prune(ctx context.Context) error {
	return c.queries.PruneVerificationSends(ctx, interval(c.window*2))
}

func interval(d time.Duration) pgtype.Interval {
	return pgtype.Interval{Microseconds: d.Microseconds(), Valid: true}
}
