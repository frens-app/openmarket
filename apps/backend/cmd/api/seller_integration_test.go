package main

import (
	"context"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"connectrpc.com/validate"
	"frens.lol/openmarket/backend/pkg/auth"
	"frens.lol/openmarket/backend/pkg/db"
	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
	"frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1/apiv1connect"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
	"go.uber.org/zap"
	"google.golang.org/protobuf/proto"
)

func TestSellerIntegration(t *testing.T) {
	databaseURL := os.Getenv("SELLER_TEST_DATABASE_URL")
	if databaseURL == "" {
		t.Skip("set SELLER_TEST_DATABASE_URL to a disposable database ending in _seller_test")
	}
	ctx := context.Background()
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(config.ConnConfig.Database, "_seller_test") {
		t.Fatal("database name must end in _seller_test")
	}
	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer pool.Close()
	sqlDB := stdlib.OpenDBFromPool(pool)
	defer sqlDB.Close()
	if err := goose.SetDialect("postgres"); err != nil {
		t.Fatal(err)
	}
	if err := goose.Up(sqlDB, "../../deployments/migrations"); err != nil {
		t.Fatal(err)
	}
	q := db.New(pool)
	mux := http.NewServeMux()
	mux.Handle(apiv1connect.NewSellerServiceHandler(&sellerServer{queries: q, pool: pool}, connect.WithInterceptors(validate.NewInterceptor(), newAuthInterceptor("test-secret", q))))
	server := httptest.NewServer(mux)
	defer server.Close()
	client := apiv1connect.NewSellerServiceClient(server.Client(), server.URL)
	newAccount := func() (db.User, string) {
		t.Helper()
		user, err := q.CreateUser(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		session, err := q.CreateSession(ctx, db.CreateSessionParams{UserID: user.ID, RefreshTokenHash: user.ID.String(), RefreshTokenExpiresAt: timestamptz(time.Now().Add(time.Hour)), DevicePlatform: db.DevicePlatformIOS})
		if err != nil {
			t.Fatal(err)
		}
		token, err := auth.SignAccessToken(user.ID, session.ID, "test-secret", time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		// No device or Facebook connection exists for this OpenMarket account.
		return user, token
	}
	userA, tokenA := newAccount()
	_, tokenB := newAccount()
	seller := &v1.FacebookSeller{Id: "123456789", Name: "Sam", PhotoUrl: proto.String("https://example.com/sam.jpg"), JoinedText: proto.String("Joined Facebook in 2012"), Rating: proto.Float64(4.8), RatingCount: proto.Int32(12), IsHighlyRated: proto.Bool(true)}
	upsert := func(profile *v1.FacebookSeller, token string) (*connect.Response[v1.UpsertSellerResponse], error) {
		req := connect.NewRequest(&v1.UpsertSellerRequest{Seller: profile})
		if token != "" {
			req.Header().Set("Authorization", "Bearer "+token)
		}
		return client.UpsertSeller(ctx, req)
	}
	follow := func(id string, following bool, profile *v1.FacebookSeller, token string) error {
		req := connect.NewRequest(&v1.SetSellerFollowRequest{SellerId: id, Following: following, Seller: profile})
		req.Header().Set("Authorization", "Bearer "+token)
		_, err := client.SetSellerFollow(ctx, req)
		return err
	}
	list := func(token, after string) *v1.ListFollowedSellersResponse {
		t.Helper()
		req := connect.NewRequest(&v1.ListFollowedSellersRequest{AfterId: after})
		req.Header().Set("Authorization", "Bearer "+token)
		response, err := client.ListFollowedSellers(ctx, req)
		if err != nil {
			t.Fatal(err)
		}
		return response.Msg
	}
	if _, err := upsert(seller, ""); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("anonymous upload: %v", err)
	}
	for _, profile := range []*v1.FacebookSeller{
		{Id: "../123", Name: "Sam"}, {Id: "123", Name: "  "}, {Id: "123", Name: "Sam", Rating: proto.Float64(6)},
		{Id: "123", Name: "Sam", Rating: proto.Float64(math.NaN())}, {Id: "123", Name: "Sam", RatingCount: proto.Int32(-1)},
		{Id: "123", Name: "Sam", PhotoUrl: proto.String("file:///tmp/photo")},
		{Id: "123", Name: "Sam", PhotoUrl: proto.String("https://user:pass@example.com/photo")},
	} {
		if _, err := upsert(profile, tokenA); connect.CodeOf(err) != connect.CodeInvalidArgument {
			t.Fatalf("invalid seller accepted: %v, %v", profile, err)
		}
	}
	if err := follow(seller.Id, true, seller, tokenA); err != nil {
		t.Fatal(err)
	}
	if err := follow(seller.Id, true, seller, tokenA); err != nil {
		t.Fatal(err)
	}
	if err := follow(seller.Id, true, nil, tokenA); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("missing profile: %v", err)
	}
	if err := follow("999", true, seller, tokenA); connect.CodeOf(err) != connect.CodeInvalidArgument {
		t.Fatalf("mismatched ID: %v", err)
	}
	if got := list(tokenA, ""); len(got.Sellers) != 1 {
		t.Fatalf("duplicate follow: %v", got)
	}
	if got := list(tokenB, ""); len(got.Sellers) != 0 {
		t.Fatalf("cross-account leak: %v", got)
	}
	// Guest Facebook observations preserve fields they cannot see.
	partial, err := upsert(&v1.FacebookSeller{Id: seller.Id, Name: "Sam Updated"}, tokenB)
	if err != nil {
		t.Fatal(err)
	}
	if partial.Msg.Seller.GetRating() != 4.8 || partial.Msg.Seller.GetPhotoUrl() != *seller.PhotoUrl || partial.Msg.Seller.GetJoinedText() != *seller.JoinedText {
		t.Fatalf("partial upload erased data: %v", partial.Msg.Seller)
	}
	zero, err := upsert(&v1.FacebookSeller{Id: seller.Id, Name: "Sam Updated", RatingCount: proto.Int32(0), IsHighlyRated: proto.Bool(false)}, tokenA)
	if err != nil {
		t.Fatal(err)
	}
	if zero.Msg.Seller.RatingCount == nil || zero.Msg.Seller.GetRatingCount() != 0 || zero.Msg.Seller.IsHighlyRated == nil || zero.Msg.Seller.GetIsHighlyRated() {
		t.Fatalf("explicit zero/false lost: %v", zero.Msg.Seller)
	}
	if err := follow(seller.Id, true, seller, tokenB); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := follow(seller.Id, false, nil, tokenA); err != nil {
			t.Fatal(err)
		}
	}
	if len(list(tokenA, "").Sellers) != 0 || len(list(tokenB, "").Sellers) != 1 {
		t.Fatal("unfollow affected another user")
	}
	// Exercise the actual page boundary rather than assuming the client can
	// restore all follows in one response.
	for i := range 101 {
		id := fmt.Sprintf("8%03d", i)
		if err := follow(id, true, &v1.FacebookSeller{Id: id, Name: "Seller"}, tokenA); err != nil {
			t.Fatal(err)
		}
	}
	first := list(tokenA, "")
	second := list(tokenA, first.NextAfterId)
	if len(first.Sellers) != 100 || first.NextAfterId == "" || len(second.Sellers) != 1 || second.NextAfterId != "" {
		t.Fatalf("bad pagination: %d/%d", len(first.Sellers), len(second.Sellers))
	}
	// Account deletion soft-deletes users; follows need explicit cleanup.
	if _, err := q.CreateAuthMethod(ctx, db.CreateAuthMethodParams{UserID: userA.ID, AuthService: db.AuthServiceGOOGLE, Subject: userA.ID.String()}); err != nil {
		t.Fatal(err)
	}
	userSvc := &userServer{queries: q, pool: pool, logger: zap.NewNop()}
	if _, err := userSvc.DeleteAccount(auth.WithUserID(ctx, userA.ID), connect.NewRequest(&v1.DeleteAccountRequest{})); err != nil {
		t.Fatal(err)
	}
	var count int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM seller_follows WHERE user_id=$1", userA.ID).Scan(&count); err != nil || count != 0 {
		t.Fatalf("deleted account retained follows: %d, %v", count, err)
	}
	if err := follow(seller.Id, true, seller, tokenA); connect.CodeOf(err) != connect.CodeUnauthenticated {
		t.Fatalf("deleted account can follow: %v", err)
	}
	if len(list(tokenB, "").Sellers) != 1 {
		t.Fatal("account deletion removed another user's follows")
	}
}
