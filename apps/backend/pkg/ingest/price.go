package ingest

import (
	"errors"
	"strconv"
	"strings"

	v1 "frens.lol/openmarket/backend/pkg/protos/openmarket/api/v1"
)

var errPriceShape = errors.New("price is not a plain decimal")

// currencyExponent holds the currencies whose minor unit is not two decimal
// places. Everything absent from this map is assumed to have two, which is
// true of every currency this app has been pointed at.
var currencyExponent = map[string]int{
	"BIF": 0, "CLP": 0, "DJF": 0, "GNF": 0, "ISK": 0, "JPY": 0, "KMF": 0,
	"KRW": 0, "PYG": 0, "RWF": 0, "UGX": 0, "VND": 0, "VUV": 0,
	"XAF": 0, "XOF": 0, "XPF": 0,
	"BHD": 3, "IQD": 3, "JOD": 3, "KWD": 3, "LYD": 3, "OMR": 3, "TND": 3,
}

// parsePrice converts Facebook's decimal to minor units, using the currency the
// page declared.
//
// **The currency is not optional and cannot be guessed.** `listing_price`
// carries `amount` and `formatted_amount` and no code; the search page publishes
// one for the whole marketplace at
// `marketplace_settings.current_marketplace.primary_currency`, and the client
// stamps it on every card that page produced. Without it there is no number:
// scaling major units to minor needs the currency's exponent, which is two for
// most currencies, zero for JPY and three for KWD.
//
// The shape is checked whether or not the currency arrived, so a malformed
// amount fails the card either way. `price_formatted` carries the display value
// regardless — "Free", "$20 - $40" and "CA$40" are all real and all lose
// something in the parse.
//
// Deliberately not `amount_with_offset_in_currency`, which looks like minor
// units and is not: on a Toronto payload it read 5429 against an `amount` of
// "75.00". It is an internal converted amount that collapses to the listing
// price only on US pages.
func parsePrice(p *v1.FacebookMarketplacePriceObservation) (*int64, *string, error) {
	if p == nil {
		return nil, nil, nil
	}
	amount := strings.TrimSpace(p.GetAmountDecimal())
	if amount == "" {
		return nil, nil, nil
	}
	whole, frac, err := splitDecimal(amount)
	if err != nil {
		return nil, nil, err
	}

	code := strings.ToUpper(strings.TrimSpace(p.GetCurrencyCode()))
	if code == "" {
		return nil, nil, nil
	}
	minor, err := scaleToMinor(whole, frac, exponentFor(code))
	if err != nil {
		return nil, nil, err
	}
	return &minor, &code, nil
}

// parsePreviousPrice reads the strikethrough price under the same rules. It has
// a decimal of its own: `{"formatted_amount":"$150","amount":"150.00"}`.
func parsePreviousPrice(p *v1.FacebookMarketplacePriceObservation) (*int64, error) {
	if p == nil {
		return nil, nil
	}
	amount := strings.TrimSpace(p.GetPreviousAmountDecimal())
	if amount == "" {
		return nil, nil
	}
	whole, frac, err := splitDecimal(amount)
	if err != nil {
		return nil, err
	}
	code := strings.ToUpper(strings.TrimSpace(p.GetCurrencyCode()))
	if code == "" {
		return nil, nil
	}
	minor, err := scaleToMinor(whole, frac, exponentFor(code))
	if err != nil {
		return nil, err
	}
	return &minor, nil
}

func exponentFor(code string) int {
	if e, ok := currencyExponent[code]; ok {
		return e
	}
	return 2
}

// splitDecimal accepts digits, optionally followed by a point and more digits.
//
// Nothing else. A sign, a grouping separator or a currency symbol means we are
// reading the formatted string by mistake, and "1,234" quietly becoming 1234
// would hide that rather than report it.
func splitDecimal(s string) (whole, frac string, err error) {
	whole, frac, hasFrac := strings.Cut(s, ".")
	if !allDigits(whole) || whole == "" {
		return "", "", errPriceShape
	}
	if hasFrac && !allDigits(frac) {
		return "", "", errPriceShape
	}
	if hasFrac && frac == "" {
		return "", "", errPriceShape
	}
	return whole, frac, nil
}

func allDigits(s string) bool {
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return len(s) > 0
}

// scaleToMinor shifts the decimal point by the currency's exponent.
//
// Deliberately not ParseFloat and a multiply: a float cannot hold 0.07 exactly,
// and a price is the one field here where a cent out is a wrong answer rather
// than a rounding artefact.
//
// Digits beyond the exponent are allowed only when they are zeros. "40.00" in a
// zero-exponent currency is unambiguously forty; "40.50" is not, and truncating
// it would invent a price.
func scaleToMinor(whole, frac string, exponent int) (int64, error) {
	if len(frac) > exponent {
		if strings.Trim(frac[exponent:], "0") != "" {
			return 0, errPriceShape
		}
		frac = frac[:exponent]
	}
	digits := whole + frac + strings.Repeat("0", exponent-len(frac))
	value, err := strconv.ParseInt(digits, 10, 64)
	if err != nil {
		return 0, errPriceShape
	}
	return value, nil
}
