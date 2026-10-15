# Marketplace radius audit

Measures the initial, logged-out desktop results returned by a Facebook
Marketplace search URL. It validates the radius Facebook actually requested,
opens every initial listing's item page to recover Facebook's approximate pin,
and calculates straight-line distance from the search response's own center.

The initial response is deliberately the unit of analysis. The tool does not
scroll or paginate, so a run remains comparable across the anonymous result
caps Facebook applies in different markets. Current reports use schema version
2; sponsorship, fulfillment, payload health, and raw feed-unit fields were
added after the original radius-only pilot.

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

It stops and writes a partial JSON report if values differ by more than 0.25
km. A disagreement is reported as `url_response_mismatch` or
`visual_mismatch`. Failure to find visible filter text is separately reported
as `visual_unavailable`, so a UI/parser change is not mislabeled as evidence
that Facebook used another radius. Use `--allow-radius-mismatch` only for
investigations specifically about a mismatch. Use
`--allow-missing-visual-radius` to proceed when URL and GraphQL agree but the
visible value cannot be parsed; the caveat remains in the report.

The report always retains the directly returned targeting metadata:

- `filter_radius_km`
- `filter_location_latitude`
- `filter_location_longitude`
- `buyLocation.latitude` / `buyLocation.longitude`
- GraphQL requested count, raw feed-unit count, and listing count
- per-unit sponsorship status and the evidence used to classify it

## Feed and fulfillment denominators

Raw feed units are retained before non-listing units are removed. Each unit and
listing has nullable `is_sponsored`, a status of `sponsored`, `organic`, or
`unknown`, and an evidence array. Explicit sponsor fields, a card-level visible
"Sponsored" label, and sponsored story/node types take precedence. The known
organic `POST` / `MarketplaceFeedListingStoryObject` shape is classified as
organic; unfamiliar shapes remain unknown rather than silently becoming
organic. Summary counts keep sponsored, organic, and unknown units separate.

`delivery_types` remains null when Facebook did not return it. The derived
fulfillment class is one of `local_only`, `shipping_only`,
`local_and_shipping`, `nonlocal_delivery_only`, or `unknown`. The summary's
`organic_local_handoff_count` includes only listings explicitly classified as
organic with a local handoff token; unknown sponsorship or fulfillment never
enters that denominator.

## Listing measurement

For every initial listing, the tool records the requested non-PII fields from
the search response, then loads `/marketplace/item/<listing-id>/` and extracts
`item_location` (falling back to the item-scoped `location` field). Distance is
the WGS84 ellipsoidal geodesic distance from Facebook's own filter center to
that approximate pin, calculated with the Vincenty inverse method.

Straight-line distance is a lower-bound travel estimate. Driving distance is
usually longer, especially around bridges or water. Facebook's pins are also
fuzzed and quantized; the page itself labels them "Location is approximate."

The detail audit distinguishes payload wait success, timeout, and error; target
listing match presence; coordinate-field presence; and valid, absent, or
invalid coordinates. Null coordinates are never converted to `(0, 0)`.
Missing-coordinate counts are broken down by the exact `delivery_types` set so
systematic missingness among shipping or commerce listings is visible.

JSON separates direct response values from derived measurements:

```json
{
  "response": {
    "name": "Dresser",
    "price_text": "$25",
    "city": "San Mateo",
    "is_sponsored": false,
    "delivery_types": ["IN_PERSON"],
    "approximate_latitude": 37.570495605469,
    "approximate_longitude": -122.32727050781
  },
  "derived": {
    "distance_km": 24.6,
    "distance_miles": 15.29,
    "outside_filter_radius": true,
    "fulfillment_class": "local_only",
    "local_handoff_available": true,
    "shipping_available": false
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
