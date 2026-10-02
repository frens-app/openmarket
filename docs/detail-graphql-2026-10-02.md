# Listing detail GraphQL experiment — 2026-10-02

Direct detail and gallery queries work in the existing signed-in WebKit
session and through cookie-free native requests. Both routes are now used by
the app, with browser fallback. The initial experiment is recorded below;
the isolated anonymous comparison and implementation follow-up appear at the end.

## Measurements

The final run used an iPhone 17 Pro Simulator on iOS 26.3, two active desk
listings and one sold desk listing from San Francisco search results.

| Listing | Current browser loader, complete | Signed-in direct details + gallery |
| --- | ---: | ---: |
| Active 1 | 2,125 ms | 350 ms |
| Active 2 | 2,045 ms | 491 ms |
| Sold | 1,574 ms | 488 ms |

The first browser gallery was available at 1,755 ms, before complete seller
enrichment. The direct pairs are sequential, include shared request pacing,
and use one already-loaded authenticated document. The second and third direct
pairs change only the requested listing ID; they do not navigate their browser
to those listings. A separate browser engine loads the comparison pages.

These are small samples, not production percentiles or a controlled cold-cache
benchmark. The first listing was loaded in the browser before its direct
request; the other two were requested directly before the comparison page load.
Connection reuse, server caching and ordering can affect the differences.
The direct measurements exclude initial authenticated browser preparation,
photo downloads, and native UI rendering. The production loader already
publishes cached details and partial results before completion.

An earlier run returned the additional active/sold pairs in 679/405 ms against
browser loads of 1,906/1,311 ms. The direction was consistent in this sample,
but the exact saving is not established outside the Simulator session.

## Observed operations

Both use `POST https://www.facebook.com/api/graphql/` with form encoding:

| Operation | Observed document ID | Returned data |
| --- | --- | --- |
| `MarketplacePDPContainerQuery` | `38856723643971385` | Core listing, location, availability, delivery, attributes, seller and badges |
| `MarketplacePDPC2CMediaViewerWithImagesQuery` | `10059604367394414` | Gallery photo IDs, URLs, dimensions, accessibility captions and video field |

The item page's JSON preload records expose `queryName`, `queryID`, and
`variables`. Both operations take `targetId`. The detail operation also has
context and Relay provider variables, preserved in the saved observation.
Do not assume these private document IDs or feature flags remain valid.

For authenticated requests the probe uses `getAsyncParams('POST')` and the
current actor inside the app's existing WebKit session. Cookies and CSRF
tokens remain there. Only noncredential query metadata is supplied to the
anonymous URLSession, which disables cookie storage and handling.

Both responses place the requested listing at
`data.viewer.marketplace_product_details_page.target`. Read this explicit
path and validate its ID; do not recursively collect other listings or seller
objects from related content. The observed replies were single JSON records.
Streamed responses and partial GraphQL errors still need production handling.

## Field comparison

| Current feature | Direct source | Observation |
| --- | --- | --- |
| Description | `target.redacted_description.text` | Exact match on both active listings. Sold response contained 754 characters, including the browser scraper's complete 145-character substring. |
| Gallery | Media query: `target.listing_photos[].image.uri` | Exact CDN photo-ID sets matched all three pages: 2, 3 and 3 images. Returned image longest sides were 960 px; full-resolution equivalence was not tested. |
| Condition | `target.attribute_data[]`, attribute `Condition` | Present on all three; current browser detail model missed it on all three. Use the provided label. |
| Posted time | `target.creation_time` | Numeric timestamp present on all three. Format the native relative date; current scraper returned no posted text in these samples. |
| Location label | `target.location_text.text` | Matched all three. |
| Approximate map point | `target.location.latitude/longitude` | Matched both active pages; present on sold response where the browser model missed coordinates. |
| Sold/pending | `target.is_sold`, `target.is_pending` | Matched all three, including the sold listing. |
| Delivery | `target.delivery_types` | Normalized fulfillment flags matched all three. |
| Seller identity | `target.marketplace_listing_seller.name/id` | Matched all three signed-in pages. |
| Seller join year | `marketplace_listing_seller.join_time` | UTC year matched all three displayed join years. |
| Seller rating/count | `marketplace_ratings_stats_by_role_v2.seller_stats` | Matched the page on the public-rating seller. Combined buyer/seller count differed, so do not substitute the combined statistics. |
| Highly rated badge | `target.commerce_badges_info.source_summary` | Returned Facebook's actual “Highly rated on Marketplace” label on the badged seller. Another returned “Very Responsive on Marketplace”; a third had null summary and an empty badge array. |

Rating privacy is essential: two sellers' responses contained numeric stats
while `seller_ratings_are_private` and combined `ratings_are_private` were
true; the page did not display those ratings. A replacement must honor those
flags and not expose a numeric rating merely because the response includes it.
The probe persists only comparison outcomes and privacy booleans, not those
ratings. An absent badge remains unknown; never invent a rating threshold.

No sampled visible feature requires retaining DOM extraction on the signed-in
success path. That is a feasibility result, not complete category coverage.
Vehicles, rentals, shipping purchases, removed listings, restricted listings,
videos, private/unavailable attributes, localization, and session changes were
not exhaustively tested.

## Anonymous result

The two direct queries succeeded without cookies or CSRF tokens using the same
native headers as the existing feed client (`OpenMarket/0.0.1 (iOS)` and
`Accept: application/json`). Earlier requests with the desktop browser UA and
without that Accept header returned application error `1357054` despite HTTP
200. Both headers changed together, so the cause was not isolated.

On the final anonymous active listing, gallery retrieval took 115 ms and
detail retrieval took 1,513 ms. An earlier pair measured 108/1,076 ms. These
are sequential individual timings, not a production parallel-pair benchmark.
The detail response included approximately 457 KB of data, including resource
metadata in its extensions; successful authenticated core responses ranged
from approximately 17 KB to 221 KB in the final run.

Description, gallery photo IDs, map coordinates, location, delivery and
availability matched the authenticated browser baseline for that listing.
Condition and creation time were present. `marketplace_listing_seller` was
null: seller name/ID, join year and ratings are unavailable on this path.
Anonymous badge coverage on a badged seller was not tested. Do not replace
signed-in retrieval with anonymous retrieval and expect seller parity.

## Implementation direction

1. Add a dedicated detail decoder and authenticated detail client, reusing a
   prepared Facebook browser context and shared pacing/backoff. Fetch the
   observed core and media operations by listing ID without page navigation.
   Preserve staged publication; requests can overlap subject to the pacer.
2. Keep authentication context in cache and cancellation checks, preserve
   rating privacy, map explicit attribute/badge fields, and validate both
   returned target IDs before merging.
3. Retain the current page loader for unsupported shapes or expired query
   metadata. Blocks must back off rather than trigger an immediate fallback.
4. Evaluate anonymous detail separately. It works, but this probe did not
   establish a latency advantage against an anonymous browser baseline.
5. Before shipping, verify bootstrap from the actual Search/Discover context,
   cold app startup, multiple categories, removed listings, streamed responses,
   request cancellation and physical-device latency. The probe reused an item
   document; it did not benchmark starting from an untouched feed document.

The opt-in probe, noncredential operation metadata and aggregate results are in
[`tools/probe/detail_graphql/`](../tools/probe/detail_graphql/). It passed live
checks with HTTP 200 and no GraphQL errors on successful requests. It is not
included in the ordinary test target.

## Isolated anonymous comparison and implementation

Implementation was tested on a newly created **Openmarket Detail QA** Simulator
(iPhone 17, iOS 26.3). The user's already-running iPhone 17 Pro was not installed
to, relaunched, or signed out during this follow-up. No Facebook login or
session transfer was needed on QA.

The final anonymous comparison, with request order alternated on the second
listing, returned:

| Listing | Native core + gallery | Browser gallery available | Browser complete |
| --- | ---: | ---: | ---: |
| Active 1 | 1,125 ms | 1,522 ms | 4,551 ms |
| Active 2 | 975 ms | 1,711 ms | 4,749 ms |
| Sold | 1,042 ms | 1,614 ms | 4,656 ms |

Native data arrived 26–43% earlier than the browser's gallery in these samples.
Browser completion includes roughly three seconds waiting for absent seller
information, so the larger completion-time improvement must not be presented
as an equal improvement to first useful display. Photo downloads are excluded.
An earlier isolated run measured native 1,018/1,147/1,075 ms against browser
gallery 1,592/1,455/2,288 ms, supporting the switch but not a stable percentile.

All gallery photo-ID sets, location labels, availability and fulfillment
matched. Native detail preserved the full sold description (754 vs 145
characters), supplied its missing coordinates, and supplied condition and
posted time on all three. Anonymous seller data is **optional**, not invariably
absent: one earlier anonymous response included a seller name, while the final
run returned none. The initial assertion that every anonymous seller must be
nil failed and was removed; final coverage tests instead verify preserved
listing fields. Numeric private ratings remain suppressed in both routes.

`DetailEngine` now routes canonical listing IDs through `DetailGraphQLClient`:

- Logged out: ephemeral URLSession, no cookie handling/storage, no browser
  bootstrap. Core and media requests overlap subject to shared pacing.
- Signed in: same-origin fetch in a prepared detail, Search, or Discover
  WebView with a matching actor. Query tokens stay in that WebView. Without a
  prepared context, the ordinary item-page fallback warms the detail browser
  for subsequent opens. The feed itself is never navigated by this client.
- Core details publish as soon as ready, then merge the gallery. Cancellation,
  a newer listing request, or an account change prevents stale publication.
- Unsupported schemas/queries retain the browser fallback. HTTP 403/429,
  recognized GraphQL rate limits, network failures and account changes do not
  trigger a second transport. Request blocks apply shared backoff.
- The decoder scopes every response to the requested target ID, handles
  target-scoped streamed object patches, preserves unknown fields, and uses
  seller-only statistics only when their privacy flag explicitly permits it.

A separate live production `DetailEngine.loadDetail` call for a plant listing
returned five photos in **1,031 ms** with `anonymous_graphql` transport and a
nil browser URL: no hidden page navigation occurred.

Validation: **123 tests passed**, comprising the normal suite plus 15 new
detail regressions and one opt-in live production probe. The three-listing
anonymous comparison also passed separately. Coverage includes private and
unknown rating flags, target identity, unrelated gallery exclusion, streamed
patches/late errors, request cookie isolation, backoff, cancellation, account
changes, superseded opens and staged publication. The authenticated transport
was exercised against a controlled prepared feed document with mocked responses
and no navigation. A fresh live authenticated production run on QA was not
performed because that separate Simulator remained logged out; the earlier
live signed-in operation measurements above remain the network evidence.

The opt-in tests were removed from the normal Xcode test sources after the
runs. Aggregate anonymous results are in
[`anonymous-results-2026-10-02.json`](../tools/probe/detail_graphql/anonymous-results-2026-10-02.json).
