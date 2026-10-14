package main

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"strings"

	"connectrpc.com/connect"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"github.com/jackc/pgx/v5/pgxpool"
)

type sellerServer struct {
	queries *db.Queries
	pool    *pgxpool.Pool
}

func sellerParams(seller *v1.FacebookSeller) (db.UpsertFacebookSellerParams, error) {
	if seller == nil || strings.TrimSpace(seller.Name) == "" {
		return db.UpsertFacebookSellerParams{}, connect.NewError(connect.CodeInvalidArgument, errors.New("seller name is required"))
	}
	if seller.PhotoUrl != nil {
		u, err := url.Parse(*seller.PhotoUrl)
		if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
			return db.UpsertFacebookSellerParams{}, connect.NewError(connect.CodeInvalidArgument, errors.New("seller photo must be an HTTPS URL without credentials"))
		}
	}
	return db.UpsertFacebookSellerParams{
		ID: seller.Id, Name: strings.TrimSpace(seller.Name), PhotoUrl: seller.PhotoUrl,
		JoinedText: seller.JoinedText, Rating: seller.Rating, RatingCount: seller.RatingCount,
		IsHighlyRated: seller.IsHighlyRated,
	}, nil
}

func sellerProto(seller db.FacebookSeller) *v1.FacebookSeller {
	return &v1.FacebookSeller{
		Id: seller.ID, Name: seller.Name, PhotoUrl: seller.PhotoUrl,
		JoinedText: seller.JoinedText, Rating: seller.Rating, RatingCount: seller.RatingCount,
		IsHighlyRated: seller.IsHighlyRated,
	}
}

func (s *sellerServer) UpsertSeller(ctx context.Context, req *connect.Request[v1.UpsertSellerRequest]) (*connect.Response[v1.UpsertSellerResponse], error) {
	params, err := sellerParams(req.Msg.Seller)
	if err != nil {
		return nil, err
	}
	seller, err := s.queries.UpsertFacebookSeller(ctx, params)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("save seller: %w", err))
	}
	return connect.NewResponse(&v1.UpsertSellerResponse{Seller: sellerProto(seller)}), nil
}

func (s *sellerServer) SetSellerFollow(ctx context.Context, req *connect.Request[v1.SetSellerFollowRequest]) (*connect.Response[v1.SetSellerFollowResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	var params db.UpsertFacebookSellerParams
	if req.Msg.Following {
		params, err = sellerParams(req.Msg.Seller)
		if err != nil {
			return nil, err
		}
		if params.ID != req.Msg.SellerId {
			return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("seller IDs must match"))
		}
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	q := s.queries.WithTx(tx)
	if _, err := q.LockSellerFollowUser(ctx, userID); err != nil {
		return nil, notFoundOrInternal(err, "load user")
	}
	if req.Msg.Following {
		if _, err := q.UpsertFacebookSeller(ctx, params); err != nil {
			return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("save seller: %w", err))
		}
		err = q.FollowSeller(ctx, db.FollowSellerParams{UserID: userID, SellerID: req.Msg.SellerId})
	} else {
		err = q.UnfollowSeller(ctx, db.UnfollowSellerParams{UserID: userID, SellerID: req.Msg.SellerId})
	}
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("set seller follow: %w", err))
	}
	if err := tx.Commit(ctx); err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	return connect.NewResponse(&v1.SetSellerFollowResponse{}), nil
}

func (s *sellerServer) ListFollowedSellers(ctx context.Context, req *connect.Request[v1.ListFollowedSellersRequest]) (*connect.Response[v1.ListFollowedSellersResponse], error) {
	userID, err := auth.UserID(ctx)
	if err != nil {
		return nil, connect.NewError(connect.CodeUnauthenticated, err)
	}
	const pageSize = 100
	sellers, err := s.queries.ListFollowedSellers(ctx, db.ListFollowedSellersParams{UserID: userID, AfterID: req.Msg.AfterId, PageLimit: pageSize + 1})
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, fmt.Errorf("list seller follows: %w", err))
	}
	response := &v1.ListFollowedSellersResponse{}
	if len(sellers) > pageSize {
		sellers = sellers[:pageSize]
		response.NextAfterId = sellers[pageSize-1].ID
	}
	for _, seller := range sellers {
		response.Sellers = append(response.Sellers, sellerProto(seller))
	}
	return connect.NewResponse(response), nil
}
