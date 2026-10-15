package main

import (
	"context"
	"database/sql"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/pressly/goose/v3"
)

func verifyListingPriceMigration(t *testing.T, ctx context.Context, sqlDB *sql.DB, pool *pgxpool.Pool) {
	t.Helper()
	const migrations = "../../deployments/migrations"
	if err := goose.UpTo(sqlDB, migrations, 21); err != nil {
		t.Fatal(err)
	}
	samples := []struct {
		id, snapshot               string
		amount, currency, original *string
	}{
		{"77001", `{"priceText":"CA$12.50","priceAmountDecimal":"12.50","priceCurrencyCode":"CAD","originalPriceText":"CA$20.99","originalPriceAmountDecimal":"20.99"}`, stringPtr("12.50"), stringPtr("CAD"), stringPtr("20.99")},
		{"77002", `{"priceText":"$100"}`, nil, nil, nil},
		{"77003", `{"priceText":"Free","priceAmountDecimal":"0"}`, stringPtr("0"), nil, nil},
		{"77004", `{"priceText":"VND9,007,199,254,740,993","priceAmountDecimal":"9007199254740993","priceCurrencyCode":"VND"}`, stringPtr("9007199254740993"), stringPtr("VND"), nil},
		{"77005", `{"priceText":"bad source","priceAmountDecimal":"1.234","priceCurrencyCode":"$","originalPriceAmountDecimal":"NaN"}`, nil, nil, nil},
		{"77006", `{"priceText":"bad source","priceAmountDecimal":"1e3","priceCurrencyCode":"cad","originalPriceAmountDecimal":"-1"}`, nil, nil, nil},
	}
	for _, sample := range samples {
		if _, err := pool.Exec(ctx, "INSERT INTO listings (facebook_listing_id, snapshot) VALUES ($1, $2::jsonb)", sample.id, sample.snapshot); err != nil {
			t.Fatal(err)
		}
	}
	check := func() {
		t.Helper()
		for _, sample := range samples {
			var amount, currency, original *string
			var duplicates bool
			if err := pool.QueryRow(ctx, `SELECT price_amount::text, price_currency_code, original_price_amount::text,
    snapshot ?| ARRAY['priceAmountDecimal','priceCurrencyCode','originalPriceAmountDecimal']
    FROM listings WHERE facebook_listing_id=$1`, sample.id).Scan(&amount, &currency, &original, &duplicates); err != nil {
				t.Fatal(err)
			}
			same := func(a, b *string) bool { return a == nil && b == nil || a != nil && b != nil && *a == *b }
			if !same(amount, sample.amount) || !same(currency, sample.currency) || !same(original, sample.original) || duplicates {
				t.Fatalf("incorrect migrated price for %s", sample.id)
			}
		}
	}
	if err := goose.UpTo(sqlDB, migrations, 22); err != nil {
		t.Fatal(err)
	}
	check()
	for _, amount := range []string{"-1", "1.234", "1000000000000000000", "NaN", "Infinity", "-Infinity"} {
		for _, column := range []string{"price_amount", "original_price_amount"} {
			_, err := pool.Exec(ctx, "UPDATE listings SET "+column+"=$1::numeric WHERE facebook_listing_id='77002'", amount)
			var pgErr *pgconn.PgError
			if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
				t.Fatalf("%s accepted invalid amount %q: %v", column, amount, err)
			}
		}
	}
	if _, err := pool.Exec(ctx, "UPDATE listings SET price_currency_code='cad' WHERE facebook_listing_id='77002'"); err == nil {
		t.Fatal("accepted invalid currency code")
	}
	if err := goose.DownTo(sqlDB, migrations, 21); err != nil {
		t.Fatal(err)
	}
	var amount, currency, original string
	if err := pool.QueryRow(ctx, `SELECT snapshot->>'priceAmountDecimal', snapshot->>'priceCurrencyCode', snapshot->>'originalPriceAmountDecimal' FROM listings WHERE facebook_listing_id='77001'`).Scan(&amount, &currency, &original); err != nil {
		t.Fatal(err)
	}
	if amount != "12.50" || currency != "CAD" || original != "20.99" {
		t.Fatal("rollback lost structured prices")
	}
	if err := goose.UpTo(sqlDB, migrations, 22); err != nil {
		t.Fatal(err)
	}
	check()
}

func stringPtr(s string) *string { return &s }
