# Listing comparison performance — 2026-10-02

Price comparison now fetches active and recently sold listings concurrently
through cookie-free native GraphQL requests. Coordinates and radius are sent in
the query; no Facebook login lookup, browser bootstrap, or page rendering is
needed on the normal path. Jev still receives one batch after both searches.

## Measured result

On the iPhone 17 Pro Simulator (iOS 26.3), the final production search-pair path
returned in **602 ms on a new pool and 453 ms on its next use**. The old serial
browser path took **2,108 ms** in the same benchmark session: an observed
**1,506–1,655 ms reduction (71–79%)** in the search portion of the comparison.
This is not an end-to-end Jev benchmark or a production percentile.

The query was `desk`, San Francisco, local pickup. Direct queries used
`37.779379, -122.418433` and 8 km, matching the browser's observed query
metadata. Sold searches used the last-month filter and retained only `is_sold`
results, excluding pending and unknown status. The anonymous direct probe
returned 15 active cards and six sold cards; the oldest sold card was listed
27 days earlier. These are advertised prices and seller-marked sold status,
not verified transaction prices or sale dates.

These are small, sequentially collected samples. Browser resource caches,
connection reuse, Facebook caching/ranking, request jitter, and network
variation can affect the deltas. “New pool” and “first use” do not mean a cold
OS/network/server cache. Do not add the individual savings below together.

## Per-change evidence and estimates

| Change | Observation | Interpretation |
| --- | --- | --- |
| Avoid waiting for the browser's location pill | Serial browser: 2,108 → 1,409 ms; an earlier run was 2,324 → 1,559 ms. | About 0.70–0.77 s less in these samples, but warming/order confound attribution. The structural benefit is removing a diagnostic wait of up to 2.5 s per search; savings are zero when the pill was already ready. Coordinates govern the native query, and browser fallback still reads/logs the settled location once. |
| Overlap active and sold searches | With the old 400 ms pacer and shorter browser waits: 1,409 → 1,409 ms; earlier run 1,559 → 1,400 ms. | Observed additional benefit was 0–159 ms (0–10%). It depends on page durations, pool contention, and connection reuse; concurrency is not automatically a 2× gain. For independent search times A and S with start gap G, the idealized path changes from A + S to max(A, G + S). |
| Native anonymous GraphQL instead of search-page loads | Parallel browser: 1,409 ms. Anonymous direct requests: 1,002 ms first use, then 344 and 486 ms. | Observed reduction of 407 ms first use (29%), or 923–1,065 ms warm (66–76%), relative to that browser sample. The complete production wrapper measured 602/453 ms in a later pair. Different auth contexts can produce different inventories; this measures latency, not identical result sets. |
| Remove authenticated browser bootstrap | An exploratory authenticated production pair took 2,682 ms first use / 404 ms warm; the final anonymous pair took 602 / 453 ms. | A 2,080 ms first-use difference was observed in separate runs, not a controlled causal measurement. Warm authenticated and anonymous results were similar. The certain architectural gain is no browser bootstrap or session-cookie check on anonymous comparisons. |
| Random 100–300 ms spacing instead of fixed 400 ms | Six concurrently requested slots: 2,002 → 1,066 ms in a pacing-only test, 936 ms less (47%). | Expected spacing is 200 ms, saving about 200 ms per queued gap. Six slots have five gaps: expected wait falls from 2 s to 1 s. Requests already spaced farther apart by network time save nothing. Random samples vary; this is not an HTTP throughput benchmark. |
| Earlier markup fallback | Comparison fallback now gives structured data 600 ms after rendered cards appear instead of exhausting a 20 s payload timeout. | Conditional saving approaching 19.4 s when cards appear promptly but structured payload never does, plus polling granularity. Not exercised by the successful live GraphQL runs. A local HTML regression test verifies that rendered evidence bypasses the payload timeout. |
| Publish gallery before seller details | On one final live detail read, photos were published at 662 ms and full detail returned at 1,049 ms: a 387 ms lead. | The new explicit gallery callback avoids up to the 3 s seller wait when the earlier text callback had no photos. The recorded run did not distinguish photos already present in that first callback, so 387 ms is publication lead, not a proven incremental saving. The opt-in probe now records whether the first callback already contained photos. |

The untouched-main preliminary baseline was 2,801 ms active plus 1,318 ms sold
(4,119 ms total), showing why a single before/after number should not be treated
as a stable production speedup. The table uses the later, closer-in-time
benchmark for comparison instead of selecting the slowest baseline.

## Implementation and behavior

- `MarketCheckPool` leases two independent search engines. Each branch acquires
  and releases one engine; it never holds one while waiting for a second.
  Concurrent comparisons share the bounded queue.
- `ComparableSearch` uses `AnonymousFeedClient` regardless of Facebook login.
  The API's native URLSession disables cookie storage and cookie handling.
  A nonpersistent, isolated WebView remains available for unsupported inputs
  or schema failures. Missing saved coordinates use the existing city-slug
  browser path, not a fabricated latitude/longitude.
- Coordinate and radius are now also passed by the seller price-check caller.
  Its existing sequential stage UI remains unchanged; listing-click comparison
  is the flow whose active/sold searches now overlap.
- Native requests retain query, delivery, availability, radius, and date
  constraints. Date filtering was verified against the desktop page's Relay
  variables: on UTC epoch day 20728, last month was the inclusive sequence
  `20728;20727;…;20698` (31 values). UTC arithmetic avoids local timezone/DST
  differences. This uses the device clock, as normal requests do; a materially
  incorrect device date is not covered by these measurements.
- Empty pages with advancing cursors can make up to three requests. A verified
  empty terminal response does not trigger another browser fetch. Blocks,
  network failures, cancellation, and session-change errors do not switch
  transports. Sold-search failure remains nonfatal and is recorded separately.
- Shared pacing retains the session cap and backoff. Cancelled reservations
  and reservations that encounter a block while waiting cannot send requests.
  The 100–300 ms change applies to the shared pacer, including browsing/detail.
- The main browsing session and listing-detail loader retain their existing
  authentication. Openmarket account login is still needed for the backend
  Jev call; anonymous Facebook retrieval does not remove that requirement.
- Anonymous inventory can differ from signed-in inventory even at the same
  coordinates. Native radius requests do not establish strict geographic
  enforcement by Facebook. Compare answer usefulness as well as latency.

## Ongoing measurements

`market_check_completed` and failures after searches now include:

| Field | Meaning |
| --- | --- |
| `active_queue_ms`, `sold_queue_ms` | Time waiting for an available comparison engine. |
| `active_fetch_ms`, `sold_fetch_ms` | Retrieval time after acquiring that engine, including pacer waits and any fallback. |
| `active_transport`, `sold_transport` | `anonymous_graphql` or `browser`. |
| `searches_ms` | Wall time to both searches finishing, including queueing. |
| `relevance_ms` | Client-observed evaluation RPC time, including authorization, transport, and server work; not pure Jev inference time. |
| `duration_ms` | Overall comparison time. |
| `sold_search_outcome` | Success or the existing failure category when active retrieval succeeded. |

Local logs also record each fetch's transport and duration, plus detail
`gallery_ms` and `seller_wait_ms`. Measure p50/p95 by transport and queue state;
keep failed/empty sold searches separate rather than counting them as healthy
fast answers. Timing logs introduce no listing text, account cookies, or tokens.

## Validation and reproduction

The iOS regression suite passed 107 tests, including new coverage for bounded
parallel searches, nonfatal sold failure, pending/unknown sold exclusion,
empty-page cursor recovery, cookie-isolated fallback, no navigation on native
success/block/verified-empty results, UTC midnight boundaries, early markup
fallback, and pacer spacing/cancellation/backoff.

The live probe separately verified active/sold retrieval and detail publication.
Its source and aggregate results are under `tools/probe/comparison/`. Follow
that directory's README to run it explicitly. It is excluded from normal tests.
