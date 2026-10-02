# Discover radius and filter measurements

Measured 2026-10-02 against the live Facebook Discover GraphQL operation,
without cookies or an account. Production behavior was not changed.

## Radius improves the initial page, but does not bound pagination

The app sends `radius: 65000` for every Discover query, even when the user
selects a smaller radius. The signed-in client builds its variables using the
same request builder; signed-in response behavior was not tested in this run.

The test used `MarketplaceCometBrowseFeedLightPaginationQuery`, document ID
`28036163469355579`, origin 37.7793, -122.419, `count: 1`, and
`useSDFPath: true`. Each variant began with a null cursor and followed its own
returned cursor for one additional page. Radius values use the observed
meter-scale request convention: 65,000, 8,000, and 2,000.

| Radius | First page | San Francisco city on first page | Second page | San Francisco city on second page |
|---|---:|---:|---:|---:|
| 65 km control | 25 | 2 | 6 | 1 |
| 8 km | 25 | 20 | 6 | 0 |
| 2 km | 25 | 20 | 6 | 1 |
| 65 km repeated control | 25 | 2 | 6 | 1 |

The repeated control shared 23 of its 25 first-page IDs with the initial
control. The smaller-radius first pages each shared only one ID with that
control. This is evidence of a real radius effect beyond ordinary feed churn.

However, the 8 km second page contained Oakland, San Leandro, Vallejo, Dublin,
El Sobrante, and El Cerrito. The 2 km second page also contained distant cities.
Both narrow first pages still included five cards outside San Francisco.
A second comparison with `useSDFPath: false` reproduced the pattern: 2 versus
20 San Francisco cards on the first page, and distant cities on the second.
Changing that flag did not solve the pagination problem.

All measured pages were HTTP 200, advanced their cursor, and reported
`has_next_page: true`. Initial pages carried delivery types on 20 cards;
the remaining first-page cards and every second-page card had unknown delivery.
This matches the previously documented top-picks/general-card split, but does
not establish the server's internal reason for the different radius behavior.

City names establish that some cards are far outside the requested area.
They do not prove all 20 San Francisco cards fall within 8 km or 2 km: the
responses contained no listing coordinates. No exact in-radius yield is claimed.

## Discover exposes refinement inputs, but the tested values did not enforce filters

An ephemeral macOS WebView loaded the public Discover page. Inspection of its
current Relay query metadata confirmed these home-feed arguments:
`after`, `buy_location`, `first`, `radius`, `refinement`, and `use_sdf_light_path`.
There is no dedicated delivery-method variable in this observed operation.

The loaded `MarketplaceCometBrowseFeedLight.react` component passes four
refinement fields when it refetches:

- `locality`
- `max_price_cents`
- `min_price_cents`
- `text`

Two-page anonymous comparisons at radius 8,000 returned:

| Refinement | First-page result | Second-page result |
|---|---|---|
| null, control | 25 cards, 20 San Francisco | 6 cards, distant cities |
| `{"locality":"local"}` | 25 cards, 20 San Francisco | 6 cards, distant cities |
| `{"max_price_cents":1000}` | 25 cards, **20 above $10** | 6 cards, **5 above $10** |
| `{"text":"local pickup within 5 miles"}` | 25 cards, 20 San Francisco | 6 cards, distant cities |

The field names were observed in Facebook's code. The `local` string was an
experimental candidate; its exact supported vocabulary was not established.
HTTP 200 therefore demonstrates acceptance of the request, not application of
the filter. The price experiment provides a directly measurable negative:
that input did not enforce its expected cap in this anonymous context.

No working shipping-only exclusion was demonstrated. The sample had no known
shipping-only cards to provide a positive control; one card per first page
supported both in-person pickup and shipping. General cards lacked delivery
metadata. This cannot rule out a refinement available to signed-in accounts,
a different locality value, or a separate Facebook browsing surface.

## Implications for the app

Sending the user's selected radius in meters is a justified candidate for
improving first-page relevance. Validate it in a signed-in session before
assuming the same benefit there, and retain local distance filtering.

It does not replace pagination work. Later pages still contain only six raw
cards and can lose most or all of them to local filtering. Continue toward a
visible-card target within a bounded budget, and represent filtered-empty
batches separately from network errors and true end-of-feed.

Do not ship a Discover shipping/refinement filter based only on the presence
of these fields. A valid UI-generated locality value and a signed-in comparison
are still needed to establish that capability.

## Reproduction and evidence

- [Probe instructions and source](../tools/probe/discover_filters/README.md)
- [Radius results](../tools/probe/discover_filters/radius-results-2026-10-02.json)
- [Refinement results](../tools/probe/discover_filters/refinement-results-2026-10-02.json)
- [Alternate path results](../tools/probe/discover_filters/alternate-path-results-2026-10-02.json)
- [Observed inputs](../tools/probe/discover_filters/observed-inputs-2026-10-02.json)

Twenty bounded comparison requests plus one initial baseline request were made.
Four temporary, cookie-free WebViews inspected public code; ordinary page loads
may issue their own requests. Only aggregate result data and query metadata are
retained. The older URL-parameter measurements in `filter-parameters.md` concern
a different input path and do not negate the direct GraphQL radius result.
