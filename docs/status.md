# Build status — 2026-07-31

> Historical snapshot, not current architecture. See `data-model.md`,
> `decision-desktop-primary.md`, `logged-in-findings.md`, and `docs/backend.md`
> before using any surface or persistence claim here.

App lives in `apps/ios/` (xcodegen; `xcodegen generate` then build the
`OpenMarket` scheme). Probe harness in `tools/probe/`, with its own README. Feasibility record in
`feasibility-2026-07-31.md`. Which Facebook surface to route through, and why —
including the desktop login modal — is analysed in `surface-strategy.md`.
How the mobile site handles location, radius and result quality (and why the
radius control is currently decorative) is in `mobile-location-radius-notes.md`.

## Working, verified on an iPhone 17 Pro simulator

- **Category feeds** — 49 DOM cards → 48 parsed, with title, price, badge,
  **city**, and **approximate distance**.
- **Search feeds** — 27 cards → 26 parsed, with **untruncated title**, price,
  badge, **city**, **distance**, and **condition**, all read from each card's
  `aria-label` rather than its rendered text (see below).
- **Progressive detail preview** (§3.2) — pushes on the next frame with the
  grid's data, hero image shared via `matchedGeometryEffect`, skeletons for
  what's still loading. Never blocks on the network.
- **Detail enrichment** — full multi-paragraph description with its paragraph
  breaks, photo strip, posted date, **the listing's own approximate
  coordinate**, and **seller name, star rating and rating count** (mobile-only).
  **Harvested from the feed webview during the tap**, not fetched again:
  measured **1.9–2.2s** tap-to-complete, down from ~6.5s. A revisit inside the
  session is instant and costs no network at all.
  - The tap is now the whole mechanism. WebLite routes it client-side, and by
    the time `location.href` shows the item URL the entire page — description,
    twelve photos, seller, coordinate — is already in that DOM. Measured at
    **3ms**. The engine used to wind history back at exactly that moment and
    have `DetailEngine` load the identical page again: 830ms of settling plus a
    3.5s cold load, ~4.4s of the old 6.5s, spent re-fetching a page it was
    standing on.
  - Restoring the feed (`history.back()` + settle) now happens *after* the
    caller has its data, in a task the next reader of the results page awaits.
    The user never waits for it.
  - Content is delivered in two stages — text as soon as it exists, photos when
    the gallery resolves — so a slow gallery can't hold back the description.
- **The home screen is the saved list.** With an empty search bar the app shows
  what you kept, rendered entirely from the local profile store — no network at
  all, and the launch path reaches it in 0.22s. Emptying the search bar returns
  here; recent-search pills jump back to a result set (instantly, from the
  results cache). Launch no longer auto-runs the last query.
  - Saving writes the card to the profile store *at the moment of the save*, so
    there is no such thing as a saved listing with nothing behind it. The
    control is live on the detail screen's first frame, seconds before a cold
    listing's enrichment lands, so relying on enrichment to have written the
    profile would have left early saves blank.
  - **Known limit:** fbcdn thumbnail URLs are signed and expire. `oe` is a hex
    unix expiry; measured across three cached listings, the window is
    **106.9–107.5 hours** (~4.5 days) from fetch. Text fields persist
    indefinitely, so a saved card older than that renders with a dead image.
    Tracked in the README to-do; needs image bytes cached rather than the URL.

    An earlier note here claimed persisted URLs stop resolving immediately.
    That was wrong — the URL that produced the grey placeholder was still valid
    for four more days and returned HTTP 200 on a direct fetch, and the same
    card rendered correctly on the next launch. It was a one-off image-load
    failure that `AsyncImage` never retries, which is its own to-do item. This
    is exactly the trap in `docs/probe-checklist.md` §6: a broken image, a
    mechanism invented to explain it, and signing parameters that happened to
    fit the story — recorded without ever fetching the URL.

    That one-off failure is fixed: `ImageLoader` retries, coalesces and caps
    image traffic, and `RemoteImage` gives a dead photo one visible state
    everywhere (`MissingPhoto`) instead of grey in some views and a glyph in
    others. Expiry itself is unchanged and still wants cached bytes.
- **Saving a listing.** A bookmark in the detail toolbar, keyed on `Listing.id`
  — the photo FBID out of the thumbnail CDN URL. That key is why the grid shows
  a save with no plumbing between the screens, and why the badge follows the
  listing when Facebook reorders results between loads (verified across a
  relaunch). Saved ids live in UserDefaults, and `ListingCache` refuses to evict
  a saved listing's profile: that's user data, not cache. The grid badge is
  read-only — saving is a deliberate act on the detail screen, not something a
  thumb can do by brushing the grid.
- **On-device persistence** (`ListingCache`), two stores with different jobs:

  | | |
  |---|---|
  | **launch → cards, cached** | **1.10s** — essentially just process start |
  | launch → cards, cold | 5.13s |
  | tap → cached profile painted | **0.000s** |
  | tap → live revalidation done | 3.89s |

  *Last result set* — the cards from the most recent search, restored on the
  first frame for the same query only. A grid restored under a different search
  term would be actively misleading.

  *Listing profiles* — full detail for listings actually opened, capped at 1000
  and evicted least-recently-used (`usedAt` is touched on read, so what survives
  is what's being looked at, not merely what's newest). Measured ~5.7KB each, so
  ~5.6MB at the ceiling; the load is synchronous at launch, which is worth
  watching if the cap ever rises.

  Both live in memory and mirror to disk: tap-path reads are synchronous, writes
  are coalesced on a 2s debounce and flushed on scene-phase change, since a
  debounce is wrong for an app about to be killed.

  **A cached profile is never the answer.** Every tap revalidates live, because
  price and sold status are exactly what goes stale in a cache and exactly what
  someone opening a listing needs to be right.
  - Revalidation prefers loading the known item URL directly over tapping the
    card. Tapping needs a `cardIndex` that matches the live DOM — which a
    restored card does not have — and it occupies the feed webview.
  - The first live cards **replace** restored ones outright rather than merging.
    Merging would keep last session's `cardIndex`, now pointing at a different
    card, and a tap would open the wrong listing. Detail isn't lost: `ingest`
    re-seeds it from the profile store.
- **Prefetching the top 8 cards** (`ListingStore.prefetchDepth`). Warms them the
  same way a tap does, starting as soon as the feed hydrates. Measured:

  | | |
  |---|---|
  | tap on a warmed card | **0.000s**, complete on the first frame |
  | tap on a cold card | 1.90–2.20s |
  | all 8 warm | 23.6s after cards appear (6.2s for 3) |
  | tap during an in-flight prefetch | **1.90s** — no measurable penalty |

  Preemption is what makes it safe: a tap cancels the prefetch mid-poll (the
  abandoned one logs `no id`), and the user's own open is unaffected. A tap on
  the card *currently* being prefetched rides along instead of restarting it.

  **The cost is traffic**: up to 8 extra item fetches per search, whether or not
  the user opens anything, and `openItem` does not go through `RequestPacer`.
  That is the number to revisit if login walls become more frequent — set
  `prefetchDepth` to 0 to disable. The profile store blunts it on repeat runs:
  anything already on disk is skipped, so a second run of the same search only
  pays for cards it has never read.
- **The feed webview is gated.** It holds the results page, its scroll position,
  and — for ~2s after a tap — an item page instead. `acquireFeed`/`releaseFeed`
  serialize every access. Without it a `settle()` pass landing mid-tap would run
  the *card* extractor against an *item* page and ingest that page's "Today's
  picks" module as search results. Rare when only taps parked the webview;
  constant once prefetching does it on a loop.
  - Polls for content rather than sleeping a fixed 1.5s, and doesn't wait for
    `didFinish` — on an item page that waits for every photo to download.
  - Rejects any page whose `location.pathname` id isn't the one requested.
- **Detail map centres on the listing, not the city.** The item page's own
  coordinate is read from the static-map URL (`center=` on mobile) with the
  embedded-JSON `"latitude"`/`"longitude"` pair as a fallback, and the map draws
  a half-mile circle around it at neighbourhood zoom. Where no item coordinate
  exists the geocoded city centroid still carries the first frame — but at a 6 km
  circle labelled "City only", since a tight circle on a centroid asserts the
  listing is near downtown. Verified on two listings: Oakland
  `37.828674316406,-122.26135253906` (~2.8 km from the centroid it used to draw)
  and Mountain View `37.416687011719,-122.07458496094`.
- **Deep linking** — "View on Facebook" opens the listing's own
  `/marketplace/item/{id}` page. Verified against a live listing.
- **Detail content is scoped to the listing.** Detail pages carry "Related
  searches" and "Today's picks" modules full of *other people's* listings; the
  extractor walks in document order and stops at the first such heading, so the
  photo strip and description can't pick them up. Text nodes inside
  `<script>`/`<style>` are excluded — a TreeWalker over `SHOW_TEXT` visits them,
  which briefly rendered a page's JavaScript as a listing description.
- **Approximate-area map** — an Apple Maps card with a radius circle around the
  geocoded place, not a pin: Facebook says "Location is approximate" and a pin
  would imply precision the seller never shared.
- **Session restore** — the last search or category is persisted and re-run on
  launch, so reopening lands where the user left off rather than on an empty
  screen.
- **Pagination** — driven by stepping the hidden webview's native scroll view,
  the only method that works (§ below).
- **Radius pinning, recent-search pills, first-run, settings, request pacing
  with backoff, parse-health metrics.** Sponsored cards are filtered out; the
  keyword blocklist and per-listing hiding were removed on 2026-08-04.

## The three findings the implementation is built around

1. **Mobile UA only.** Desktop caps at 15 results with no pagination; the stock
   WKWebView UA gets a dataless shell.
2. **Pagination responds only to the native scroll view.** `window.scrollTo`
   and synthesized `TouchEvent`s leave the page frozen; stepping
   `scrollView.contentOffset` loads the next ~25 listings.
3. **Cards are found structurally**, as an actionable container holding an
   fbcdn image. Search pages wrap card text in `h3`; category pages don't, so
   any markup-shaped selector breaks on one surface or the other.

## Known gaps

### Item URLs — the tap works; the app watched the wrong channel

**Verified 2026-08-04.** A plain `MouseEvent` sequence on a card navigates to
that listing's item page. WebLite routes it **client-side via
`history.replaceState`**, so no navigation ever reaches `decidePolicyFor` —
which is the only thing that resumed `pendingItemURL`. The resolve timed out
after 10s every time while the tap was working perfectly.

Two listings, both clean:

| | id | description | photos | seller | coords |
|---|---|---|---|---|---|
| card 0 | 1244917550907745 | yes | 18 | Hannah | 37.762756…,-122.448120… |
| card 1 | 2119352205659543 | yes | 19 | Erin | 37.795715…,-122.437133… |

`history.back()` restores the feed exactly — 26 cards, same first card, same
URL — both times. `stopMarker` was false on both, so mobile item pages don't
carry the "Today's picks" contamination the desktop scoping was built for.

This makes the desktop search redundant: one tap yields the id *and* the item
page, on the surface that has seller data. `ItemMatcher` and its 6-character
title floor become deletable.

The earlier "works in the spike, not in the app" record was an artifact — those
probes selected cards by bare `fbcdn` and acted on `cards[0]`, which under that
selector is Facebook's wordmark, and the wordmark is a link.

<details>
<summary>Superseded: resolving via the desktop surface</summary>



Listing ids exist nowhere in the mobile DOM, and synthetic taps never fired
WebLite's server-side action from inside the app (mouse events, touch events,
`el.click()`, interactive webview, full opacity — all no-ops, though the same
code worked in the standalone spike).

> **The tap half of that was wrong**, and is kept here only because this block
> records what was believed at the time. Taps always fired; the app was
> watching `decidePolicyFor` for a navigation WebLite never generates, because
> it routes client-side through `history.replaceState`. Watching
> `location.href` instead made the in-place tap work, and it is now the primary
> enrichment path. The listing-id half stands.

Resolved by going around it. The **desktop** surface still exposes real
`a[href*="/marketplace/item/{id}"]` anchors, so `DetailEngine` searches that
surface for the listing's own title and matches the result back by title prefix
and price (`ItemMatcher`). Grid titles arrive truncated, so matching is on a
normalised prefix, and it refuses to guess — a wrong id would open someone
else's listing, which is worse than no link.

Cost is one page load per listing the user actually opens, on top of the detail
page load that §3.2 already requires. Verified end to end: tapping a card
resolves the id, loads the real description, condition and photos, and "View on
Facebook" deep-links to that exact item page.

</details>

### Search cards often carry no location — SOLVED 2026-08-04

**We were reading the wrong thing.** Every mobile search card carries an
`aria-label` holding the untruncated title, the condition, the price and the
city — 27 of 27 cards, on both layouts. The extractor reads rendered text,
which on one layout omits the city. Nothing about the webview context was ever
at fault.

```
Desk for sale - Used - Good - $75 in Oakland, CA
Free Computer desk for sale - Used - Like New in El Sobrante, CA
```

Two shapes: priced listings put the price between the condition and `in`; free
listings prefix `Free ` and drop the price segment. Parsing both covers every
card that is a listing.

The layout difference is real but no longer load-bearing, and it is not random:
requesting a place that differs from the IP-inferred one gets the layout with
per-card cities, requesting the place you already appear to be in does not.
Eight search observations, no exceptions. The elimination work below stands as
a record of what was ruled out, but the premise — that the app was being denied
data — was wrong.

<details>
<summary>Original diagnosis, kept for the record</summary>

Category feeds render a city per card and the app shows city + distance there.
Search is inconsistent, and the cause is **not** in our code:

Facebook serves at least two mobile layouts for the *same* search URL:

| | header | cards | text nodes | city nodes |
|---|---|---|---|---|
| Variant A | "Results" + a Distance chip | price, title | 141 | 1 (page header only) |
| Variant B | "Search results for X near Y" + "40 mi", Filters, Sort | price, title, **city** | 128 | 26 (one per card) |

The standalone spike reliably gets B; the app reliably gets A, with an
identical URL, identical mobile user agent, and a fresh `nonPersistent` store
in both. Ruled out by direct experiment: the `radius` parameter, the
`latitude`/`longitude` parameters (both now removed as unnecessary), extraction
timing (re-read to ~25s), card-root selection (containment *and* document-order
bucketing), viewport size (402×778 in both), `isScrollEnabled`, webview opacity,
occlusion vs. offscreen positioning, and hit-testability.

What that leaves is something about the app's WebKit context that biases the
bucket — plausibly the process pool, two webviews in one process, or a
cookie/bucketing decision made on the very first navigation of a session.

Next step, and the cheap one: have the app instantiate a *single* webview
exactly as the spike does (no shared pool, no second engine, default
configuration) and see if the variant flips. If it does, bisect the
configuration from there. Failing that, detect the variant at runtime — the
header text and city-node count identify it unambiguously — and reload once
into a fresh data store to reroll.

Meanwhile the parse-health metric already reports `failing=location`, which is
exactly the early warning §8 was specified for; it is working as intended.

</details>

## Notes for testing

**Read `docs/probe-checklist.md` before recording a finding.** Six rules, each
written after a specific wrong answer this project committed to documentation
and then acted on for weeks.

**The app's own logs need `log stream`, not `log show`.** `os.Logger` at `info`
level isn't kept in the persisted archive, so the app appears silent:

```bash
xcrun simctl spawn <UDID> log stream --level info --style compact \
  --predicate 'subsystem == "com.brianli101.marketplace"'
```

**Driving the simulator.** Tap coordinates are device points, not screenshot
pixels — on an iPhone 17 Pro multiply screenshot coordinates by 402/width. The
feed's first card sits near `(103, 256)`.


- The iOS 26 floating search bar doesn't take focus from synthetic taps; seed
  `recentSearches` via `simctl spawn <udid> defaults write` and tap a pill.
- Set a location first, or distances stay blank:
  `xcrun simctl location <udid> set 37.7749,-122.4194`.
- Sustained probing does trigger Facebook's login wall — the app's backoff
  (§7.3) is not theoretical.
