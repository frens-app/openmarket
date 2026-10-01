package ingest

import (
	"testing"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

func price(amount, currency string) *v1.FacebookMarketplacePriceObservation {
	p := &v1.FacebookMarketplacePriceObservation{}
	if amount != "" {
		p.AmountDecimal = &amount
	}
	if currency != "" {
		p.CurrencyCode = &currency
	}
	return p
}

func TestParsePrice(t *testing.T) {
	tests := []struct {
		name     string
		amount   string
		currency string
		want     *int64
		wantErr  bool
	}{
		{name: "whole units", amount: "40", currency: "USD", want: ptr(int64(4000))},
		{name: "two decimals", amount: "40.50", currency: "USD", want: ptr(int64(4050))},
		{name: "one decimal", amount: "40.5", currency: "USD", want: ptr(int64(4050))},
		{name: "free is a price", amount: "0", currency: "USD", want: ptr(int64(0))},
		{name: "zero-exponent currency", amount: "4000", currency: "JPY", want: ptr(int64(4000))},
		{name: "zero-exponent with harmless zeros", amount: "4000.00", currency: "JPY", want: ptr(int64(4000))},
		{name: "three-exponent currency", amount: "40.500", currency: "KWD", want: ptr(int64(40500))},
		// The currency's exponent is the only thing that turns major units into
		// minor ones, so without it there is no number to store.
		{name: "no currency, no number", amount: "40.00", currency: "", want: nil},
		{name: "no amount", amount: "", currency: "USD", want: nil},

		{name: "grouping separator is a shape change", amount: "1,234.00", currency: "USD", wantErr: true},
		{name: "signed", amount: "-40.00", currency: "USD", wantErr: true},
		{name: "symbol", amount: "$40", currency: "USD", wantErr: true},
		{name: "trailing point", amount: "40.", currency: "USD", wantErr: true},
		{name: "leading point", amount: ".40", currency: "USD", wantErr: true},
		{name: "more precision than the currency has", amount: "40.501", currency: "USD", wantErr: true},
		{name: "words", amount: "Free", currency: "USD", wantErr: true},
		{name: "unknown currency is not guessed", amount: "40.00", currency: "ZZZ", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			minor, currency, err := parsePrice(price(tt.amount, tt.currency))
			if tt.wantErr {
				if err == nil {
					t.Fatalf("want error, got %v", derefInt(minor))
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if (minor == nil) != (tt.want == nil) {
				t.Fatalf("minor = %v, want %v", derefInt(minor), derefInt(tt.want))
			}
			if minor != nil && *minor != *tt.want {
				t.Fatalf("minor = %d, want %d", *minor, *tt.want)
			}
			if minor != nil && (currency == nil || *currency != tt.currency) {
				t.Fatalf("currency = %v, want %s", currency, tt.currency)
			}
		})
	}
}

// The page declares the currency; the card does not. Reading
// `amount_with_offset_in_currency` as minor units is what this replaces — it
// read 5429 against an `amount` of "75.00" on a Toronto payload, so storing it
// would have turned CA$75 into 54.29 and made exchange-rate drift look like a
// seller cutting their price.
func TestParsePriceUsesThePageCurrency(t *testing.T) {
	minor, currency, err := parsePrice(price("75.00", "CAD"))
	if err != nil {
		t.Fatal(err)
	}
	if minor == nil || *minor != 7500 {
		t.Fatalf("minor = %v, want 7500", derefInt(minor))
	}
	if currency == nil || *currency != "CAD" {
		t.Fatalf("currency = %v, want CAD", currency)
	}
}

// The strikethrough carries a decimal of its own, so a previous price is a
// number rather than a display string.
func TestParsePreviousPrice(t *testing.T) {
	p := price("150.00", "USD")
	previous := "300.00"
	p.PreviousAmountDecimal = &previous

	minor, err := parsePreviousPrice(p)
	if err != nil {
		t.Fatal(err)
	}
	if minor == nil || *minor != 30000 {
		t.Fatalf("previous = %v, want 30000", derefInt(minor))
	}

	// And with no currency there is nothing to scale it by.
	noCode := price("150.00", "")
	noCode.PreviousAmountDecimal = &previous
	if minor, err := parsePreviousPrice(noCode); err != nil || minor != nil {
		t.Fatalf("minor=%v err=%v, want no number", derefInt(minor), err)
	}
}

// A malformed amount fails the card whether or not we could have converted it.
// Skipping the shape check when the currency is missing would let a Facebook
// change through on exactly the surfaces that do not publish one.
func TestParsePriceChecksShapeWithoutCurrency(t *testing.T) {
	if _, _, err := parsePrice(price("1,234", "")); err == nil {
		t.Fatal("want error for a malformed amount with no currency")
	}
}

func ptr[T any](v T) *T { return &v }

func derefInt(v *int64) any {
	if v == nil {
		return "nil"
	}
	return *v
}
