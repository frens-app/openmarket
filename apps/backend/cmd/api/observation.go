package main

import (
	"context"
	"errors"
	"fmt"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/ingest"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"
)

// The client build, carried as metadata rather than as request fields.
//
// It describes the caller and not the observation, so putting it in the message
// would mean every batch restating it and the schema implying we trust it as
// data. Read here, attached to the batch by the server, and absent is fine.
const (
	headerAppVersion = "X-Openmarket-App-Version"
	headerAppBuild   = "X-Openmarket-App-Build"
)

// observationServer is the ingest boundary for Facebook Marketplace data.
//
// The device is taken from the session, never from the body. That is what makes
// the pseudonym on the stored batch mean anything: a client that could name its
// own install could name somebody else's, and every trust signal built on top
// would be a client-supplied number.
type observationServer struct {
	queries *db.Queries
	ingest  *ingest.Service
	builds  ingest.BuildPolicy
	logger  *zap.Logger
}

func (s *observationServer) SubmitObservations(
	ctx context.Context,
	req *connect.Request[v1.SubmitObservationsRequest],
) (*connect.Response[v1.SubmitObservationsResponse], error) {
	appVersion := req.Header().Get(headerAppVersion)
	appBuild := req.Header().Get(headerAppBuild)

	// Before the session lookup and before anything is written. A refused build
	// costs one rejected call and leaves no batch row, no observation and no
	// quarantine entry — the data is thrown out rather than filed.
	if !s.builds.Allows(appBuild) {
		s.logger.Info("refused build",
			zap.String("app_build", appBuild),
			zap.String("app_version", appVersion),
			zap.String("extractor", req.Msg.GetExtractorRevision()),
		)
		return nil, connect.NewError(connect.CodeFailedPrecondition,
			errors.New("this build's observations are not accepted; update the app"))
	}

	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Unlike a price check, an unattributable observation is not worth keeping.
	// Trust scoring, corroboration and rate limiting all need a submitter, and
	// accepting data without one is exactly the shape this ingest path exists
	// to avoid.
	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeFailedPrecondition,
				errors.New("this session has no registered device; sign in again"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("device for session: %w", err))
	}

	resp, err := s.ingest.Submit(ctx, ingest.Submission{
		DeviceID:   device.ID,
		AppVersion: appVersion,
		AppBuild:   appBuild,
		Request:    req.Msg,
	})
	switch {
	case errors.Is(err, ingest.ErrObservedInFuture), errors.Is(err, ingest.ErrObservationStale):
		// A client bug rather than an incident: the batch claims a capture time
		// this server will not vouch for, and the fix is on the client.
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	case err != nil:
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// One line per batch, and no card content in it. These four numbers are how
	// a Facebook change is noticed: cards_seen far above submitted is the client
	// dropping, quarantined far above zero is the server refusing.
	s.logger.Info("observation batch",
		zap.String("batch_id", resp.GetBatchId()),
		zap.String("route", req.Msg.GetContext().GetPageRoute().String()),
		zap.String("extractor", req.Msg.GetExtractorRevision()),
		zap.Int32("seen", req.Msg.GetCounts().GetCardsSeen()),
		zap.Int("submitted", len(req.Msg.GetObservations())),
		zap.Int32("accepted", resp.GetAccepted()),
		zap.Int32("quarantined", resp.GetQuarantined()),
		zap.Bool("suspended", resp.GetSourceSuspended()),
	)

	return connect.NewResponse(resp), nil
}
