package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"image"
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
		PhotoSha256: meta.sha256,
		PhotoBytes:  meta.byteCount,
		PhotoWidth:  meta.width,
		PhotoHeight: meta.height,
	})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("create price check: %w", err))
	}

	item, err := s.runner.Identify(ctx, llm.Subject{UserID: userID, PriceCheckID: &check.ID},
		llm.IdentifyInput{Description: req.Msg.GetDescription(), Photos: photos})
	if err != nil {
		return nil, modelError(err, "identify item")
	}

	if _, err := s.queries.SetPriceCheckIdentification(ctx, db.SetPriceCheckIdentificationParams{
		ID:             check.ID,
		UserID:         userID,
		IdentifiedName: item.Name,
		SearchQueries:  item.SearchQueries,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("record identification: %w", err))
	}

	return connect.NewResponse(&v1.IdentifyItemResponse{
		PriceCheckId:   check.ID.String(),
		IdentifiedName: item.Name,
		SearchQueries:  item.SearchQueries,
		Condition:      conditionProto(item.Condition),
		KeyAttributes:  item.KeyAttributes,
	}), nil
}

func (s *pricingServer) PriceItem(
	ctx context.Context,
	req *connect.Request[v1.PriceItemRequest],
) (*connect.Response[v1.PriceItemResponse], error) {
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

	stats := statsFromProto(req.Msg.GetStats())
	// The band has to be real before anything is priced against it. A zero
	// `stats` message deserializes into a market of nothing, and pricing an
	// item at the median of an empty set is how a number with nothing behind it
	// reaches a screen.
	if stats.PricedCount <= 0 {
		return nil, connect.NewError(connect.CodeInvalidArgument,
			errors.New("stats.priced_count must be positive; there is no market to price against"))
	}

	priced, err := s.runner.Price(ctx, llm.Subject{UserID: userID, PriceCheckID: &check.ID}, llm.PriceInput{
		Item: llm.IdentifiedItem{
			Name:          derefString(check.IdentifiedName),
			SearchQueries: check.SearchQueries,
		},
		Description: check.Description,
		MarketName:  req.Msg.GetMarketName(),
		Comparables: comparablesFromProto(req.Msg.GetComparables()),
		Stats:       stats,
	})
	if err != nil {
		return nil, modelError(err, "price item")
	}

	// Clamped here as well as on the device, and the reason is not belt and
	// braces: this is where the number is written down. Recording what the
	// model said while the screen shows something else would leave the table
	// disagreeing with the app about the one figure anybody acts on.
	price := clamp(priced.PriceMinor, stats.LowestMinor, stats.HighestMinor)

	if _, err := s.queries.CompletePriceCheck(ctx, db.CompletePriceCheckParams{
		ID:                    check.ID,
		UserID:                userID,
		SearchQueryUsed:       req.Msg.GetSearchQueryUsed(),
		CompsFound:            int32(len(req.Msg.GetComparables())),
		SoldFound:             stats.SoldCount,
		RecommendedPriceMinor: &price,
		MedianPriceMinor:      &stats.MedianMinor,
		CurrencySymbol:        &stats.CurrencySymbol,
	}); err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("complete price check: %w", err))
	}

	return connect.NewResponse(&v1.PriceItemResponse{
		RecommendedPriceMinor: price,
		Title:                 priced.Title,
		Description:           priced.Body,
	}), nil
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

// RecordPriceCopied is the signal that costs the user nothing to give.
//
// Copying the price is the action immediately before pasting it into Facebook's
// price box, so it is about as close to "this worked" as anything observable
// gets — and it arrives from everybody, where the feedback buttons are answered
// by the minority who stop to tap one.
func (s *pricingServer) RecordPriceCopied(
	ctx context.Context,
	req *connect.Request[v1.RecordPriceCopiedRequest],
) (*connect.Response[v1.RecordPriceCopiedResponse], error) {
	userID, checkID, err := subjectOf(ctx, req.Msg.GetPriceCheckId())
	if err != nil {
		return nil, err
	}

	if _, err := s.queries.MarkPriceCheckPriceCopied(ctx, db.MarkPriceCheckPriceCopiedParams{
		ID:     checkID,
		UserID: userID,
	}); err != nil {
		return nil, notFoundOrInternalCheck(err, "record price copied")
	}
	return connect.NewResponse(&v1.RecordPriceCopiedResponse{}), nil
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

// photoMeta is what survives a photo: its shape, never its bytes.
type photoMeta struct {
	sha256    []byte
	byteCount *int32
	width     *int32
	height    *int32
}

// decodePhotos validates the images and measures them.
//
// Only the first photo's shape is kept, because only one can be sent today —
// the request schema caps `photos` at one item. When that cap rises this
// returns a slice and the four columns become a child table.
func decodePhotos(raw [][]byte) ([]llm.Photo, photoMeta, error) {
	var meta photoMeta
	if len(raw) == 0 {
		return nil, meta, nil
	}

	photos := make([]llm.Photo, 0, len(raw))
	for i, data := range raw {
		if len(data) == 0 {
			return nil, meta, fmt.Errorf("photos[%d] is empty", i)
		}
		cfg, format, err := image.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return nil, meta, fmt.Errorf("photos[%d] is not a readable image: %w", i, err)
		}
		photos = append(photos, llm.Photo{Data: data, MediaType: "image/" + format})

		if i == 0 {
			sum := sha256.Sum256(data)
			byteCount, width, height := int32(len(data)), int32(cfg.Width), int32(cfg.Height)
			meta = photoMeta{
				sha256:    sum[:],
				byteCount: &byteCount,
				width:     &width,
				height:    &height,
			}
		}
	}
	return photos, meta, nil
}

func statsFromProto(s *v1.MarketStats) llm.MarketStats {
	if s == nil {
		return llm.MarketStats{}
	}
	return llm.MarketStats{
		PricedCount:      s.GetPricedCount(),
		MedianMinor:      s.GetMedianMinor(),
		LowestMinor:      s.GetLowestMinor(),
		HighestMinor:     s.GetHighestMinor(),
		LowerQuartile:    s.LowerQuartileMinor,
		UpperQuartile:    s.UpperQuartileMinor,
		CurrencySymbol:   s.GetCurrencySymbol(),
		SoldCount:        s.GetSoldCount(),
		MedianDaysToSell: s.MedianDaysToSell,
	}
}

func comparablesFromProto(in []*v1.Comparable) []llm.Comparable {
	out := make([]llm.Comparable, 0, len(in))
	for _, c := range in {
		out = append(out, llm.Comparable{
			Title:      c.GetTitle(),
			PriceMinor: c.PriceMinor,
			IsSold:     c.GetIsSold(),
			DaysListed: c.DaysListed,
			City:       c.GetCity(),
		})
	}
	return out
}

// conditionProto maps the model's word onto Facebook's own values. Anything
// unrecognised is UNSPECIFIED rather than a guess — the field is a hint, and a
// wrong hint is worse than none.
func conditionProto(condition string) v1.ItemCondition {
	switch condition {
	case "new":
		return v1.ItemCondition_ITEM_CONDITION_NEW
	case "used_like_new":
		return v1.ItemCondition_ITEM_CONDITION_USED_LIKE_NEW
	case "used_good":
		return v1.ItemCondition_ITEM_CONDITION_USED_GOOD
	case "used_fair":
		return v1.ItemCondition_ITEM_CONDITION_USED_FAIR
	default:
		return v1.ItemCondition_ITEM_CONDITION_UNSPECIFIED
	}
}

// clamp holds a recommendation inside the evidence that produced it. A price
// outside the observed range is not a bolder opinion about the market, it is a
// number with nothing behind it.
func clamp(price, low, high int64) int64 {
	if low > high {
		return price
	}
	return min(max(price, low), high)
}

func derefString(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}
