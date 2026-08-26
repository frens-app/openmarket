package ingest

import (
	"context"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgtype"
	"github.com/jackc/pgx/v5/pgxpool"
	"go.uber.org/zap"
	"google.golang.org/protobuf/encoding/protojson"
)

// The two ways a batch is refused before anything is stored. Both are about
// observed_at, which is the one claim the server cannot verify and can only
// bound: it has no way to tell a live read from a replayed one.
var (
	ErrObservedInFuture = errors.New("observed_at is ahead of this server's clock")
	ErrObservationStale = errors.New("observed_at is older than this service accepts")
)

type Limits struct {
	MaxObservationAge time.Duration
	MaxClockSkew      time.Duration
	// How far back to look for a second submitter when an observation proposes
	// moving availability backwards.
	CorroborationWindow time.Duration
	// Window the circuit breaker's quarantine rate is measured over.
	BreakerWindow time.Duration
	// How far back to look before calling a payload shape new. Longer than the
	// breaker window: a shape that appeared once a fortnight ago is not news.
	ShapeWindow time.Duration
}

// Submission is one ingest call, with the parts the transport already knows.
// The device comes from the authenticated session and never from the request
// body: a client that could name its own device could name someone else's.
type Submission struct {
	DeviceID   uuid.UUID
	AppVersion string
	AppBuild   string
	Request    *v1.SubmitObservationsRequest
}

type Service struct {
	pool    *pgxpool.Pool
	queries *db.Queries
	keyring *Keyring
	breaker Breaker
	limits  Limits
	logger  *zap.Logger
	now     func() time.Time
}

func NewService(
	pool *pgxpool.Pool,
	queries *db.Queries,
	keyring *Keyring,
	breaker Breaker,
	limits Limits,
	logger *zap.Logger,
) *Service {
	return &Service{
		pool:    pool,
		queries: queries,
		keyring: keyring,
		breaker: breaker,
		limits:  limits,
		logger:  logger,
		now:     time.Now,
	}
}

// Submit validates, attributes and merges one batch, in one transaction.
//
// One transaction because the batch row is the provenance for every listing
// row it moved. A partial commit would leave canonical listings pointing at a
// batch whose counts say something else, and the counts are how a Facebook
// change is noticed.
func (s *Service) Submit(ctx context.Context, in Submission) (*v1.SubmitObservationsResponse, error) {
	req := in.Request
	now := s.now()
	observedAt := req.GetContext().GetObservedAt().AsTime()

	if observedAt.After(now.Add(s.limits.MaxClockSkew)) {
		return nil, ErrObservedInFuture
	}
	if now.Sub(observedAt) > s.limits.MaxObservationAge {
		return nil, ErrObservationStale
	}

	candidates, rejections := Validate(req, observedAt)

	submitterID, epoch, err := s.keyring.SubmitterID(ctx, in.DeviceID, now)
	if err != nil {
		return nil, err
	}
	reputation, err := s.queries.GetOrCreateDeviceReputation(ctx, in.DeviceID)
	if err != nil {
		return nil, fmt.Errorf("device reputation: %w", err)
	}

	src := source{
		route:  req.GetContext().GetPageRoute(),
		method: req.GetContext().GetExtractionMethod(),
		auth:   req.GetContext().GetFacebookAuthenticationState(),
	}
	suspended, err := s.sourceSuspended(ctx, req)
	if err != nil {
		return nil, err
	}
	s.warnOnNewShape(ctx, req)

	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, fmt.Errorf("begin: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.queries.WithTx(tx)

	batch, err := q.CreateObservationBatch(ctx, db.CreateObservationBatchParams{
		ObservedAt:                  timestamp(observedAt),
		SubmitterID:                 submitterID,
		Epoch:                       pgtype.Date{Time: epoch, Valid: true},
		SubmitterTrust:              reputation.Tier,
		FacebookBrowserVariant:      req.GetContext().GetBrowserVariant().String(),
		FacebookPageRoute:           req.GetContext().GetPageRoute().String(),
		ExtractionMethod:            req.GetContext().GetExtractionMethod().String(),
		FacebookAuthenticationState: req.GetContext().GetFacebookAuthenticationState().String(),
		ExtractorRevision:           req.GetExtractorRevision(),
		AppVersion:                  optional(in.AppVersion),
		AppBuild:                    optional(in.AppBuild),
		ShapeFingerprint:            req.GetShapeFingerprint(),
		CardsSeen:                   cardsSeen(req),
		CardsSubmitted:              int32(len(req.GetObservations())),
		ClientDropReasons:           dropReasons(req),
		Suspended:                   suspended,
	})
	if err != nil {
		return nil, fmt.Errorf("create batch: %w", err)
	}

	accepted, conflicts := 0, 0
	if suspended {
		// Nothing was wrong with these cards. The surface they came from is
		// producing garbage at a rate that says the extractor no longer matches
		// the page, so the batch is kept for diagnosis and merged into nothing.
		for _, c := range candidates {
			rejections = append(rejections, Rejection{
				Index:  c.Index,
				Reason: v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_SOURCE_SUSPENDED,
			})
		}
	} else {
		for _, c := range candidates {
			conflict, err := s.apply(ctx, q, batch, c, src, observedAt, epoch)
			if err != nil {
				return nil, err
			}
			if conflict != nil {
				rejections = append(rejections, *conflict)
				conflicts++
				continue
			}
			accepted++
		}
	}

	for _, r := range rejections {
		payload, err := marshalObservation(req.GetObservations(), r.Index)
		if err != nil {
			return nil, err
		}
		if err := q.InsertObservationQuarantine(ctx, db.InsertObservationQuarantineParams{
			BatchID:          batch.ID,
			ObservationIndex: int32(r.Index),
			Reason:           rejectionReason(r.Reason),
			FieldPath:        r.FieldPath,
			Payload:          payload,
		}); err != nil {
			return nil, fmt.Errorf("quarantine: %w", err)
		}
	}

	if err := q.FinalizeObservationBatch(ctx, db.FinalizeObservationBatchParams{
		ID:               batch.ID,
		CardsAccepted:    int32(accepted),
		CardsQuarantined: int32(len(rejections)),
	}); err != nil {
		return nil, fmt.Errorf("finalize batch: %w", err)
	}
	if err := q.RecordBatchOutcome(ctx, db.RecordBatchOutcomeParams{
		DeviceID:    in.DeviceID,
		Accepted:    int64(accepted),
		Quarantined: int64(len(rejections)),
		Conflicts:   int64(conflicts),
	}); err != nil {
		return nil, fmt.Errorf("record outcome: %w", err)
	}
	// The volume half of the split: an install id and a count, with no listing
	// ids anywhere near it.
	if _, err := q.BumpDeviceActivity(ctx, db.BumpDeviceActivityParams{
		DeviceID: in.DeviceID,
		Cards:    int32(len(req.GetObservations())),
	}); err != nil {
		return nil, fmt.Errorf("device activity: %w", err)
	}

	if err := tx.Commit(ctx); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}

	return &v1.SubmitObservationsResponse{
		BatchId:         batch.ID.String(),
		Accepted:        int32(accepted),
		Quarantined:     int32(len(rejections)),
		Rejections:      protoRejections(rejections),
		SourceSuspended: suspended,
	}, nil
}

// sourceSuspended asks the breaker about this browser variant, route, method
// and extractor revision.
func (s *Service) sourceSuspended(ctx context.Context, req *v1.SubmitObservationsRequest) (bool, error) {
	health, err := s.queries.GetSourceHealth(ctx, db.GetSourceHealthParams{
		BrowserVariant:    req.GetContext().GetBrowserVariant().String(),
		PageRoute:         req.GetContext().GetPageRoute().String(),
		ExtractionMethod:  req.GetContext().GetExtractionMethod().String(),
		ExtractorRevision: req.GetExtractorRevision(),
		Window:            interval(s.limits.BreakerWindow),
	})
	if err != nil {
		return false, fmt.Errorf("source health: %w", err)
	}
	return s.breaker.Open(health.Submitted, health.Quarantined), nil
}

// warnOnNewShape says so when a structured payload arrives with a set of key
// paths this surface has not produced before.
//
// The expensive failures are the silent ones. `DOOR_DROPOFF` was found by a
// person reading a log line and noticing a token that should not have been
// there (docs/parsing-conventions.md §1); this is that person, running on every
// batch. It fires whether or not anything failed to parse, which is the point —
// a change that still parses is the one nobody notices.
//
// Best effort, and never fatal. A batch is not worth refusing because the
// lookup behind a warning failed.
func (s *Service) warnOnNewShape(ctx context.Context, req *v1.SubmitObservationsRequest) {
	fingerprint := req.GetShapeFingerprint()
	if len(fingerprint) == 0 {
		return
	}
	seen, err := s.queries.CountBatchesWithShapeFingerprint(ctx, db.CountBatchesWithShapeFingerprintParams{
		BrowserVariant:   req.GetContext().GetBrowserVariant().String(),
		PageRoute:        req.GetContext().GetPageRoute().String(),
		ExtractionMethod: req.GetContext().GetExtractionMethod().String(),
		ShapeFingerprint: fingerprint,
		Window:           interval(s.limits.ShapeWindow),
	})
	if err != nil {
		s.logger.Warn("shape fingerprint lookup", zap.Error(err))
		return
	}
	if seen > 0 {
		return
	}
	s.logger.Warn("unseen payload shape",
		zap.String("fingerprint", hex.EncodeToString(fingerprint)),
		zap.String("variant", req.GetContext().GetBrowserVariant().String()),
		zap.String("route", req.GetContext().GetPageRoute().String()),
		zap.String("method", req.GetContext().GetExtractionMethod().String()),
		zap.String("extractor", req.GetExtractorRevision()),
	)
}

func cardsSeen(req *v1.SubmitObservationsRequest) int32 {
	seen := req.GetCounts().GetCardsSeen()
	// The client is the only witness to what it dropped, so a count below what
	// it sent is a client bug rather than a fact. Clamping keeps the batch's
	// CHECK satisfiable without inventing a drop that did not happen.
	if submitted := int32(len(req.GetObservations())); seen < submitted {
		return submitted
	}
	return seen
}

// dropReasons never returns nil. The column is NOT NULL because "the client
// reported no drops" and "the client did not report" are the same thing here —
// an empty array — and a nullable column would invite a third reading.
func dropReasons(req *v1.SubmitObservationsRequest) []string {
	if reasons := req.GetCounts().GetDropReasons(); reasons != nil {
		return reasons
	}
	return []string{}
}

func optional(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func interval(d time.Duration) pgtype.Interval {
	return pgtype.Interval{Microseconds: d.Microseconds(), Valid: true}
}

func marshalObservation(observations []*v1.FacebookMarketplaceListingObservation, index int) ([]byte, error) {
	if index < 0 || index >= len(observations) {
		return []byte("null"), nil
	}
	// Presence is preserved: an absent optional stays absent rather than
	// appearing as a zero. An observation that cannot distinguish "not supplied
	// by this surface" from "supplied as empty" is not evidence of anything.
	out, err := protojson.Marshal(observations[index])
	if err != nil {
		return nil, fmt.Errorf("marshal observation: %w", err)
	}
	return out, nil
}

func protoRejections(rejections []Rejection) []*v1.ObservationRejection {
	out := make([]*v1.ObservationRejection, 0, len(rejections))
	for _, r := range rejections {
		out = append(out, &v1.ObservationRejection{
			Index:     int32(r.Index),
			Reason:    r.Reason,
			FieldPath: r.FieldPath,
		})
	}
	return out
}

var rejectionReasons = map[v1.ObservationRejectionReason]db.ObservationRejectionReason{
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_MALFORMED_FIELD:      db.ObservationRejectionReasonMalformedField,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_IMPLAUSIBLE_VALUE:    db.ObservationRejectionReasonImplausibleValue,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_CONTRADICTORY_FIELDS: db.ObservationRejectionReasonContradictoryFields,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_KEY_COLLISION:        db.ObservationRejectionReasonKeyCollision,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ROUTE_MISMATCH:       db.ObservationRejectionReasonRouteMismatch,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ORIGIN_CONFLICT:      db.ObservationRejectionReasonOriginConflict,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_ALIAS_CONFLICT:       db.ObservationRejectionReasonAliasConflict,
	v1.ObservationRejectionReason_OBSERVATION_REJECTION_REASON_SOURCE_SUSPENDED:     db.ObservationRejectionReasonSourceSuspended,
}

func rejectionReason(r v1.ObservationRejectionReason) db.ObservationRejectionReason {
	if mapped, ok := rejectionReasons[r]; ok {
		return mapped
	}
	return db.ObservationRejectionReasonMalformedField
}
