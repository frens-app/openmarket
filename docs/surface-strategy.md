# Surface strategy: mobile vs. desktop

**Status:** historical analysis. The recommendation below was implemented and
then superseded by signed-in desktop findings. Use `data-model.md` for the
current source matrix, `decision-desktop-primary.md` for routing, and
`logged-in-findings.md` for authentication-dependent behavior. Statements in
this file that desktop cannot paginate or cannot expose seller identity are
retained as experiment history, not current truth.
**Date:** 2026-07-31
**Related:** `feasibility-2026-07-31.md` (how we got here), `status.md` (what's built),
`mobile-location-radius-notes.md` (why mobile's location and radius don't behave as the URL suggests)

Facebook serves two entirely different Marketplace sites depending on the user
agent, and they have opposite strengths. Everything below was measured from a
`WKWebView` on an iPhone 17 Pro simulator, logged out, same city, same query
("anthurium") unless noted.

---

## 1. The two surfaces

### Mobile — WebLite

A **server-driven UI**. Cards are `data-mcomponent` containers keyed by an
opaque token (`data-action-id="32511"`). Tapping sends that token to Facebook,
which decides server-side where to navigate. The client is never told which
listing a card represents.

Measured, with 26 listings on screen:

| Probe | Result |
|---|---|
| `/marketplace/item/{id}` hrefs | **0** |
| Anchors on the entire page | 4 — Safari promo, Chrome promo, logo, "Log in" |
| Elements with `aria-label` / `alt` / `title` | 64 |
| …that reference a listing | **0** |
| The string `listing <digits>` anywhere in the markup | **0** |
| Distinct 13–17 digit numbers in the document | 4 (for 26 cards — so not per-listing) |

Also ruled out earlier: React fiber props, embedded JSON in `<script>` tags,
and every `data-*` attribute on the card and six levels of ancestors.

**There are no listing IDs on the mobile site, in any form.** This is
architectural, not an oversight, and no better selector will find them.

### Desktop

A conventional web page, so it *has* to put a real URL in a real anchor:

```html
<a aria-label="Anthurium Red Gunsal x Bess add, $38, San Francisco, CA, listing 1030250539438843"
   class="x1i10hfl xjbqb8w x1ejq31n …"
   href="/marketplace/item/1030250539438843/?ref=search&referral_code=null&referral_story_type=post">
```

The ID appears twice — in the `href` and in the `aria-label` — and the label is
a comma-delimited record of **title, price, city, and ID** in one string.
Accessibility labels are a far more durable parsing target than obfuscated
class names (`x1i10hfl xjbqb8w`), because Facebook can't churn them without
breaking screen readers.

Renders fine on iOS: a desktop UA in a `WKWebView` produced 16 listing anchors
at real layout sizes (first card 189×262pt), with `navigator.userAgent`
reporting macOS. The app already relies on this for detail pages.

---

## 2. Head to head

| | Mobile (WebLite) | Desktop |
|---|---|---|
| Listing IDs | none, anywhere | in `href` **and** `aria-label` |
| Results per search | 26, then paginates | ~16, hard cap |
| Pagination logged out | **yes** — 26 → 50 → 74 → 99, batches of ~25 | **no** |
| Per-card location | only on one of two layout variants | reliably present |
| Title, price | yes (titles truncated) | yes, untruncated, in the label |
| Category pages | paginates | ~24, capped |
| Parsing target | structural guesswork | anchor + accessibility label |
| Layout stability | two variants served at random | one consistent layout observed |

Pagination on mobile responds **only** to stepping the native
`scrollView.contentOffset`. `window.scrollTo` and synthesized `TouchEvent`s
both leave the page frozen.

Neither surface can be fetched without a browser: `URLSession`, `curl`, and
even same-origin `fetch()` with valid cookies all return a dataless JS shell.
A real top-level navigation in a webview is required either way.

---

## 3. The login modal on desktop

**Measured 2026-08-05** in a real `WKWebView` with a real viewport, which
matters — an earlier attempt ran in a browser pane sized 0×0, where nothing can
lazy-load, and it produced a confident wrong answer (see §3a).

There is no scroll threshold to find, because the overlay is up from the start:

| stage | cards | doc height | overlay |
|---|---|---|---|
| on load | 15 | 600 px | **up** |
| 24 scroll steps | 15 | 600 px | up — page never moved (`scrollY` pinned at 20) |
| after clicking its Close button | 15 | **2340 px** | gone |
| then scrolling | **39** | 612 px | back — and now undismissable |
| further dismiss attempts | 39 | 612 px | `no close affordance found` |

So the sequence is: the "See more on Facebook" overlay appears **on load**, pins
the document at ~600 px and blocks scrolling entirely. It is dismissible through
its own Close affordance, and dismissing it unlocks the page. Scrolling then
genuinely paginates — 15 → 39 cards — after which it returns.

**And the one that returns is a different, undismissable modal.** This is the
ceiling. Round 2's dismissal reported `no close affordance found`, and
enumerating every clickable element inside it gives the whole story:

```
INPUT (email)  ·  "Log In"  ·  "Forgot password?"  ·  "Create new account"
```

No close control of any kind. Escape is a no-op; a backdrop click is a no-op;
both leave `scrollable: false` at 612 px. There is exactly **one** free
dismissal per page load, and it buys 15 → 39.

Note what is *not* holding the page: `bodyOverflow: visible`,
`bodyPosition: static` — there is no CSS scroll lock to defeat. The document is
612 px because the modal collapses the results region rather than merely
covering it. Removing the dialog node outright leaves the height at 580 px, so
DOM surgery does not recover it either.

Two things it is *not*:

- **Not a full login wall.** No hard login *page* appeared across ~30 scroll
  steps and six dismissal attempts. The one on record came from sustained
  probing over a long session, not from scrolling a single search.
- **Not an extraction blocker.** All 39 cards stay in the DOM and readable
  behind the modal, even while it is unscrollable.

### The catch that actually constrains the design

**Only the first 15 cards carry the embedded payload.** Checking each rendered
card's id against the markup holding the payload objects:

```
cards 39 · uniqueIds 39 · idsWithPayload 15 · creation_time keys 16
```

The payload ships with the server-rendered first response. The 24 cards added by
client-side pagination are markup only — no `creation_time`, no
`delivery_types`, no `is_sold`. So desktop's structured data is capped at ~15
per query no matter how far it is scrolled, and scrolling buys reach in a form
that is no richer than mobile's.

That is the real reason desktop can't be the depth mechanism — not the modal,
and not a hard result cap.

### 3a. What the earlier wrong answer was, and why

This section previously said sustained scrolling *brings up* the modal, with the
threshold unmeasured. Separately, the README and `filter-parameters.md` recorded
that desktop "doesn't paginate logged out — scrolling it six times added
nothing". Both were wrong, and the second was wrong for an avoidable reason: the
test ran in a pane whose `innerHeight` was 0, so the scroll calls were no-ops
and the absence of new cards measured only the absence of a viewport. A test
that cannot succeed is not evidence of failure — check that the instrument can
observe a positive before recording a negative.

Also worth remembering: heavy probing during development *did* trigger a full
login wall. The backoff ladder in §7.3 is not theoretical.

---

## 4. What routing through desktop would gain

1. **Exact identity, free.** Today identity is inferred from a photo's CDN
   filename, and grid listings are matched to search results by fuzzy title
   prefix. Both disappear. Correct dedupe and correct hidden-listings follow,
   and so does the elimination of a real risk: a mis-match opens someone else's
   listing.
2. **Instant deep links.** No ~5s resolve step on tap. Opening a listing costs
   one page load instead of two.
3. **Location on every card**, hence distance on every card. Locality is the
   product thesis; on mobile it depends on which layout variant we're served.
4. **Fewer requests.** Current: 1 per search + 2 per listing opened. Desktop
   first: 1 per search + 1 per listing opened.
5. **Much less fragile code.** These exist only to cope with WebLite and could
   be deleted: document-order text bucketing, the ~25s settle/re-read loop,
   native-scroll pagination, the in-place tap machinery, `ItemMatcher`'s fuzzy
   matching, and variant handling.

> **Corrected 2026-08-05.** This list previously described the synthetic tap
> machinery as something "which never worked in-app". It works, and has since
> the tap was rewritten to watch `location.href` instead of `decidePolicyFor`:
> `FeedEngine.openItem` clicks a card and the feed webview lands on the item
> page, which is the app's primary enrichment path at ~1.9s per open. The
> original negative came from watching for a navigation WebLite never
> generates — it routes client-side through `history.replaceState`. See
> `probe-checklist.md`, which already carried the correction.
>
> Point 1 also needs qualifying: identity is still inferred from the photo's
> CDN filename, but that inference is no longer surface-bound. See §5a.

### What it costs

**Depth.** ~16 results per search versus mobile's 26-and-climbing. That is the
single reason not to go all-desktop.

---

## 5. Options

| Option | Depth | IDs / location | Complexity |
|---|---|---|---|
| A. All mobile | best | none — no deep links, no detail | high, fragile |
| B. Current hybrid — mobile feed, in-place tap, desktop resolve as fallback | best | exact via photo id (§5a), ~1.9s per open | highest |
| C. **Desktop first, mobile for depth** | good | exact for the first ~16 | medium |
| D. All desktop | ~16 per query | exact everywhere | lowest |

**Recommendation: C**, with D as the honest simplification if depth turns out
not to matter in practice.

Under C, the first page comes from desktop — exact IDs, untruncated titles,
prices, cities, instant deep links — and mobile is spun up only when the user
scrolls past ~16 results. Most sessions never leave the first screen, so most
of the time you get the good surface and the reliable parser.

### 5b. Restated after the 2026-08-05 measurements

C still wins, and for a stronger reason than it was originally argued on. Three
findings changed the balance:

1. **Filters and sorting exist only on desktop** (`filter-parameters.md`).
   `sortBy`, `deliveryMethod`, `daysSinceListed`, `itemCondition` and
   `minPrice`/`maxPrice` all work there and are all stripped on mobile. This is
   the decisive one: recency, local-vs-shipping and price bounds are the
   product's actual selection criteria, and mobile cannot express any of them.
2. **Desktop's filters are server-side**, so its 15 structured results are drawn
   from the whole filtered corpus rather than being the first 15 of an
   unfiltered list. Fifteen *correctly selected* listings is a different thing
   from fifteen arbitrary ones.
3. **The seam is exact** (§5a), so merging desktop and mobile results is an
   equality check on the photo key.

**Do not use desktop's dismissal-pagination.** It buys cards 16–39, and those
carry no payload (§3) — they are exactly as poor as mobile cards, obtained at
the cost of provoking the undismissable modal. Take desktop's structured 15 and
go to mobile for depth.

So the division of labour is:

| job | surface | why |
|---|---|---|
| the search itself | **desktop** | only surface with filters, sorting and exact timestamps |
| depth past ~15 | **mobile** | only surface that paginates; merge on the photo key |
| item detail | **mobile** | seller name, join date, rating, description, photos, coordinates — desktop item pages have none of the seller fields |
| item ids for mobile cards | **mobile WebSocket** | avoids the ~1.9 s resolve tap (`embedded-payload.md` §5b) |

Radius is unaffected by any of this and remains a client-side filter against
per-listing coordinates, because no surface honours it (§`filter-parameters.md`).

**The open risk is the login wall**, not the modal. The modal is understood and
survivable; what is unmeasured is how often sustained desktop querying escalates
to a full wall. That frequency should be established before desktop becomes the
default search path, and it cannot be measured without provoking one.

The seam was previously described as the honest wrinkle in C: merging the two
feeds means recognising when a mobile card is a listing desktop already
returned, which was thought to need the same fuzzy matching C otherwise
deletes. Measured overlap for a single query: desktop returned 16 links against
mobile's 26 cards, and 15 of 21 sampled mobile cards matched a desktop entry by
12-character title prefix (~60%). The misses were near-duplicate titles — three
"Anthurium Luxurians" listings plus one "Anthirium Luxurians" typo — which is
exactly where title matching is weakest.

**That wrinkle is gone — see §5a. The seam has an exact key.**

### 5a. The photo id joins the two surfaces exactly

Measured 2026-08-05, same query, both user agents, one session: **the middle
segment of a listing's fbcdn filename is identical on mobile and desktop.**

| listing | mobile | desktop |
|---|---|---|
| Black L-Shaped Corner Desk with Monitor Shelf | `928285703619199` | `928285703619199` |
| Wooden writing desk with gray hutch | `965063599852315` | `965063599852315` |
| Great Condition Desk with Lots of Storage | `1670233630954680` | `1670233630954680` |
| Blue desk & black rolly chair | `1870301990594903` | `1870301990594903` |
| Desk (San Francisco) | `822376967512303` | `822376967512303` |

That segment is already what `Listing.id` is built from, so the join needs no
new extraction — the key the app computes on a mobile card is the same string it
would compute on the desktop card for the same listing. Dedupe at the seam is an
equality check, not a similarity score.

**Trap: this is *not* the payload's `primary_listing_photo.id`.** The desktop
GraphQL payload carries its own photo id, and it is a different number from the
filename segment — adjacent, which makes it easy to mistake for the same value:

| filename segment | `primary_listing_photo.id` |
|---|---|
| `928285703619199` | `928285686952534` |
| `2893069517699487` | `2893069507699488` |
| `1670233630954680` | `1670233620954681` |

Six of six sampled differ. Joining on `primary_listing_photo.id` would match
nothing and fail silently. Use the filename segment.

What this does **not** remove is `ItemMatcher` itself: it is still live at
`DetailEngine.swift:83`, reached from `ListingStore.swift:365` as the last-resort
path when neither a cached `itemURL` nor an in-place tap produced a detail. It
has been demoted from the primary mechanism to a fallback, not deleted, and the
seam argument above is the reason it *can* now be deleted rather than evidence
that it has been.

---

## 6. Open questions

1. **Does desktop search accept an offset or cursor parameter?** If page two
   were reachable by URL, option D becomes strictly better than anything else
   and the mobile path can be deleted outright. Facebook's own desktop
   pagination is infinite-scroll and login-gated, so this is unlikely — but
   it's ~15 minutes to rule out and it would settle the whole question.
2. **How much scrolling triggers the desktop login modal?** (§3.) Sets the
   ceiling on any desktop-driven feed.
3. **Does the modal ever block extraction, or is it always just an overlay?**
   So far listings have stayed readable in the DOM behind it.
4. **How often do users actually scroll past the first ~16 results?** This is
   the product question that decides C vs. D. Worth answering with the
   handoff/scroll-depth telemetry in §8 before building either.
