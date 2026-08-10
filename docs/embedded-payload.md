# The GraphQL payload is already in the page

**Date:** 2026-08-05
**Method:** desktop pages inspected in a browser; both surfaces measured from a
`WKWebView` (`tools/probe`, `runPayloadTests`)
**Related:** `filter-parameters.md`, `surface-strategy.md`, `data-model.md`

The question was whether Facebook exposes a GraphQL API we could call for exact
posting times and better filtering. The useful answer turned out to be that we
don't need to call anything: **the desktop surface embeds the `MarketplaceSearch`
GraphQL response verbatim in the HTML it already serves us**, one structured
`listing` object per card.

The mobile surface embeds none of it.

---

## 1. Why not the API itself

| Route | Status |
|---|---|
| Public Marketplace API | Does not exist, and never has. Meta's incentive runs the other way — the whole product depends on keeping buyers and sellers inside Facebook. |
| Commerce Platform API | Limited alpha, approved *seller* partners only. Built for managing your own inventory, not for reading other people's listings. |
| Meta Content Library API | Real, and it does expose Marketplace listings with `SINCE`/`UNTIL` date filtering — but access is for approved researchers, running inside a Secure Research Environment or third-party cleanroom. Not a thing a consumer iOS app can ship against. |
| Internal `/api/graphql/` | Reachable, but each query needs a `doc_id` (a precompiled-query hash that rotates every few weeks) plus a session-bound `fb_dtsg` CSRF token, and logged-out calls get bounced to a login wall. Reported rate limits are ~30–60 requests/hour/IP. |

The internal endpoint is the only one that would work in principle, and it is a
maintenance treadmill: a rotating `doc_id` means the app breaks on Facebook's
schedule rather than ours. It is also a considerably more aggressive posture
than loading pages — this app's whole premise is that it browses the public site
the way a logged-out visitor does.

Reading the payload out of the page we already load gets the same fields with
none of that.

## 2. What each card carries

The desktop search page holds one of these per rendered card, inside
`MarketplaceSearchFeedStoriesEdge` → `node.listing`:

```json
{
  "id": "1054280080442808",
  "primary_listing_photo": { "image": {"uri": "https://scontent-…"},
                             "id": "928285686952534" },
  "creation_time": 1784161765,
  "listing_price": { "formatted_amount": "$40", "amount": "40.00" },
  "strikethrough_price": null,
  "location": { "reverse_geocode": {
      "city": "San Francisco", "state": "CA",
      "city_page": { "display_name": "San Francisco, California",
                     "id": "114952118516947" } } },
  "is_hidden": false, "is_live": true, "is_pending": false, "is_sold": false,
  "marketplace_listing_category_id": "1583634935226685",
  "marketplace_listing_title": "Black L-Shaped Corner Desk with Monitor Shelf",
  "created_with_seller_app": false,
  "marketplace_listing_seller": null,
  "delivery_types": ["IN_PERSON"]
}
```

Counted rather than sampled, on a 15-card page: `creation_time` ×15,
`marketplace_listing_title` ×15, `delivery_types` ×15, `is_sold` ×15,
`primary_listing_photo` ×15, `strikethrough_price` ×15,
`marketplace_listing_seller` ×15, `MarketplaceSearchFeedStoriesEdge` ×15. One
per card, no gaps.

Five of these are things the app currently does without, or works to derive:

- **`creation_time` is an exact unix timestamp.** This is the field that makes
  recency sorting possible at all. Cards render no date, and item pages only say
  "Listed 2 weeks ago" — the payload for that same listing says 20.3 days.
- **`primary_listing_photo.id` is a photo id — but not the app's one.**
  Recorded here on 2026-08-05 as being the same FBID the app parses out of the
  fbcdn filename. It is not. The two are adjacent but distinct
  (`928285703619199` in the filename against `928285686952534` in the payload;
  6 of 6 sampled differ), so joining on it would match nothing and fail
  quietly. The value that *does* join mobile to desktop is the filename
  segment, which is byte-identical across surfaces —
  `surface-strategy.md` §5a.
- **`delivery_types` is the local-vs-shipping signal**, structured. See §4.
- **`city_page.id` is a place id**, free with every card — the open question in
  `mobile-location-radius-notes.md` §8 about cities with no vanity slug.
- **`is_sold` / `is_live` / `is_pending`** give a sold check for saved listings.

**No coordinates.** `latitude` appears 6 times on a 15-card page, so it is not
per-card; the finest location a card carries is still its city. Per-listing
coordinates remain item-page-only.

## 3. Verification

The rule from `probe-checklist.md` §6 applies with force here, because item
pages carry ~20 *other* listings' `creation_time` values in their "Today's
picks" rail — the same trap that made the coordinate extractor read a
neighbour's location. A timestamp found in the markup is not automatically this
listing's.

Two checks:

1. **Structural, on item pages.** The listing's own `creation_time` is the one
   followed by `location_text`; the picks' are followed by
   `primary_listing_photo`. On a sample item page that discriminator matched
   **exactly once** against 20 picks, and the value it returned (27.3 hours)
   agreed with the page's own "Listed a day ago".
2. **Cross-surface, on search pages.** Card `1054280080442808` carried
   `creation_time: 1784161765` in the search payload. Opening that listing's own
   item page and reading its own timestamp gave **the same value**, against a
   rendered "Listed 2 weeks ago".

So the search payload's per-card timestamps are the listings' real creation
times, not an artefact of proximity in the markup.

## 4. `delivery_types`, measured both ways

| Page | Values seen |
|---|---|
| default search (15 cards) | `IN_PERSON`, `IN_PERSON,DOOR_PICKUP`, `IN_PERSON,PUBLIC_MEETUP` — no shipping token anywhere |
| re-survey, 35 arrays across two pages | adds **`DOOR_DROPOFF`**, missed above. Full vocabulary: `SHIPPING_ONSITE`, `IN_PERSON`, `DOOR_PICKUP`, `DOOR_DROPOFF`, `PUBLIC_MEETUP` |
| `deliveryMethod=shipping` (24 cards) | `SHIPPING_ONSITE` in **24 of 24**, alone on 5 and combined with local options on 19 |

`DOOR_DROPOFF` is rare — 1 of 21 arrays on one item page, 1 of 14 on a search
page — and is the only token meaning *delivery without shipping*: the seller
brings it to the buyer. `DOOR_PICKUP` is the opposite direction. Treating the
two as one thing states the reverse of what the seller offered, so they are
carried separately.

`SHIPPING_ONSITE` is therefore the reliable marker, and it is finer than the
"card has no city line" heuristic in `mobile-location-radius-notes.md` §4: it
separates *ships only* (5 cards) from *ships or collect in person* (19), which
are different things for a local-browsing app.

**Item pages carry it too, confirmed.** The detail extractor reads
`delivery_types` from the listing's own object, anchored on `location_text` like
`is_sold`. Verified end to end against a live Oakland listing that sat *past*
the payload's ~15-card reach — so its card had no delivery data of its own and
the item page was the only possible source: `delivery=IN_PERSON` in the log, and
the badge rendered.

**The anchor is what makes it safe, and it was measured.** On a live item page:
21 `delivery_types` arrays present (the picks rail), `"location_text"` occurring
**exactly once**, and **exactly one** `delivery_types` inside the ±4000-char
window around it — the one belonging to the page's own listing. Same property
`is_sold` relies on, now confirmed for this field rather than assumed.

Worth noting there is no DOM route to fall back on: zero `aria-label`s on that
page matched `/ship|pickup|deliver/i`. Delivery is payload-only, so the
structured read is not a shortcut past a more stable rendered source — it is the
only source.

A rendered-text fallback ("Ships to you", "Local pickup", read only from nodes
outside any `a[href*="/marketplace/item/"]`) covers pages that don't embed the
array. It has not been observed firing, since the payload has answered every
time so far. `DetailEngine` logs `delivery=` on every open, so which source won
is readable rather than guessed.

Still unconfirmed on a live page: `SHIPPING_ONSITE` reaching the detail screen.
A `deliveryMethod=shipping` search returns nothing at all logged out, so no
shipping listing has been openable to check. The token mapping itself is
exercised over all eight documented token sets (`Fulfillment`), and the shipping
branch differs from the verified local one only in which token matches.

`created_with_seller_app` is also per-card and is a plausible business /
drop-shipper signal, but every card on the pages measured was `false`, so it is
untested as a discriminator.

## 5. The catch: mobile has none of it

Both mobile pages, measured from the same `WKWebView` that produced the desktop
numbers above:

| | mobile search | mobile item | desktop search |
|---|---|---|---|
| rendered listing photos | 26 | 20 | 15 |
| `creation_time` | **0** | **0** | 15 |
| `marketplace_listing_title` | **0** | **0** | 15 |
| `delivery_types` | **0** | **0** | 15 |
| `is_sold` | **0** | **0** | 15 |
| `MarketplaceSearchFeedStoriesEdge` | **0** | **0** | 15 |

Zero occurrences of every key, on a page rendering 26 listings. The desktop
column is the positive control from the same run — the probe works, and the
mobile result is a real absence rather than a selector problem.

This is consistent with what WebLite is: a server-driven UI that ships rendered
components, not a React app rehydrating from a GraphQL response. It also
explains the earlier finding that mobile item pages have no embedded JSON to
fall back on for condition.

## 5a. Why the payload is absent, and how far that's actually established

The short version: **the two surfaces put the renderer in different places, and
the payload is only needed where the renderer is.**

Desktop is a React app that re-renders from data on the client — clicking a
filter rewrites the result grid via `history.pushState` with no page load, which
is only possible if the client holds the data that produced the grid. So the
GraphQL response ships alongside the markup. That is what the 124 script tags
and 68 KB per listing are.

WebLite is the opposite arrangement: the server runs the query, binds the
results into a component tree, renders it, and ships only the rendered output.
The client is a thin runtime that displays components and posts an action token
back when one is tapped. It never re-renders from data because it never holds
data.

Measured support, rather than inference:

| | mobile | desktop |
|---|---|---|
| bytes of HTML per rendered listing | ~7,000 | ~68,000 |
| `<script>` tags | 25 | 124 |

And the decisive tell is not the size but the **missing identifiers**. Mobile
carries no listing id anywhere — checked previously against every pattern the
desktop surface uses, including React internals. A payload merely trimmed for
bandwidth would keep ids; they are 16 bytes and nearly everything depends on
them. Their total absence is the signature of a client that was never meant to
reason about listings at all, which is exactly why card taps are opaque
`data-action-id` tokens the server resolves.

So the absence looks like an architectural consequence rather than an
anti-scraping measure. WebLite exists to serve low-bandwidth devices, and a 10×
reduction per listing is the point of it. The scraping-resistance is a side
effect.

**Caveat on this section:** the architecture description is an inference from
observed behaviour, not from anything Meta documents. The measurements above are
real; the causal story is the most economical explanation of them.

## 5b. Resolved: it's a WebSocket

**Answered 2026-08-05.** Reported by a parallel Codex session and independently
reproduced here. WebLite loads feed data over a WebSocket, which is why both
instruments below came back empty — WebSocket frames are not `fetch`, not
`XMLHttpRequest`, and appear in **no** Resource Timing entry. The two negatives
were correct and jointly misleading.

Wrapping `window.WebSocket` at `.atDocumentStart`, a mobile search for `desk`:

```
socket    wss://kaios-d.facebook.com:443/ws/0000099999?lid=…
frames    37, of which 1 carries listing routes
that frame   binary, 124,534 bytes, exactly 26 marketplace/item/<id> routes
rendered     26 cards
```

Twenty-six ids for twenty-six cards, arriving before the cards reach the DOM.
`kaios-d` is Facebook's Lite/KaiOS infrastructure, which is consistent with
WebLite being the same server-driven stack.

Pagination uses the same channel: scrolling to 50 cards added three more
id-carrying frames (79,128 B / 50 ids, 75,012 B / 17, 62,575 B / 15).

### Ordering holds — verified by tapping

Ids in a frame are worthless unless they can be aligned to cards; a
mis-alignment opens a stranger's listing, which is the failure this project
cares most about. So the order was checked against reality rather than assumed:

| tapped card index | landed on | position in socket list |
|---|---|---|
| 1 | `1624050395351390` ("Wooden writing desk with gray hutch") | **1** |
| 2 | `1797842328020434` | **2** |

Socket order matches DOM order for both.

### The hazard: the list is cumulative across navigations

Not in the original report, and it is the thing that would cause a mis-mapping
in practice. The accumulated id list **grew while tapping**: 26 after the search,
42 after opening one item, 55 after opening a second. Item pages push their own
frames — their "Today's picks" rails carry item routes too — so a naive global
`ids[cardIndex]` lookup silently drifts by however many ids an item page
contributed.

Anything built on this has to scope ids to the frame that delivered the feed,
and reset on navigation. The 79 unique ids observed against 50 rendered cards at
the end of the run is that contamination, not evidence that ids arrive ahead of
rendering.

### What it would buy

Every card's `itemURL` immediately, removing the ~1.9 s per-listing tap that
`FeedEngine.openItem` currently pays and the prefetch budget built around it.
That is a large win, but it is a private binary protocol with session-scoped
ids, so it belongs behind DOM extraction as an accelerator with fixtures and a
health check — not as the correctness path.

## 5c. Superseded: what transport pagination uses

Worth recording as a genuine dead end rather than quietly dropping.

Scrolling the mobile feed paginates 26 → 50 → 74 listings, growing the markup
from 181 KB to 297 KB. Three things were established about that new content:

- It is **not preloaded.** Snapshotting the initial markup and searching it for
  the later listings found 0 of 48 photo ids and 4 of 48 titles (those four
  being short generic strings like "Black small desk"). Positive control: 26 of
  26 photo ids and 25 of 26 titles for the *first* batch were found.
- It carries **no payload keys** — `creation_time` stays at 0 across all
  297 KB.
- It arrives over the network, yet **neither instrument can see the request.**
  A `fetch`/`XMLHttpRequest` recorder injected at `.atDocumentStart` — before
  any page script runs — captured **0 requests**. Resource Timing, which records
  requests whatever API issued them, shows 83 entries: 75 images, 4 CSS, and 4
  `/ajax/weblite_*_logging/` telemetry beacons of ~380 bytes each. No content
  request in either.

Something is either clearing the Resource Timing buffer (WebLite demonstrably
harvests it — `weblite_resources_timing_logging` is one of the four beacons) or
using a transport neither instrument observes.

> **It was the second one — a WebSocket (§5b).** Recorded here as a worked
> example for `probe-checklist.md`: two instruments returning nothing is not
> two pieces of evidence, it is one blind spot counted twice. Both `fetch`/XHR
> hooking and Resource Timing miss WebSockets, so their agreement carried far
> less information than it appeared to. The conclusion drawn at the time — that
> mobile carries no structured data regardless of transport — did survive, but
> for a reason unrelated to the strength of the evidence.

## 6. What this changes

The surface trade-off in `filter-parameters.md` §5 stands, but the desktop side
is worth much more than it looked:

- Desktop: 15–24 results, no pagination — but every one **fully structured**,
  with an exact timestamp, a numeric price, delivery types, sold state, a place
  id, and the photo id.
- Mobile: paginates indefinitely and carries seller identity — but everything
  must be scraped from rendered text, and there is no date at any depth.

For the plan of filtering by location and then sorting ourselves, the desktop
payload is the enrichment source, and it removes the blocker recorded in the
README's to-do list: sorting by recency no longer needs an item-page fetch per
listing, because the search response already dates every card.

## 7. Open questions

- Does the payload survive on the desktop *category browse* path, or only on
  search?
- `marketplace_listing_seller` is present as a key on every card but was `null`
  throughout. When is it populated? If it ever carries a seller id, the
  duplicate-coordinates business heuristic in `data-model.md` gets much cheaper.
- Is there a `cursor` that would paginate the desktop payload? The edges carry
  `"cursor": null` logged out, which is consistent with the observed hard cap.
- Does `created_with_seller_app` ever come back `true`, and does it correlate
  with the drop-shipper listings we want to filter?
- What transport does mobile pagination actually use (§5b)? Answering it would
  need a proxy or `WKURLSchemeHandler`-level interception rather than anything
  reachable from inside the page.

## 8. The browse path has no usable payload — measured 2026-08-07

Prompted by the home screen's Discover section, which loads
`/marketplace/<place>/` rather than a `/search/` path. §7 listed "does the
payload appear on category and browse pages" as an open question; for browse it
is now answered, and the answer is no.

Ran the extractor's own logic against a live browse page, logged out, desktop
user agent:

| | Browse `/marketplace/sanfrancisco/` | Search `/marketplace/sanfrancisco/search/?query=desk` |
|---|---|---|
| `"listing":{` blocks found | 6 | ~15 |
| …carrying `marketplace_listing_title` | **0** | all |
| …carrying `listing_price` | **0** | all |
| …carrying `primary_listing_photo` | **0** | all |
| …carrying `creation_time` | 6 | all |
| Rendered card anchors | **20** | 15 |
| …with a full `aria-label` and an image | **20 of 20** | all |

So the six blocks are not a thin payload, they are a different object: an id and
a timestamp with no describable content attached. Six of them against twenty
rendered cards, and none of the six is enough to draw a card with.

The markup, meanwhile, is complete — every one of the twenty anchors carries the
same `aria-label` shape the search tail is parsed from
(`"Beanbag poufs, $5, San Francisco, CA, listing 1597932195222996"`).

**Consequence.** Category paths remain untested; assume the same until someone
measures them.

> **The caller this was measured for is gone.** `DiscoverFeed` briefly read the
> browse page's DOM to fill the home screen. It now runs the user's own recent
> searches instead — the browse feed turned out to be a rotating popularity pool
> rather than a recommendation (README, "Why not Facebook's own feed"), and
> being markup-only was the smaller of its two problems. Nothing in the app
> loads a browse path today. The measurement stands on its own: it is the answer
> to half of §7's open question, and the reason to be suspicious of any future
> plan that assumes payload coverage off a `/search/` path.

**One parsing bug fell out of this.** The browse feed spells a free listing's
price `FREE`, where search results spell it `Free`. `DesktopCardParser` matched
the exact string, so a browse card rendered with an em dash for its price and
the word FREE stranded on the end of its title. Now matched
case-insensitively — worth remembering as a general hazard: the two paths are
different renderers and agree on shape, not on casing.
