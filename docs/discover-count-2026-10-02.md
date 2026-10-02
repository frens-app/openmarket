# Discover count measurements

Measured 2026-10-02 using the live, anonymous Discover GraphQL operation.
Increasing `count` increases subsequent-page size, with an observed plateau
near 30 listings. Production request behavior was not changed.

## Method

Used `MarketplaceCometBrowseFeedLightPaginationQuery`, observed document ID
`28036163469355579`, a San Francisco origin (37.7793, -122.419), radius 8,000,
`useSDFPath: true`, and no refinement. Requests were cookie-free HTTP POSTs.
Only `count` varied. No account settings or listings were modified.

The first comparison ran count 1, 2, 4, 8, then 1 again. Each variant started
with a null cursor and followed its own returned cursors for three pages.
The decoder counted only the requested home-feed connection and its streamed
edges, matching the production decoder's selection of top-picks and general
listing cards. Canonical IDs were retained in memory to measure duplicates;
saved results contain only aggregates, cities, and request metadata.

## Results

| Count | First-page listings | Second page | Third page | Subsequent request time |
|---|---:|---:|---:|---|
| 1 | 26 | 5 | 6 | 219–221 ms |
| 2 | 26 | 11 | 12 | 264–294 ms |
| 4 | 37 | 24 | 24 | 357–401 ms |
| 8 | 43 | 30 | 30 | 441–461 ms |
| 1, repeated control | 26 | 6 | 5 | 212–228 ms |

All 15 requests returned HTTP 200, advancing cursors, and
`has_next_page: true`. There were no duplicate listing IDs within a page or
across the three pages of each variant. This does not imply uniqueness across
separate variants, which intentionally start from the same feed origin.

The first page includes one top-picks unit containing 20 listings, plus
individual general-listing edges. Thus `count` is neither an exact card count
nor an exact returned edge count. Subsequent-page sizes scaled approximately
six listings per count unit until the observed plateau.

Subsequent responses grew from roughly 20–23 KB at count 1 to 86 KB at count 4
and 107 KB at count 8. These are single-run observations, not latency percentiles.
First-page requests took 2.7–4.3 seconds and did not show a monotonic timing
relationship with count.

## Checking the plateau

A second probe obtained one fresh count-1 first page, then sent count 5, 8,
and 16 from the **same returned cursor**. These were independent comparisons,
not three sequential appends.

| Count | Listings | Response bytes | Request time | ID overlap with count 5 |
|---|---:|---:|---:|---:|
| 5 | 29 | 103,492 | 402 ms | baseline |
| 8 | 29 | 103,492 | 388 ms | 29 of 29 |
| 16 | 29 | 103,492 | 373 ms | 29 of 29 |

All three responses contained the same set of 29 canonical listing IDs, with
no overlap with the seed page. Together with the fresh count-8 chain above,
this supports an effective plateau at roughly 30 listings, reached at count 5.
It does not establish a permanent or universal server limit.

## Implications

A practical candidate is count 1 for the initial page and count 5 when following
a cursor. That preserves the existing initial load and provides approximately
five times as many raw candidates per pagination request in this experiment.
Values above 5 offered no additional inventory in the matched-cursor test.

This is an efficiency improvement, not a locality fix. With radius 8,000,
the 29-card matched page included Vallejo, Montara, and other distant cities;
only one card reported San Francisco as its city. The response had city names,
not listing coordinates, so no exact in-radius yield is claimed.

Local filtering and pagination toward a visible-card target are still needed.
Avoid treating a larger raw batch as a successful top-up when most cards are
filtered out. All second and third pages also lacked delivery metadata on their
general-listing cards; unknown delivery must not be counted as shipping-only.

These measurements were anonymous. The app's signed-in client shares the same
variable builder, but the signed-in server behavior still needs validation.
No production default was changed as part of this investigation.

## Evidence and reproduction

- [Probe source](../tools/probe/discover_filters/count.py)
- [Three-page comparisons](../tools/probe/discover_filters/count-results-2026-10-02.json)
- [Matched-cursor comparison](../tools/probe/discover_filters/count-cap-results-2026-10-02.json)
- [Probe instructions](../tools/probe/discover_filters/README.md)

The two runs made 19 requests in total. HTTP/GraphQL errors, cyclic or missing
cursors, oversized responses, and an empty subsequent page stop the probe.
