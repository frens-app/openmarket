package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strings"
	"time"

	"buf.build/go/protovalidate"
	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"google.golang.org/protobuf/types/known/timestamppb"
)

type savedListingServer struct {
	queries *db.Queries
	pool    *pgxpool.Pool
}

func validListingTime(t *timestamppb.Timestamp, now time.Time) bool {
	return t != nil && t.CheckValid() == nil && !t.AsTime().Before(time.Date(2004, 1, 1, 0, 0, 0, 0, time.UTC)) && !t.AsTime().After(now.Add(5*time.Minute))
}

func listingFieldGroup(n protoreflect.FieldNumber) string {
	switch n {
	case 4, 5, 26, 27, 28:
		return "price"
	case 9, 10, 11, 14, 15, 16:
		return "detail"
	case 12, 13:
		return "availability"
	default:
		return "card"
	}
}

func listingSnapshotField(n protoreflect.FieldNumber) bool {
	return n >= 2 && n <= 21 || n >= 26 && n <= 28
}

func listingTimes(s *v1.SavedListingSnapshot) map[string]*timestamppb.Timestamp {
	return map[string]*timestamppb.Timestamp{"card": s.CardObservedAt, "price": s.PriceObservedAt, "detail": s.DetailObservedAt, "availability": s.AvailabilityObservedAt}
}

func validateListingChange(c *v1.SavedListingChange, now time.Time) error {
	if c == nil {
		return errors.New("missing change")
	}
	if err := protovalidate.Validate(c); err != nil {
		return err
	}
	if c.GetSaved() && !validListingTime(c.SavedAt, now) {
		return errors.New("valid saved_at is required")
	}
	if c.Saved != nil && !c.GetSaved() {
		if c.Snapshot != nil {
			return errors.New("removal cannot upload a snapshot")
		}
		return nil
	}
	s := c.Snapshot
	if s == nil || s.FacebookListingId != c.FacebookListingId {
		return errors.New("matching listing snapshot is required")
	}
	if (s.PriceAmountDecimal != nil || s.PriceCurrencyCode != nil) && s.PriceText == nil {
		return errors.New("structured price requires source price text")
	}
	if s.OriginalPriceAmountDecimal != nil && s.OriginalPriceText == nil {
		return errors.New("structured original price requires source text")
	}
	if c.GetSaved() && (strings.TrimSpace(s.GetTitle()) == "" || !validListingTime(s.CardObservedAt, now)) {
		return errors.New("saving requires a title and card observation time")
	}
	if s.Sold != nil && s.Pending != nil && s.GetSold() && s.GetPending() {
		return errors.New("listing cannot be both sold and pending")
	}
	times := listingTimes(s)
	for _, t := range times {
		if t != nil && !validListingTime(t, now) {
			return errors.New("invalid observation time")
		}
	}
	var fieldErr error
	s.ProtoReflect().Range(func(f protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		if listingSnapshotField(f.Number()) && !validListingTime(times[listingFieldGroup(f.Number())], now) {
			fieldErr = fmt.Errorf("observation time required for %s", f.Name())
			return false
		}
		return true
	})
	if fieldErr != nil {
		return fieldErr
	}
	urls := append([]string{}, s.PhotoUrls...)
	if s.ThumbnailUrl != nil {
		urls = append(urls, *s.ThumbnailUrl)
	}
	for _, raw := range urls {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
			return errors.New("photos require HTTPS URLs without credentials")
		}
	}
	if s.Seller != nil {
		if _, err := sellerParams(s.Seller); err != nil {
			return err
		}
	}
	return nil
}

// Track freshness per field, including optional seller fields. Group timestamps
// on reads use the oldest retained field so re-uploading a restored snapshot
// cannot falsely make an older field fresh.
func mergeListingSnapshot(old, incoming *v1.SavedListingSnapshot, ages map[string]time.Time) {
	old.FacebookListingId = incoming.FacebookListingId
	times := listingTimes(incoming)
	mergeListingPrices(old, incoming, ages)
	var merge func(protoreflect.Message, protoreflect.Message, string, time.Time)
	merge = func(dst, src protoreflect.Message, prefix string, at time.Time) {
		src.Range(func(f protoreflect.FieldDescriptor, v protoreflect.Value) bool {
			key := prefix + string(f.Name())
			if f.Message() != nil && !f.IsList() {
				merge(dst.Mutable(f).Message(), v.Message(), key+".", at)
				return true
			}
			if previous, ok := ages[key]; !ok || at.After(previous) {
				if f.IsList() {
					list := dst.Mutable(f).List()
					list.Truncate(0)
					for i := 0; i < v.List().Len(); i++ {
						list.Append(v.List().Get(i))
					}
				} else {
					dst.Set(f, v)
				}
				ages[key] = at
			}
			return true
		})
	}
	incoming.ProtoReflect().Range(func(f protoreflect.FieldDescriptor, v protoreflect.Value) bool {
		if !listingSnapshotField(f.Number()) || listingFieldGroup(f.Number()) == "price" {
			return true
		}
		at := times[listingFieldGroup(f.Number())].AsTime()
		single := (&v1.SavedListingSnapshot{}).ProtoReflect()
		single.Set(f, v)
		merge(old.ProtoReflect(), single, "", at)
		return true
	})
	oldest := map[string]time.Time{}
	old.ProtoReflect().Range(func(f protoreflect.FieldDescriptor, _ protoreflect.Value) bool {
		if !listingSnapshotField(f.Number()) {
			return true
		}
		group := listingFieldGroup(f.Number())
		name := string(f.Name())
		for key, at := range ages {
			if key == name || strings.HasPrefix(key, name+".") {
				if prev, ok := oldest[group]; !ok || at.Before(prev) {
					oldest[group] = at
				}
			}
		}
		return true
	})
	old.CardObservedAt = nil
	old.PriceObservedAt = nil
	old.DetailObservedAt = nil
	old.AvailabilityObservedAt = nil
	for group, at := range oldest {
		t := timestamppb.New(at)
		switch group {
		case "card":
			old.CardObservedAt = t
		case "price":
			old.PriceObservedAt = t
		case "detail":
			old.DetailObservedAt = t
		case "availability":
			old.AvailabilityObservedAt = t
		}
	}
}

// Replace each price with its metadata atomically. A newer text-only client
// invalidates older numeric values rather than attaching them to a new price.
func mergeListingPrices(old, incoming *v1.SavedListingSnapshot, ages map[string]time.Time) {
	at := incoming.PriceObservedAt.AsTime()
	for _, key := range []string{"price_text", "original_price_text"} {
		if previous, ok := ages[key]; ok && !at.After(previous) {
			return
		}
	}
	if incoming.PriceText != nil {
		if old.GetPriceCurrencyCode() != incoming.GetPriceCurrencyCode() {
			old.OriginalPriceText = nil
			old.OriginalPriceAmountDecimal = nil
			ages["original_price_text"] = at
			ages["original_price_amount_decimal"] = at
		}
		old.PriceText = incoming.PriceText
		old.PriceAmountDecimal = incoming.PriceAmountDecimal
		old.PriceCurrencyCode = incoming.PriceCurrencyCode
		for _, key := range []string{"price_text", "price_amount_decimal", "price_currency_code"} {
			ages[key] = at
		}
	}
	if incoming.OriginalPriceText != nil {
		old.OriginalPriceText = incoming.OriginalPriceText
		old.OriginalPriceAmountDecimal = incoming.OriginalPriceAmountDecimal
		ages["original_price_text"] = at
		ages["original_price_amount_decimal"] = at
	}
}

func (s *savedListingServer) apply(ctx context.Context, userID uuid.UUID, c *v1.SavedListingChange) error {
	if c == nil {
		return connect.NewError(connect.CodeInvalidArgument, errors.New("missing change"))
	}
	if err := protovalidate.Validate(c); err != nil {
		return connect.NewError(connect.CodeInvalidArgument, err)
	}
	encoded, err := proto.MarshalOptions{Deterministic: true}.Marshal(c)
	if err != nil {
		return err
	}
	hash := sha256.Sum256(encoded)
	mutationID, err := uuid.Parse(c.MutationId)
	if err != nil {
		return connect.NewError(connect.CodeInvalidArgument, err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.queries.WithTx(tx)
	if _, err = q.LockSavedListingUser(ctx, userID); err != nil {
		return notFoundOrInternal(err, "load user")
	}
	previous, err := q.GetSavedListingMutation(ctx, db.GetSavedListingMutationParams{UserID: userID, MutationID: mutationID})
	if err == nil {
		if !bytes.Equal(previous, hash[:]) {
			return connect.NewError(connect.CodeInvalidArgument, errors.New("mutation ID reused with different contents"))
		}
		return nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return err
	}
	if err := validateListingChange(c, time.Now()); err != nil {
		return connect.NewError(connect.CodeInvalidArgument, err)
	}
	if c.Snapshot != nil {
		if err = q.EnsureListing(ctx, c.FacebookListingId); err != nil {
			return err
		}
		row, err := q.LockListing(ctx, c.FacebookListingId)
		if err != nil {
			return err
		}
		snapshot, err := decodeListingSnapshot(row.Snapshot, row.PriceAmountDecimal, row.PriceCurrencyCode, row.OriginalPriceAmountDecimal)
		if err != nil {
			return err
		}
		ages := map[string]time.Time{}
		if err = json.Unmarshal(row.FieldObservedAt, &ages); err != nil {
			return err
		}
		mergeListingSnapshot(snapshot, c.Snapshot, ages)
		if snapshot.GetSold() && snapshot.GetPending() {
			return connect.NewError(connect.CodeInvalidArgument, errors.New("conflicting availability; refresh both sold and pending"))
		}
		update, err := listingSnapshotUpdate(row.ID, snapshot, ages)
		if err != nil {
			return err
		}
		if err = q.UpdateListingSnapshot(ctx, update); err != nil {
			return err
		}
		if c.GetSaved() {
			if err = q.SaveListing(ctx, db.SaveListingParams{UserID: userID, ListingID: row.ID, SavedAt: timestamptz(c.SavedAt.AsTime())}); err != nil {
				return err
			}
		}
	} else {
		if err = q.RemoveSavedListing(ctx, db.RemoveSavedListingParams{UserID: userID, FacebookListingID: c.FacebookListingId}); err != nil {
			return err
		}
	}
	if err = q.RecordSavedListingMutation(ctx, db.RecordSavedListingMutationParams{UserID: userID, MutationID: mutationID, RequestHash: hash[:]}); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s *savedListingServer) ApplySavedListingChanges(ctx context.Context, req *connect.Request[v1.ApplySavedListingChangesRequest]) (*connect.Response[v1.ApplySavedListingChangesResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	if len(req.Msg.Changes) == 0 || len(req.Msg.Changes) > 50 {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("send 1 to 50 changes"))
	}
	response := &v1.ApplySavedListingChangesResponse{}
	for _, c := range req.Msg.Changes {
		result := &v1.SavedListingChangeResult{MutationId: c.GetMutationId()}
		err := s.apply(ctx, userID, c)
		if err != nil {
			if connect.CodeOf(err) != connect.CodeInvalidArgument {
				return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("sync saved listing: %w", err))
			}
			result.Error = err.Error()
		}
		response.Results = append(response.Results, result)
	}
	return connect.NewResponse(response), nil
}

func (s *savedListingServer) ListSavedListings(ctx context.Context, req *connect.Request[v1.ListSavedListingsRequest]) (*connect.Response[v1.ListSavedListingsResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	rows, err := s.queries.ListSavedListings(ctx, db.ListSavedListingsParams{UserID: userID, AfterID: req.Msg.AfterId, PageLimit: 101})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	response := &v1.ListSavedListingsResponse{}
	more := len(rows) > 100
	if more {
		rows = rows[:100]
	}
	for _, row := range rows {
		snapshot, err := decodeListingSnapshot(row.Snapshot, row.PriceAmountDecimal, row.PriceCurrencyCode, row.OriginalPriceAmountDecimal)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		response.Listings = append(response.Listings, &v1.SavedListing{ListingId: row.ID.String(), Snapshot: snapshot, SavedAt: timestamppb.New(row.SavedAt.Time)})
	}
	if more {
		response.NextAfterId = response.Listings[len(response.Listings)-1].Snapshot.FacebookListingId
	}
	return connect.NewResponse(response), nil
}
