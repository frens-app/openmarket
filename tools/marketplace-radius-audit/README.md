# Marketplace radius audit

Measures the initial, logged-out desktop results returned by a Facebook
Marketplace search URL. It validates the radius Facebook actually requested,
opens every initial listing's item page to recover Facebook's approximate pin,
and calculates straight-line distance from the search response's own center.

The initial response is deliberately the unit of analysis. The tool does not
scroll or paginate, so a run remains comparable across the anonymous result
caps Facebook applies in different markets.

## Setup

```bash
cd tools/marketplace-radius-audit
pnpm install
pnpm exec playwright install chromium
```

## Run

```bash
pnpm run audit \
  --url 'https://www.facebook.com/marketplace/sanfrancisco/search/?query=dresser&exact=false&radius=16' \
  --output sf-dresser.json \
  --csv sf-dresser.csv
```

Chromium is headed by default so the tested surface is visibly a desktop
browser. Pass `--headless` for unattended rechecks. A new Playwright context is
created with no storage state or cookies; the run fails unless Facebook's
search query has actor ID `0` and the page exposes a Log In control.
If Chrome is already installed, `--browser-channel chrome` can use it instead
of Playwright's downloaded Chromium.

`--max-results` defaults to 24. Facebook may return fewer results to an
anonymous browser; the report records both the GraphQL `count` requested and
the number actually returned. The tool does not manufacture or paginate extra
results.

Item pages are loaded strictly one at a time. Before every item request,
including the first, the tool waits a fresh random interval between 3 and 6
seconds. Override the range with `--delay-min-ms` and `--delay-max-ms`; do not
set it to zero for routine collection. Each selected delay and resulting HTTP
status is retained under the listing's `audit` field. If Facebook returns HTTP
403 or 429—or displays a recognizable temporary-block/rate-limit interstitial—
the run stops immediately and performs no automatic retry.

## Radius validation

Before opening any item, the tool compares three independent values:

1. `radius` in the input URL, interpreted as kilometres.
2. The visible Marketplace location/distance filter, converting miles to km.
3. `filter_radius_km` in `CometMarketplaceSearchContentContainerQuery`.

It stops and writes a partial JSON report if they differ by more than 0.25 km.
This catches saved-account overrides, unit misunderstandings, redirects, and
Facebook experiments before they contaminate a distance result. Use
`--allow-radius-mismatch` only for investigations specifically about the
mismatch.

The report always retains the directly returned targeting metadata:

- `filter_radius_km`
- `filter_location_latitude`
- `filter_location_longitude`
- `buyLocation.latitude` / `buyLocation.longitude`
- GraphQL requested and returned initial result counts

## Listing measurement

For every initial listing, the tool records the requested non-PII fields from
the search response, then loads `/marketplace/item/<listing-id>/` and extracts
`item_location` (falling back to the item-scoped `location` field). Distance is
the Haversine straight-line distance from Facebook's own filter center to that
approximate pin.

Straight-line distance is a lower-bound travel estimate. Driving distance is
usually longer, especially around bridges or water. Facebook's pins are also
fuzzed and quantized; the page itself labels them "Location is approximate."

JSON separates direct response values from derived measurements:

```json
{
  "response": {
    "name": "Dresser",
    "price_text": "$25",
    "city": "San Mateo",
    "approximate_latitude": 37.570495605469,
    "approximate_longitude": -122.32727050781
  },
  "derived": {
    "distance_km": 24.6,
    "distance_miles": 15.29,
    "outside_filter_radius": true
  }
}
```

## Privacy boundary

The auditor does not read or store seller names, profiles, descriptions,
photos, messages, addresses, cookies, or account data. Listing ID, requested
listing name, price, city, delivery mode, and Facebook's published approximate
pin are retained. Email addresses, URLs, and phone-like strings are redacted
from listing text fields before output.

## Tests

```bash
pnpm test
```
