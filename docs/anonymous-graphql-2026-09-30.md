# Anonymous feed pagination can bypass the browser

**Measured:** 2026-09-30, repository `d5101d7`.
**Scope:** native anonymous feeds and authenticated, session-backed GraphQL feeds.

Direct, anonymous GraphQL requests returned paginated Search and Discover
listings. They did not need a Facebook account, cookies, `fb_dtsg`, `lsd`,
`jazoest`, or a browser-generated starting cursor. This supports replacing the
hidden-browser feed pipeline with a native HTTP client and native list rendering.
It does not establish a supported public API or long-term availability.

## What was actually tested

The initial discovery used a macOS `WKWebView` with a new `.nonPersistent()`
store and the exact desktop/mobile user agents in `BrowserSession.swift`.
The desktop viewport was 1280 × 900. The only observed Facebook cookies were
`datr`, `sb`, and `wd`; there were no `c_user` or `xs` account cookies.
Document-start hooks recorded fetch, XHR, and WebSocket traffic.

Query IDs and input variables came from the page's loaded Relay modules and
its actual pagination requests, rather than a third-party list of IDs.
Subsequent HTTP probes used a native `OpenMarket/0.0.1 (iOS)` user agent and
no cookie jar. Every run was bounded; cursors came from the preceding response.
The cold runs started with `cursor: null`.

| Route / method | Observed result |
|---|---|
| `www.facebook.com/marketplace/sanfrancisco/search/?query=desk`, desktop UA in WebKit | 15 initial cards; embedded cursor and `has_next_page: true`. Dismissing the login overlay and scrolling generated real GraphQL pagination requests. |
| Same URL, mobile UA in WebKit | WebLite, 401 `data-mcomponent` elements, zero item anchors, no captured GraphQL calls. A `kaios-d.facebook.com` WebSocket frame carried 26 item routes. |
| `m.facebook.com/marketplace/sanfrancisco/search/?query=desk`, mobile UA | WebLite and the same socket host, but only related searches and no item routes in this observation. This is not proof that the host never serves listings. |
| `www.facebook.com/marketplace/sanfrancisco/`, desktop UA | Browse page with 18 rendered item links, a browse pagination operation, and initial variables. |
| Anonymous location GraphQL operation already used by the app | HTTP 200, `sanfrancisco`, 144 ms. Positive control for native anonymous GraphQL access. |
| Search GraphQL, starting from a browser cursor | Four requests: **28 + 29 + 29 + 28 = 114 unique listings**, no duplicates; **1119 / 542 / 1075 / 535 ms**. |
| Search GraphQL, starting with null cursor | **15 + 28 = 43 unique listings**, **334 / 558 ms**, advancing cursors. |
| Browse GraphQL, starting with null cursor | **25 + 6 + 6 = 37 unique listings**, **3027 / 277 / 321 ms**, advancing cursors. |
| Search GraphQL in iOS 26.3 Simulator, iPhone 17 Pro | Fresh ephemeral, cookie-disabled `URLSession`: **15 + 28 listings**, **340 / 397 ms**. No WebView was needed for these requests. |

All direct feed responses were HTTP 200 with no GraphQL errors and
`has_next_page: true`. Timings are individual observations, not percentiles.
Counts across separate runs must not be added together as unique inventory.
The macOS UA comparison is not a physical-iPhone browser test; the direct
native HTTP path was independently confirmed on iOS Simulator.

The ordinary curl desktop-page request returned an HTTP 400 error page while
WebKit successfully rendered the same route. That negative did not predict
the native GraphQL result. One sandboxed command also failed DNS resolution;
that is an environment failure, not Facebook refusing a query.

## Request shape

Endpoint: `POST https://www.facebook.com/api/graphql/`, form encoded.

Common fields: `__user=0`, `av=0`, `__a=1`, `__comet_req=15`,
`fb_api_caller_class=RelayModern`, `fb_api_req_friendly_name`,
`server_timestamps=true`, `variables`, and `doc_id`.

| Purpose | Operation | Observed document ID |
|---|---|---|
| Search | `CometMarketplaceSearchContentPaginationQuery` | `27212616558440397` |
| Browse / Discover | `MarketplaceCometBrowseFeedLightPaginationQuery` | `28036163469355579` |

These are private, build-dependent IDs. Their future lifetime was not measured.
Do not turn them into permanent constants with no failure path. The checked-in
probe configurations contain the exact public variables observed in this run.

Search used `count: 24`, a null/returned cursor, a query of `desk`, and the
page's San Francisco coordinate/radius parameters. The server returned 15 on
the initial request and 28–29 on later requests; requested count is not an
exact card-count contract. One browser-generated response had zero edges but
an advancing cursor and `has_next_page: true`. Empty edges alone do not prove
exhaustion.

Browse used the page's `count: 1`, `useSDFPath: true`, coordinate and radius,
plus its Relay provider flags. Its count is not a literal listing count either.
The observed response contained seven newline-separated JSON records: initial
data, streamed edges, and a deferred `page_info`. A single `JSONDecoder.decode`
over the entire body cannot parse this format.

## What data survives pagination

**Search:** all 114 listings in the four-page run had canonical listing ID,
title, `creation_time`, price, cover photo, location, delivery types, and sold
state. The fact that later responses are not embedded back into the page HTML
does not mean they lack structured data.

**Browse:** two shapes must be normalized separately:

- Top-picks listings contain the familiar `marketplace_listing_title`,
  `listing_price`, `primary_listing_photo`, and other listing fields.
- `MarketplaceFeedGeneralListingObject` carries title and price in `data`,
  canonical ID and creation time in `listing`, city in `entity.location`, and
  the photo in `photo.default_image`. `data.product_item_id` is different from
  `listing.id` in the inspected card; do not substitute it for the item URL ID.

All 37 browse cards had ID, title, price, photo, city, and creation time. Only
20 top-picks cards carried delivery and sold fields. Those fields remain
unknown on the general cards. Their price uses `amount_with_offset` plus a
currency code; production normalization must account for currency minor units.

The probe initially counted only objects with `marketplace_listing_title`,
which misleadingly reported zero listings on browse pages 2 and 3. Inspecting
the response types and actual title fields revealed six general cards on each.
The committed results and parser include both shapes.

## Where the current implementation waits

The feed already uses the desktop surface inside an iOS `WKWebView`.
Switching to another browser UA alone does not remove the work below.

| Current code | Work on the path to visible cards |
|---|---|
| `DesktopFeedEngine.load` | Navigate, then wait for both payload harvest and location-pill read. The pill can wait 2.5 s even if payload is ready. |
| `DesktopFeedEngine.harvest` | Repeated whole-document extraction, up to 20 s before markup fallback when no payload appears. |
| `DesktopFeedEngine.scrollOnce` | Scroll a hidden DOM container; poll every 50 ms, up to 900 ms per attempt; a stalled retry adds 700 ms and end confirmation can add 2 s. |
| `ListingStore.loadMore` | Up to three hidden scrolls to seek six visible cards. |
| `DiscoverFeed.scrollForMore` | Up to fourteen hidden scrolls, harvesting and filtering each window. |
| `ListingStore.absorb` / `DiscoverFeed.nearby` | Await city geocoding before publishing cards. The geocoder's nominal five-second deadline is checked between batches, not enforced on an in-flight lookup. |
| `RequestPacer` | Shared 400 ms minimum spacing for operations that claim a slot; preserve this behavior in a native client. |

Pagination does not currently reload the entire page on every step; it drives
the existing browser's scroll pipeline. Searches and browse reloads do navigate.
Anonymous pagination is also disabled by application policy:
`DesktopFeedEngine.canLoadMore` requires `.authed`, and Discover marks an
anonymous first page terminal. Those guards describe the chosen UI path, not
the direct endpoint's measured capability.

To test the conversion hypothesis, the exact current
`DesktopScripts.extractSearchPayload` ran ten times on a detached DOM built
from the captured 990,265-character search page. It extracted 15 listings in
**2–4 ms** per invocation in macOS WebKit, including HTML serialization and
the extractor's output stringify. This excludes live-page rendering, the
native bridge and Swift ingestion. On iOS Simulator, Foundation JSON parsing
and feed extraction took **0.67 / 1.71 ms** for the two direct responses.
Neither measurement is a full app frame-time profile or a benchmark on a
physical phone. They do not support blaming simple data conversion for
multi-second delays; browser/network waits and repeated orchestration are
the stronger candidates.

## Recommended implementation

### Follow-up: coordinates and authenticated detail

Three additional cookie-free Search requests varied only the coordinate:
downtown Manhattan `(40.706, -74.009)`, uptown `(40.807, -73.962)`, then the
same downtown coordinate again. Query `desk`, radius 65 km, null cursor and
all other variables stayed fixed. Each returned 15 listings. Downtown and
uptown shared 11 IDs; the downtown repeat matched all 15 original IDs.
Responses took 792 / 695 / 287 ms. This supports coordinate-sensitive search
selection without the browser picker. It does not establish strict radius
enforcement, distance accuracy, or equivalent behavior for Browse.

Distinguish the search center from the listing's own approximate coordinate:
the inspected anonymous Search response supplied `location.reverse_geocode`,
not per-listing latitude/longitude. All 15 `marketplace_listing_seller` fields
were null. The existing item-detail path is still needed for those richer
fields. Earlier signed-in detail measurements in `logged-in-findings.md`
found seller identity, ratings when present, and listing coordinates on the
desktop surface; those fields were not freshly re-tested authenticated here.

Authenticated direct pagination was subsequently verified in the signed-in
app's WebView; see the authenticated implementation below. Requests use the
query metadata and request fields supplied by that page. Modest request volume
does not by itself establish endpoint support or prevent account challenges.

### Feed migration

Add an anonymous native feed client with two adapters (Search and Browse),
normalizing directly into the existing listing model. Keep opaque cursors and
query/location/filter state together. Decode responses off the main actor,
deduplicate by canonical ID, and prefetch one bounded page when the reader
approaches the end. Keep the current stable-row publishing behavior.

Preserve the shared request pacing/backoff, cancellation, and generation
checks. A failed query or schema mismatch should fall back to the existing
browser engine; a 403/429 should back off without immediately retrying through
another transport. Treat missing data as unknown. Handle partial GraphQL
errors, streamed records, unchanged/repeated cursors, and empty advancing pages.

A browser bootstrap may still be useful to refresh query metadata after it
changes, but it is **not required per page or even for the initial data request
with the currently measured IDs**. Keep WebKit for account login, item detail,
and the fallback path. Anonymous HTTP requests should remain cookie-isolated;
the current production `BrowserSession` auth labels share a persistent store
and are not isolation boundaries.

Before making this the default, verify filter and sort parity, other locations
and currencies, browse card ID-to-detail alignment, cold starts on physical
iPhones, and long-session failure behavior. This run established bounded
pagination, not indefinite availability, all filters, or a production SLA.

## Reproduce

From the repository root, with Python 3.9+ and network access:

```sh
python3 tools/probe/anonymous_graphql/run.py search --pages 2
python3 tools/probe/anonymous_graphql/run.py browse --pages 3
```

The probe has no third-party dependencies, does not accept or store account
cookies, prints aggregate counts/timing/coverage, and stops after at most five
requests. `--doc-id` overrides an expired ID. It stops on HTTP/GraphQL failures,
missing/repeated cursors, or two consecutive pages without new cards.
`--response-file` parses a local saved response without network traffic.

Exact observed configurations and sanitized results are in
`tools/probe/anonymous_graphql/`. The parser was checked against all nine saved
desktop HTTP responses, including streamed browse pages and both card shapes.
Raw page captures, cookie values, response cursors, and listing inventories are
not committed.

## Implemented guest feed path

`AnonymousFeedClient` now supplies cookie-isolated native pages to
`ListingStore` and `DiscoverFeed`. The decoder reads the requested connection,
including Browse's streamed edges and deferred page information, and maps both
card shapes into `PayloadListing`. Canonical IDs deduplicate pages; the existing
listing/photo identity remains compatible with saved listings and detail caches.

Search requests preserve the observed delivery switches, condition list,
price bounds in minor units, availability flag, and uppercase sort values.
The default local-pickup Search was rechecked through the production Swift
client: 24 + 24 new listings in 465 / 291 ms. Browse returned 25 + 6 in
3000 / 174 ms. The production decoder also matched all nine saved responses.

Selected-place coordinates now supply native requests and participate in the
search cache key. A changed coordinate in the same city refreshes the feeds.
Session changes and superseding searches discard old completions. Pagination
keeps the existing user-scroll gate, prefetch margin, and bounded top-ups;
empty advancing pages are not terminal. Sparse or failed batches offer retry.

The native path uses the shared request pacer. HTTP 403/429 and recognized
GraphQL rate-limit messages back off without attempting the browser. Schema
failures fall back; ordinary network failures preserve cards and allow retry.
End-of-results footers use cursor state rather than whether the user is logged
in. Browser fallback retains its guest first-page limit.

Item-detail extraction retains its WebView path. The later authenticated
implementation below replaces signed-in feed scrolling with GraphQL requests.
Category routes, date-window searches, and missing/invalid coordinates use
the browser because equivalent native inputs have not been verified. The
initial Browse page can still take several seconds, and city geocoding remains
ahead of publication to keep radius filtering stable. These are remaining
limits, not eliminated by replacing the transport.

Validation: the iOS Simulator build succeeded and the full suite passed
67 tests. After the final fallback/retry adjustment, all 18 feed-specific tests
passed again. They cover streamed parsing, canonical IDs, empty advancing
pages, cursor cycles, cookie isolation, HTTP backoff, browser fallback, stale
Search/Discover completions, session changes, and coordinate-aware caching.

## Anthurium search regression

A fresh logged-out desktop search for `anthurium`, San Francisco, 16 km,
local pickup exposed `COMMERCE_MKTPLACE_WWW` in the initial query's
`params.bqf.callsite`. The implementation had copied
`COMMERCE_MKTPLACE_SEO_USERS` from an earlier page capture. A controlled direct
comparison using the same pagination document and all other variables unchanged
returned:

| Callsite | New listings per page | Pagination |
| --- | --- | --- |
| `COMMERCE_MKTPLACE_SEO_USERS` | 0, 0 | First page advertised more; second ended |
| `COMMERCE_MKTPLACE_WWW` | 15, 24, 24 | All three advertised more |

The WWW requests took 419, 890, and 464 ms. They used no cookies or browser
tokens. This shows that accepting a query without errors does not establish
equivalence between callsites, and an empty SEO response does not prove there
are no listings. The client and probe now use the observed normal search
callsite. The earlier broad claim that cold pagination works needs this
qualification.

Initial Search also follows empty advancing pages automatically, up to three
requests total, stopping as soon as cards arrive or the server confirms the
end. Exhausting that budget retains the cursor for a subsequent paging attempt; a block
stops recovery without a browser retry. Regression tests cover automatic
recovery, a confirmed empty result, the request budget, and retry after a block.

After the change, the production Swift client independently returned 15, 24,
and 24 new anthurium cards. The iOS Simulator build and all 70 tests passed.
This validates the client and store; installation on the physical device remains
necessary to exercise the updated UI there.

## Cached-search pagination stall

The Simulator reproduced an Anthurium feed stopped at its first page with no
loading indicator. App logs showed 15 cached cards restored, a live response
with 15 cards and `has_next_page=true`, and no subsequent pagination request.
Three regression tests failed before the fix: visibility lost on cached/live
replacement, a drag ignored during refresh, and a callback rejected because
the card's contents changed despite retaining its ID.

Search now remaps observed cached IDs into the live ordering, preserves a drag
made during refresh, and rechecks pagination when the refresh completes.
Search and Discover match appearance callbacks by ID and recheck the margin
on subsequent drag events. The existing one-request-at-a-time and bounded
pagination rules remain in effect.

A geometry-based footer also requests a page automatically when it enters the
bottom 160-point prefetch margin. It works independently of cell appearance
and drag callbacks, including a short or locally filtered feed. New visible
cards may trigger another bounded top-up if the viewport still needs filling;
a batch without visible progress does not repeatedly fetch while stationary.
Hidden surfaces and feeds loading their initial page cannot trigger it.

Pagination displays only a spinner while a request is running: no Load more
button, loading text, or next-page skeleton cards. Its accessibility label
remains available to VoiceOver. Failed top-ups stop automatic footer requests;
the existing scroll and pull-to-refresh actions can retry.

Validation: all 80 iOS tests passed, covering cached-card paging and the footer
request gate (bottom visibility, concurrent loading, lack of visible progress,
returning to the bottom, and query changes).

## Authenticated session-backed GraphQL

Verified on the signed-in iPhone 17 Pro Simulator session on 2026-09-30.
`AuthenticatedFeedClient` runs `fetch('/api/graphql/')` in the existing
persistent WebView, with same-origin credentials. The loaded page supplies
`CurrentUserInitialData`, `getAsyncParams('POST')`, and the operation's Relay
metadata. The actor and `fb_dtsg` are checked before sending; no browser tokens
or session cookies are exported into URLSession, logs, or the backend.
The browser document's actor must match the currently signed-in cookie identity,
and a pagination cursor cannot move between accounts.

The operation names and document IDs matched the anonymous Search and Browse
operations in this session. Each module becomes available after the relevant
Search or Browse page bootstraps; seeing the embedded first-page data does not
mean those JavaScript modules have loaded yet. Preparation polls for the
module with a ten-second deadline, then the warm context handles new queries
and cursor requests without navigation. The first page therefore still pays
browser startup, and later page latency remains dependent on Facebook.

| Authenticated production-client probe | New listings | End-to-end milliseconds | More pages |
| --- | --- | --- | --- |
| Anthurium Search, cold context | 15 | 1952 | yes |
| Search, next cursor | 0 | 1485 | yes |
| Search, following cursor | 24 | 928 | yes |
| Browse, cold context | 20 | 6614 | yes |
| Browse, next cursor | 5 | 1547 | yes |

Search's empty page was a real empty edge array with an advancing cursor.
The following page contained 24 listings and two `MarketplaceFeedAdStory`
edges. Both Search and Browse streamed additional video metadata underneath
ad-story attachments. `GraphQLFeedDecoder` ignores these patches only when
the path points into a known ad story in the requested feed; unrelated or
unrecognized patches still fail validation. It does not turn ad metadata into
listing cards.

`ListingStore` and `DiscoverFeed` select the authenticated transport when signed
in and the cookie-free transport when signed out. Both use the same connection
decoder, cursor validation, deduplication, native grid, and automatic pagination.
Unsupported inputs or schema changes fall back to browser extraction. HTTP
403/429 and recognized GraphQL blocks apply the shared backoff without trying
another transport. Fetches have an eight-second deadline and request-specific
abort controllers; superseded requests cannot publish into a newer feed.
Details and seller extraction retain the established item-page path.

Validation: 91 iOS tests passed, including authenticated Search/Discover routing,
no guest retry on authenticated blocks, sign-out cancellation and cursor reset,
streamed ad patches, HTTP/GraphQL backoff, and malformed or login responses.
Browse top picks carry `formatted_price.text` separately from `listing_price.amount`;
the decoder preserves that display price, also covered by a regression test.
The bounded live probe is kept separately in
`tools/probe/authenticated_graphql/`; it is not run by the ordinary test suite.
