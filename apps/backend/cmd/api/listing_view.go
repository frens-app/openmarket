package main

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"buf.build/go/protovalidate"
	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/jackc/pgx/v5/pgxpool"
	"google.golang.org/protobuf/proto"
)

type listingViewServer struct {
	queries *db.Queries
	pool    *pgxpool.Pool
}

func validateListingView(r *v1.SubmitListingViewRequest, now time.Time) error {
	if err := protovalidate.Validate(r); err != nil {
		return err
	}
	if !validListingTime(r.ViewedAt, now) {
		return errors.New("invalid view time")
	}
	if r.Snapshot == nil {
		if r.Source != v1.ListingViewSource_LISTING_VIEW_SOURCE_UNSPECIFIED {
			return errors.New("source requires snapshot")
		}
		return nil
	}
	if r.Source == v1.ListingViewSource_LISTING_VIEW_SOURCE_UNSPECIFIED || !validListingTime(r.Snapshot.DetailObservedAt, now) {
		return errors.New("detail observation time and source required")
	}
	return validateListingChange(&v1.SavedListingChange{MutationId: "00000000-0000-4000-8000-000000000001", FacebookListingId: r.FacebookListingId, Snapshot: r.Snapshot}, now)
}

// The account comes exclusively from the verified OpenMarket session.
func (s *listingViewServer) SubmitListingView(ctx context.Context, req *connect.Request[v1.SubmitListingViewRequest]) (*connect.Response[v1.SubmitListingViewResponse], error) {
	receivedAt := time.Now()
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	r := req.Msg
	if err := validateListingView(r, receivedAt); err != nil {
		return nil, connect.NewError(connect.CodeInvalidArgument, err)
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.queries.WithTx(tx)
	if _, err = q.LockSavedListingUser(ctx, userID); err != nil {
		return nil, notFoundOrInternal(err, "load user")
	}
	view := db.RecordListingViewParams{ViewedAt: timestamptz(r.ViewedAt.AsTime()), ReceivedAt: timestamptz(receivedAt), Viewer: &userID}
	if err = q.EnsureListing(ctx, r.FacebookListingId); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	row, err := q.LockListing(ctx, r.FacebookListingId)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	view.ID = row.ID
	if r.Referrer != nil {
		if err = q.RecordUserListingClick(ctx, db.RecordUserListingClickParams{
			UserID: userID, ListingID: row.ID,
			ClickedAt: view.ViewedAt, Referrer: r.GetReferrer(),
		}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if err = q.RecordListingView(ctx, view); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	if r.Snapshot != nil && (!row.LastDetailReceivedAt.Valid || receivedAt.After(row.LastDetailReceivedAt.Time)) {
		snapshot, err := decodeListingSnapshot(row.Snapshot, row.PriceAmountDecimal, row.PriceCurrencyCode, row.OriginalPriceAmountDecimal)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		ages := map[string]time.Time{}
		if err = json.Unmarshal(row.FieldObservedAt, &ages); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		mergeListingSnapshot(snapshot, r.Snapshot, ages)
		if snapshot.GetSold() && snapshot.GetPending() {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("conflicting availability"))
		}
		update, err := listingSnapshotUpdate(row.ID, snapshot, ages)
		if err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if err = q.UpdateListingSnapshot(ctx, update); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
		if err = q.RecordListingDetailSource(ctx, db.RecordListingDetailSourceParams{ID: row.ID, ObservedAt: timestamptz(r.Snapshot.DetailObservedAt.AsTime()), Source: proto.String(r.Source.String()), Observer: &userID, ReceivedAt: timestamptz(receivedAt)}); err != nil {
			return nil, connect.NewError(connect.CodeInternal, err)
		}
	}
	if err = tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.SubmitListingViewResponse{}), nil
}
