# Regional currencies — verified 2026-10-15

The app enables 29 countries. This expansion adds France, Italy, Germany,
Mexico, Philippines, Brazil, India, Indonesia, Vietnam, Bangladesh, Pakistan,
Egypt, Thailand, Nigeria, Colombia, Turkey, Argentina, South Africa, and Algeria.
App Store territory availability must be updated separately when releasing the build.

## Field units

`MarketCurrency` owns currency aliases, local display symbols, and conversion
from Facebook's `amount_with_offset` to a major-unit `Decimal`.

| Source | Interpretation |
| --- | --- |
| Search `listing_price.amount` | Canonical major-unit decimal text |
| Search `listing_price.formatted_amount` | Source display text, parsed independently of device locale |
| Discover `data.price.amount_with_offset` | Divide by the currency's Facebook offset |
| Search `filter_price_*_bound` | Major units multiplied by 100, independently of the Discover offset |

Facebook's public page currency metadata specifies offset **1** for TWD, IDR,
COP, and VND, and **100** for the other supported currencies. TWD, IDR, and COP
therefore must not inherit their ISO minor-unit precision. Captured metadata:
[`currencies-2026-10-15.json`](../tools/probe/regional/currencies-2026-10-15.json).

Do not substitute `amount_with_offset_in_currency` from search for the local
listing amount: the observed values differ from the local amount and its
currency offset (for example, EUR 30 had this field equal to 3340).

Bounded filter probes in Jakarta and Ho Chi Minh City confirmed that bounds
100,000–200,000 require request values 10,000,000–20,000,000. Without the ×100
scale, the responses contained prices 1,000–2,000. A Colombia comparison hit
Facebook's rate limit; probing stopped immediately. The corresponding Taiwan
filter check was not run. No filter conversion change was made.

## Parsing and display

`MarketplacePrice` accepts prefix and suffix symbols, decimal commas or dots,
western and Indian grouping, ordinary/nonbreaking/narrow spaces, Arabic and
Bengali digits, and compact K/M/B amounts. Malformed grouping and unsupported
currencies are rejected rather than partially parsed. A single separator with
three following digits is grouping; supported prices have at most two decimal
places. Discount pairs must use the same source currency marker and ascend in
exact decimal value.

`Listing.priceText` and `originalPriceText` retain source text for persistence
and observations. Views use `displayPrice` and `displayOriginalPrice`; these
shorten symbols without changing numbers or separators. Examples: CA$/CAD → $,
GBP → £, PHP → ₱, IDR → Rp. Price-check history also retains its source marker
while rendering the shorter symbol.

Price guides group known aliases by currency and exclude other currencies from
their numeric sample. A check of a specific listing uses that listing's source
currency. No exchange-rate conversion occurs. Price recommendations retain the
existing whole-major-unit policy; fractional values are parsed exactly before
truncation. The application's price-check wire format remains hundredths of a
major unit, independently of Facebook's offset.

## Saved listing storage

`SavedListingSnapshot` stores `price_amount_decimal`, `price_currency_code`, and
`original_price_amount_decimal` alongside the source text. Amounts are exact
nonnegative decimal strings in **major units**, with up to 18 integer digits and
two fractional digits. They are never floating-point numbers or Facebook offset
integers. GraphQL's numeric amount takes precedence over compact display text
such as `$1.23M`.

PostgreSQL stores the normalized values in dedicated `listings.price_amount`
(`numeric`), `price_currency_code` (`text`), and `original_price_amount`
(`numeric`) columns. `price_amount` is the current asking price;
`original_price_amount` is the previous asking price Facebook shows crossed out,
not the first price this app observed. A listing reduced from CAD 100 to CAD 80
has `price_amount = 80`, `original_price_amount = 100`, and
`price_currency_code = 'CAD'`. A missing previous price remains NULL.

Migration `00022_listing_price_columns.sql` backfills valid explicit structured
JSONB values and removes those keys from the snapshot. The columns are the
single source of truth; source display text and other listing details remain
in JSONB. The API reconstructs its existing decimal-string fields from the
columns, preserving client compatibility. Database checks reject negative,
nonfinite, out-of-range, and excess-precision values without rounding. Rollback
restores the structured JSONB fields before dropping the columns.

Local saves, sync responses, and shopping results carry the same wire fields.
An unambiguous source marker can supply a missing code, but bare `$` remains
unknown unless GraphQL supplies the code. Ranges are not inferred to be exact
amounts; free prices are zero with unknown currency unless the source identifies
it. The migration never guesses currency from old formatted text.

The server validates decimal/code syntax and observation times. Price text and
its numeric metadata update together. A newer legacy text-only update clears
stale structured values, and an older retry cannot restore them. Currency
changes invalidate an original price from the previous currency. Existing
records without these fields remain readable. Deploy the updated backend
before releasing the client that writes these fields.

This storage addition applies to listing records. Price-check history still
uses its existing fixed-hundredths wire format and whole-unit recommendations.

## Evidence and limits

- iOS simulator build and test suite passed: 220 tests, one opt-in live Amazon
  test skipped, zero failures.
- Backend build, vet, and tests pass. A disposable PostgreSQL database verifies
  migration up/down/backfill, database constraints, and API save/load for CAD, EUR, INR, IDR, VND, and COP, including
  zero and an exact amount larger than 2^53. Swift wire/local-storage tests
  cover all 24 currencies.
- Cookie-free GraphQL: two search pages and one Discover page in one city per
  new country, 57 responses and 1,221 listing occurrences. The production
  decoder replayed all responses successfully; 1,220 prices parsed and one
  unsupported PLN price from Berlin remained unparsed and unmodified.
- A returned `IDR550M` price supplied the compact-amount regression case.
- The test resource `apps/ios/TestResources/RegionalPrices.json` contains all
  430 distinct search price strings from the probe, with Facebook's major-unit
  amounts. Synthetic tests cover decimal and grouping variants not encountered
  in these English responses.
- Results: [`results-2026-10-15.json`](../tools/probe/regional/results-2026-10-15.json).
  The bounded probe can be rerun with
  `python3 tools/probe/regional/run.py --output /tmp/regional-results.json`.
- Actual SwiftUI listing cards are rendered by the currency tests for visual
  review. Images use placeholders and do not request network content.

These probes do not establish signed-in behavior, every city, location-picker
resolution, item-detail access, seller handoff, or App Store availability in
the new countries. The test suite covers parsers and region eligibility locally;
live requests stopped at the rate-limit response rather than retrying.
