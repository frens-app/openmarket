package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
	"time"
	// Registered for their DecodeConfig side effects. Decoding the header is
	// what turns "some bytes" into known dimensions, and it doubles as the only
	// check that the client sent an image at all — a provider handed a
	// truncated upload answers with something confidently wrong rather than an
	// error, which is the worst of both.
	_ "image/jpeg"
	_ "image/png"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	"frens.lol/openmarket/backend/pkg/llm"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"go.uber.org/zap"
)

// pricingServer implements Price Check's half of the work.
//
// The other half is on the phone, and cannot move here: the comparable search
// runs in a WKWebView against the user's own Facebook session, so between
// IdentifyItem and PriceItem this service is not waiting on anything — it has
// returned, and the client comes back when it has a market.
//
// That is why the price check row is written by the first call rather than the
// second. A run that dies in between is a real outcome, and one worth being
// able to count.
type pricingServer struct {
	queries *db.Queries
	runner  *llm.Runner
	logger  *zap.Logger
}

func (s *pricingServer) IdentifyItem(
	ctx context.Context,
	req *connect.Request[v1.IdentifyItemRequest],
) (*connect.Response[v1.IdentifyItemResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	photos, meta, err := decodePhotos(req.Msg.GetPhotos())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}

	check, err := s.queries.CreatePriceCheck(ctx, db.CreatePriceCheckParams{
		UserID: userID,
		// Best effort: a session without a device row is possible (the column
		// is nullable, and a deleted device sets it null rather than taking the
		// session down). Losing which phone it came from is not worth failing a
		// price check over.
		DeviceID:    s.deviceIDForSession(ctx),
		Description: req.Msg.GetDescription(),
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create price check: %w", err))
	}

	// Logged and continued rather than returned. The photos are already decoded
	// and about to go to a model; failing the whole check because a metadata row
	// would not insert would throw away the answer to keep the footnote.
	for _, photo := range meta {
		if err := s.queries.AddPriceCheckPhoto(ctx, db.AddPriceCheckPhotoParams{
			PriceCheckID: check.ID,
			Ordinal:      photo.ordinal,
			Sha256:       photo.sha256,
			Bytes:        photo.byteCount,
			Width:        photo.width,
			Height:       photo.height,
		}); err != nil {
			s.logger.Warn("record price check photo",
				zap.Error(err),
				zap.String("price_check_id", check.ID.String()),
				zap.Int("ordinal", int(photo.ordinal)),
			)
		}
	}

	item, err := s.runner.Identify(ctx, llm.Subject{UserID: userID, PriceCheckID: &check.ID},
		llm.IdentifyInput{Description: req.Msg.GetDescription(), Photos: photos})
	if err != nil {
		return nil, modelError(err, "identify item")
	}

	if _, err := s.queries.SetPriceCheckIdentification(ctx, db.SetPriceCheckIdentificationParams{
		ID:                 check.ID,
		UserID:             userID,
		IdentifiedName:     item.Name,
		SearchQueries:      item.SearchQueries,
		ListingTitle:       item.ListingTitle,
		ListingDescription: item.ListingBody,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("record identification: %w", err))
	}

	return connect.NewResponse(&v1.IdentifyItemResponse{
		PriceCheckId:       check.ID.String(),
		IdentifiedName:     item.Name,
		SearchQueries:      item.SearchQueries,
		KeyAttributes:      item.KeyAttributes,
		ListingTitle:       item.ListingTitle,
		ListingDescription: item.ListingBody,
	}), nil
}

// CompletePriceCheck writes down what the device found. It calls no model.
//
// The clamp that used to live here is gone with the call it guarded: it existed
// because a model picked the price and a model can pick a number outside its own
// evidence. `PriceGuide` picks the median of the prices it was given, which is
// inside the range by construction. Clamping a median to the range it came from
// would be theatre.
//
// What is checked instead is that there was a market at all. A zero `stats`
// message deserializes into a market of nothing, and a "median of no prices"
// is the shape of a number with nothing behind it.
func (s *pricingServer) CompletePriceCheck(
	ctx context.Context,
	req *connect.Request[v1.CompletePriceCheckRequest],
) (*connect.Response[v1.CompletePriceCheckResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	checkID, err := uuid.Parse(req.Msg.GetPriceCheckId())
	if err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, fmt.Errorf("price_check_id: %w", err))
	}

	// Matched on the user as well as the id, so naming somebody else's price
	// check is a NotFound rather than a way to read it.
	check, err := s.queries.GetPriceCheck(ctx, db.GetPriceCheckParams{ID: checkID, UserID: userID})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, connect.NewError(connect.CodeNotFound, errors.New("price check not found"))
		}
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("load price check: %w", err))
	}

	stats := req.Msg.GetStats()
	if stats.GetPricedCount() <= 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument,
			errors.New("stats.priced_count must be positive; there is no market to record"))
	}

	price := req.Msg.GetRecommendedPriceMinor()
	median := stats.GetMedianMinor()
	currency := stats.GetCurrencySymbol()

	if _, err := s.queries.CompletePriceCheck(ctx, db.CompletePriceCheckParams{
		ID:                    check.ID,
		UserID:                userID,
		SearchQueryUsed:       req.Msg.GetSearchQueryUsed(),
		CompsFound:            req.Msg.GetCompsFound(),
		SoldFound:             stats.GetSoldCount(),
		RecommendedPriceMinor: &price,
		MedianPriceMinor:      &median,
		CurrencySymbol:        &currency,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("complete price check: %w", err))
	}

	return connect.NewResponse(&v1.CompletePriceCheckResponse{}), nil
}

func (s *pricingServer) SubmitPriceCheckFeedback(
	ctx context.Context,
	req *connect.Request[v1.SubmitPriceCheckFeedbackRequest],
) (*connect.Response[v1.SubmitPriceCheckFeedbackResponse], error) {
	userID, checkID, err := subjectOf(ctx, req.Msg.GetPriceCheckId())
	if err != nil {
		return nil, err
	}

	helpful := req.Msg.GetHelpful()
	if _, err := s.queries.SetPriceCheckHelpful(ctx, db.SetPriceCheckHelpfulParams{
		ID:      checkID,
		UserID:  userID,
		Helpful: &helpful,
	}); err != nil {
		return nil, notFoundOrInternalCheck(err, "record feedback")
	}

	s.logger.Info("price check feedback",
		zap.String("price_check_id", checkID.String()),
		zap.Bool("helpful", helpful),
	)
	return connect.NewResponse(&v1.SubmitPriceCheckFeedbackResponse{}), nil
}

// RecordPriceCheckCopy is the signal that costs the user nothing to give.
//
// Copying is the action immediately before pasting into Facebook, so it is
// about as close to "this worked" as anything observable gets — and it arrives
// from everybody, where the feedback buttons are answered by the minority who
// stop to tap one.
//
// What it carries is what was *taken*, beside what was offered: a price that
// may have been stepped, and listing copy that may have been rewritten. See
// migration 00008 for why those are separate columns rather than an overwrite.
func (s *pricingServer) RecordPriceCheckCopy(
	ctx context.Context,
	req *connect.Request[v1.RecordPriceCheckCopyRequest],
) (*connect.Response[v1.RecordPriceCheckCopyResponse], error) {
	userID, checkID, err := subjectOf(ctx, req.Msg.GetPriceCheckId())
	if err != nil {
		return nil, err
	}

	// Every field passed through as-is, nil included: the query only overwrites
	// where there is something to overwrite with, so a call reporting one copy
	// leaves the other two columns alone.
	if _, err := s.queries.RecordPriceCheckCopy(ctx, db.RecordPriceCheckCopyParams{
		ID:                       checkID,
		UserID:                   userID,
		CopiedPriceMinor:         req.Msg.CopiedPriceMinor,
		CopiedListingTitle:       req.Msg.CopiedListingTitle,
		CopiedListingDescription: req.Msg.CopiedListingDescription,
	}); err != nil {
		return nil, notFoundOrInternalCheck(err, "record price check copy")
	}
	return connect.NewResponse(&v1.RecordPriceCheckCopyResponse{}), nil
}

// ListPriceChecks hands back the rows this user has already made.
//
// No model, no market, no new storage: `CreatePriceCheck` has written a row on
// every run since this feature existed, specifically so a run that fails is
// still countable. Reading them back is what turns that into a history the
// seller can see.
func (s *pricingServer) ListPriceChecks(
	ctx context.Context,
	req *connect.Request[v1.ListPriceChecksRequest],
) (*connect.Response[v1.ListPriceChecksResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}

	// Clamped rather than trusted, and defaulted rather than refused: the field
	// is a hint from a screen, and a client that sends 0 wants the sensible
	// number rather than an error about it.
	limit := req.Msg.GetLimit()
	if limit <= 0 {
		limit = defaultPriceCheckPage
	}
	limit = min(limit, maxPriceCheckPage)

	rows, err := s.queries.ListPriceChecks(ctx, db.ListPriceChecksParams{UserID: userID, Limit: limit})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list price checks: %w", err))
	}

	checks := make([]*v1.PriceCheckSummary, 0, len(rows))
	for _, row := range rows {
		checks = append(checks, priceCheckSummary(row))
	}
	return connect.NewResponse(&v1.ListPriceChecksResponse{Checks: checks}), nil
}

const (
	defaultPriceCheckPage = 20
	maxPriceCheckPage     = 50
)

// priceCheckSummary is the row as the seller's own history, which is not quite
// the row as the table holds it.
//
// The listing fields prefer what was copied over what was generated. Both
// columns exist because the gap between them is the only real measure of
// quality this feature has (migration 00008) — but that is a question for a
// query, not for the person who rewrote the title. What they get back is what
// they wrote.
func priceCheckSummary(row db.PriceCheck) *v1.PriceCheckSummary {
	summary := &v1.PriceCheckSummary{
		PriceCheckId:          row.ID.String(),
		IdentifiedName:        derefString(row.IdentifiedName),
		Description:           row.Description,
		RecommendedPriceMinor: row.RecommendedPriceMinor,
		CurrencySymbol:        derefString(row.CurrencySymbol),
		CompsFound:            derefInt32(row.CompsFound),
		SoldFound:             derefInt32(row.SoldFound),
		SearchQueryUsed:       derefString(row.SearchQueryUsed),
		ListingTitle:          preferring(row.CopiedListingTitle, row.ListingTitle),
		ListingDescription:    preferring(row.CopiedListingDescription, row.ListingDescription),
	}
	if row.CreatedAt.Valid {
		summary.CreatedAt = row.CreatedAt.Time.UTC().Format(time.RFC3339)
	}
	return summary
}

// preferring returns the first of the two that was actually written.
//
// Empty counts as written: a seller who cleared the title and copied that meant
// it, and falling through to the generated one would put words back that they
// deleted.
func preferring(chosen, generated *string) string {
	if chosen != nil {
		return *chosen
	}
	return derefString(generated)
}

func derefString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func derefInt32(value *int32) int32 {
	if value == nil {
		return 0
	}
	return *value
}

// deviceIDForSession returns the install this call came from, or nil.
func (s *pricingServer) deviceIDForSession(ctx context.Context) *uuid.UUID {
	sessionID, err := auth.SessionID(ctx)
	if err != nil {
		return nil
	}
	device, err := s.queries.GetDeviceForSession(ctx, sessionID)
	if err != nil {
		return nil
	}
	return &device.ID
}

// subjectOf pulls the caller and validates the price check id they named.
func subjectOf(ctx context.Context, rawID string) (uuid.UUID, uuid.UUID, error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return uuid.Nil, uuid.Nil, connect.NewError(connect.CodeInternal, err)
	}
	checkID, err := uuid.Parse(rawID)
	if err != nil {
		return uuid.Nil, uuid.Nil, connect.NewError(connect.CodeInvalidArgument,
			fmt.Errorf("price_check_id: %w", err))
	}
	return userID, checkID, nil
}

func notFoundOrInternalCheck(err error, what string) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return connect.NewError(connect.CodeNotFound, errors.New("price check not found"))
	}
	return connect.NewError(connect.CodeInternal, fmt.Errorf("%s: %w", what, err))
}

// modelError maps a provider failure onto something the client can act on.
//
// The distinction that matters to the app is retry-or-not: Unavailable and
// DeadlineExceeded mean try again, ResourceExhausted and InvalidArgument mean
// do not. A blanket Internal would make the screen offer "Try again" for a
// safety refusal that will refuse identically every time.
func modelError(err error, what string) error {
	switch {
	case errors.Is(err, llm.ErrCeilingReached):
		return connect.NewError(connect.CodeResourceExhausted,
			errors.New("too many price checks recently; try again later"))
	case errors.Is(err, context.Canceled):
		return connect.NewError(connect.CodeCanceled, err)
	}

	switch llm.CodeOf(err) {
	case llm.ErrorCodeTimeout:
		return connect.NewError(connect.CodeDeadlineExceeded, fmt.Errorf("%s: %w", what, err))
	case llm.ErrorCodeRateLimited, llm.ErrorCodeUnavailable:
		return connect.NewError(connect.CodeUnavailable, fmt.Errorf("%s: %w", what, err))
	case llm.ErrorCodeRefused:
		// Only a genuine refusal earns this sentence, because it is the only
		// failure rewording can fix. A malformed request of ours is
		// bad_request and falls through to the internal error below, where it
		// belongs: it is not the user's item, and there is nothing they can do.
		return connect.NewError(connect.CodeInvalidArgument,
			errors.New("the model declined to answer for this item; try rewording the description"))
	default:
		return connect.NewError(connect.CodeInternal, fmt.Errorf("%s: %w", what, err))
	}
}

// photoMeta is what survives a photo: its shape and its ordinal, never its
// bytes. One of these per photo, matching `price_check_photos`.
type photoMeta struct {
	ordinal   int16
	sha256    []byte
	byteCount int32
	width     int32
	height    int32
}

// decodePhotos validates the images and measures every one of them.
//
// `image.DecodeConfig` is doing two jobs and the second is the important one:
// it reads the dimensions, and by reading them it proves the bytes are an image
// rather than whatever else a client felt like putting in the field. Only the
// header is parsed, so a 4 MiB photo costs almost nothing here.
func decodePhotos(raw [][]byte) ([]llm.Photo, []photoMeta, error) {
	if len(raw) == 0 {
		return nil, nil, nil
	}

	photos := make([]llm.Photo, 0, len(raw))
	meta := make([]photoMeta, 0, len(raw))
	for i, data := range raw {
		if len(data) == 0 {
			return nil, nil, fmt.Errorf("photos[%d] is empty", i)
		}
		cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return nil, nil, fmt.Errorf("photos[%d] is not a readable image: %w", i, err)
		}
		photos = append(photos, llm.Photo{Data: data, MediaType: "image/" + format})

		sum := sha256.Sum256(data)
		meta = append(meta, photoMeta{
			ordinal:   int16(i),
			sha256:    sum[:],
			byteCount: int32(len(data)),
			width:     int32(cfg.Width),
			height:    int32(cfg.Height),
		})
	}
	return photos, meta, nil
}

// Four helpers stood here, and all four went with the pricing call:
//
//   statsFromProto        translated the market for a prompt to read
//   comparablesFromProto  translated the listings for the same prompt
//   conditionProto        mapped a guess nothing consumed
//   clamp                 held a model's number inside its own evidence
//
// None of them were wrong. They were the cost of having a model produce a
// figure, and that cost is only visible once the figure comes from somewhere
// else. `CompletePriceCheck` reads the four values it records straight off the
// request.
