# What changes with a signed-in session

**Date:** 2026-08-05
**Method:** `tools/probe`, signed in by hand on a throwaway account in a visible
webview; battery in `runLoggedInTests`. Desktop user agent throughout except
the login itself.
**Related:** `surface-strategy.md`, `embedded-payload.md`, `filter-parameters.md`

Four questions could only be answered with a session. Two came back the way the
all-desktop plan needed, two did not.

---

## 1. Seller data: unlocked (the plan's best result)

Desktop item pages carry no seller fields logged out. Signed in, the same
listing:

| field | logged out | signed in |
|---|---|---|
| "Joined Facebook in …" | — | **"Joined Facebook in 2023"** |
| Seller information heading | no | **yes** |
| `/marketplace/profile/<id>` links | 0 | **3** |
| coordinates | yes | yes |
| rating | — | absent on this listing |

The profile links matter more than the join date: they are a **stable seller
id**, which no surface provides logged out and which mobile never provides at
all. That is the missing ingredient for the "filter out businesses and
drop-shippers" goal — listings can be grouped by seller instead of guessed at
from duplicate coordinates and repeated titles.

### Ratings — superseded by §1a

> The survey below concluded ratings were unavailable everywhere. **That was
> wrong on both counts** — a broken detector plus a sample of unrated desk
> sellers. Ratings are readable and common; see §1a. The `profileLinks` and
> `joined` columns still stand.

Six listings, both user agents, all signed in:

| | desktop | mobile |
|---|---|---|
| "Joined Facebook in …" | 6/6 | **6/6** |
| seller rating | **0/6** | **0/6** |
| `/marketplace/profile/<id>` links | **3 on 6/6** | **0 on 6/6** |
| rendered photos | 5–27 | 5–9 |

Two things fall out, and one of them cuts against the all-desktop plan.

**Ratings did not appear on either surface for any of the six sellers.** The
likely explanation is that these sellers are simply unrated — Facebook only
shows a rating where one exists — but that is a guess, and the honest position
is that *no* surface has been observed rendering a seller rating. A "stars and
ratings" UI should not be planned until a rated seller has been found and
confirmed.

**Seller join date is on mobile too, logged out.** So the seller *name and join
date* are not a login-only win; what login-plus-desktop uniquely adds is the
`/marketplace/profile/<id>` link — the stable seller id, absent from mobile on
all six. That is the part worth having, and it is the part that enables grouping
listings by seller.

The corollary matters for the logged-out path: an all-desktop app shows an
unauthenticated user **less** seller information than the current mobile-based
one, which gets name and join date without any account at all.

Photo counts are `img[src*="scontent"]` currently in the DOM, so they undercount
lazy-loaded galleries; treat that row as indicative only.

## 1a. Click vs. direct URL: the view changes, the data does not

Desktop Marketplace is a single-page app, and the two ways of reaching an item
page produce visibly different screens. Measured on six listings, then on a
rated seller specifically.

| | click a card | load the URL |
|---|---|---|
| layout | **modal / lightbox** (2 close buttons) | full page (0) |
| body text | 406–910 chars | **~2× more** (808–1990) |
| listing's own fields | complete | complete |
| seller name + joined | present | present |
| **seller rating + stars** | **present** | present |
| "Today's picks" rail | **absent** | present |

**Ratings are not route-dependent.** On the same rated listing reached both
ways, the seller block is byte-identical:

```
Seller information | Seller details | Kelsey Jones | (44) |
Highly rated on Marketplace | Joined Facebook in 2010
starLabels: ["4.8 out of 5 stars…"]
```

Diffing the full body text of both routes settles what the modal actually drops:
**68 lines present only on the direct load, 0 present only on the click** — and
all 68 are the "Today's picks" recommendation rail (`Bamboo bathroom rack`,
`Standing Desk`, `Free West Elm rug`…). The modal is a strict subset of the full
page, and the only omission is *other sellers' listings*.

### Why it looked like ratings depended on the route

The two pages compared were different listings: a plant seller with 246 ratings
reached by one route, and a desk seller reached by the other. The route differed
*and* the seller differed, and the rating tracked the seller. Ratings turn out to
be strongly category-dependent — see below.

### This makes the click route arguably *better* for extraction

"Today's picks" is the single largest source of wrong answers in this project:
neighbouring listings' coordinates, condition, and `creation_time` all live in
that rail, and every extractor has needed a discriminator to avoid attributing
them to the listing being viewed (`embedded-payload.md` §3,
`mobile-location-radius-notes.md` §6). A modal that omits the rail entirely has
none of that contamination to guard against.

### Correction: ratings are common, and the earlier survey was wrong twice

The previous survey reported no ratings on any of six sellers, on either
surface. Both halves of that were wrong:

1. **The detector was broken.** It searched for `N ratings`; the page renders
   `(N)` beside star glyphs, with `Highly rated on Marketplace` alongside.
2. **The sample was unrepresentative.** All six were desk listings from casual
   sellers. Ten consecutive *anthurium* listings were rated 10 out of 10 —
   `(9)`, `(11)`, `(30)`, `(44)`, `(53)`, `(67)`, `(70)`, `(92)`, `(195)`,
   `(246)`.

So seller ratings are readable, and their availability tracks the category:
plant sellers are semi-professional and rated, one-off furniture sellers mostly
are not. Ratings and review counts are therefore viable for the
business/drop-shipper filter — with the caveat that "has ratings" partly *is* the
signal for a commercial seller.

## 2. Payload past the first page: still capped (the plan's worst result)

**This is the finding that constrains the design.** Scrolling the signed-in feed
through ten rounds:

```
round   1     2     3     4     5     6     7     8     9    10
cards  18    45    27    12    29    10    12    10     8    13
creation_time keys  16 16 16 16 16 16 16 16 16 16
```

`creation_time` never moves off **16** while cards go past 45, and
`idsWithPayload` drops to 0 as soon as the original 15 scroll out of the DOM.
The embedded payload is only ever the server-rendered first page. Signing in
does not extend it.

So the structured data — exact timestamps, `delivery_types`, `is_sold`, numeric
price — remains capped at ~15 per query whether signed in or not. Everything
beyond that is markup, which is what mobile already provides.

## 3. Infinite scroll: yes, but the feed virtualises

Scrolling works logged in and does not stop at the logged-out ceiling of 39 —
document height reached 15,397 px and kept going.

But look at the card counts above: 45, then 27, then 12, then 29. They go *down*.
The desktop feed **recycles DOM nodes**, keeping only a window around the
viewport. Consequences for anything built on it:

- Cards must be **harvested incrementally while scrolling**. Scrolling to the
  end and then reading the DOM returns whatever the last window happened to
  hold, not the feed.
- The same applies to the payload: even the first 15 objects stop matching
  rendered cards once those cards are recycled out.

## 4. Radius: still decorative, even signed in

The one that would have justified login on its own. It does not.

| | `radius=8` (5 mi) | `radius=161` (100 mi) |
|---|---|---|
| chip | "Within 5 mi" | "Within 100 mi" |
| cards | 15 | 15 |
| first five ids | identical | identical |
| cities | San Francisco ×15 | San Francisco ×15 |

Byte-identical result sets. Radius moves the chip and nothing else, logged in
exactly as logged out.

**One genuine improvement, though not from `radius`:** signed in, all 15 results
were San Francisco, where the same logged-out query returned Martinez, Vallejo,
Oakland and Daly City. The plausible cause is the account's own saved location
tightening the default — worth confirming, because if it holds it is a real
locality gain that costs no filtering work.

## 5. Timing: the data lands at half the page-load time

Item pages, signed in, desktop, polled at 25 ms from navigation start:

| listing | payload readable | rendered text | `didFinish` |
|---|---|---|---|
| 1054280080442808 | 1.04 s | 1.18 s | 1.85 s |
| 1624050395351390 | 0.84 s | 1.14 s | 1.58 s |
| 1318664736543676 | 0.79 s | 1.08 s | 2.13 s |

The payload is readable at ~0.9 s against a ~1.85 s `didFinish`. **Nothing needs
to wait for the page to finish** — extract as soon as the JSON is in the
document and abandon the rest of the load. That is roughly a 2× improvement on
detail open, and it removes the images and third-party chrome from the critical
path entirely.

### The first version of this measurement was wrong

It reported `payload=0.01s` for all three, which would have been a ~200×
finding. `webView.load()` leaves the previous document in place until the new
one commits, and the previous document was another item page carrying the same
`creation_time` / `location_text` markers — so the first poll matched the page
we had just navigated away from.

Fixed by requiring `location.href` to contain the expected listing id before
either signal counts, plus an `about:blank` load between timings. The corrected
numbers are above. Same family as the 0×0-viewport and agreeing-instruments
mistakes: **a probe that can report success before the work starts is measuring
its own setup.**

## 6. What this means for the all-desktop plan

Holds up:

- Seller data and a stable seller id (§1), which mobile cannot give at all
- Filters and sorting, which only desktop has
- Coordinates on item pages
- Detail open at ~0.9 s if the load is abandoned early (§5)

Does not hold up:

- **Infinite scroll does not buy structured depth** (§2). Past card ~15 the
  cards are markup-only — the same quality mobile already provides without an
  account in the loop.
- **Radius still does not work** (§4), so client-side distance filtering is
  required regardless.
- The feed virtualises (§3), so harvesting is more complex than "scroll then
  read".

The honest summary: signing in fixes the *item page* (seller identity) and
leaves the *feed* essentially where it was. If login is adopted, the argument
for it is seller data and account-tightened locality — not depth.

---

## 7. The signed-in page is a different document

**Added 2026-08-09, from the first real signed-in session.** §1–§6 measured what
Facebook *returns* signed in. This section is about what it *renders*, which
turned out to matter more: login was adopted, and four separate pieces of the
app broke on contact with a session. None of them were about data.

| What broke | Why | Fixed in |
|---|---|---|
| Location picker — both routes | Pill matched by text; first `div[role="button"]` reading `City · N mi` was the **notifications button** | `location.md` §5.0 |
| Location picker, intermittently | Pill clicked before layout — same element measured `344x27` and `0x0` on consecutive runs | `location.md` §5.0 |
| Location picker | `element.click()` ignored; the control opens on the pointer sequence | `location.md` §5.0 |
| Discover pagination | Cards past the first page carry **no `aria-label`** | `discover.md` §0.1a |
| Seller name unreadable | The block renders as one unseparated run — `Seller detailsDana Whitfield(17)Highly rated on Marketplace…` — and the parser split it on newlines, so the whole block became the name | §7.4 |
| Seller absent entirely | It renders *after* the detail poll's readiness test is satisfied | §7.4 |

### 7.1 What is actually different in the DOM

- **More chrome, so more collisions.** The logged-in shell adds navigation and
  jewel buttons ahead of the Marketplace content in document order. Any selector
  that takes "the first element that looks like X" is exposed, and the failure
  is silent: it finds *an* element and clicks it.
- **Panels are mounted but hidden.** A `[role="dialog"]` labelled
  `Notifications` sits in the page permanently with `visible: false`. Presence
  of a dialog is not evidence a dialog is open — check the bounding box.
- **`aria-label` coverage is inconsistent within one page.** The server-rendered
  first page of the feed labels its cards; everything infinite scroll inserts
  does not. Both states are the same surface, same session, same session — the
  label is a property of *how a node was created*, not of the page.

### 7.2 The exposure this leaves

> **Superseded for item detail by §7.4.** The signed-in desktop detail extractor
> has now been exercised and repaired. The general rule below still holds for
> any selector not re-checked with cookies present.

Everything in this app was built and verified **logged out**, over months, and
the four failures above all sat latent that whole time. That is the finding
worth keeping, more than any individual selector:

> A selector verified logged out is untested, not confirmed.

Still verified only logged out, and worth re-checking against a session before
being trusted: the item-page detail extractor (`DesktopScripts.extractDetail`),
the seller-tools flow, and the login-wall detection itself. None have been
observed failing — they have simply never been watched with cookies present.

The cheap habit that would have caught all four: when a selector matches
nothing, log **what was there instead**. Every one of these presented as an
empty result from a selector, and in three of the four the honest answer was
"you are looking at the wrong element", which no amount of re-reading the
selector reveals.

### 7.3 The account carries its own location

Independent of anything the app sets. On this session the picker's own pill read
`Location: New York, New York, Within 5 mi` while the app was browsing Seattle
at 10 mi.

That radius is a **floor the app cannot raise** (§4, `filter-parameters.md` §11)
— the app can narrow what arrives and never widen it — and it now bounds the
whole home screen rather than one section of a search, because signed-in
Discover is Facebook's own feed (`discover.md` §4.4). Nothing currently tells
the user this. The pill is readable, so saying so is possible; it is not done.

### 7.4 The seller block: two bugs stacked, and a wrong diagnosis

Both only reachable signed in, so both shipped unexercised.

**It renders as one run.** §1a records the block with separators
(`Seller information | Seller details | Kelsey Jones | (44) | …`). Observed here
it arrived with none at all, and not merely without newlines — without *spaces*:

```
Seller information Seller detailsDana Whitfield(17)Highly rated on MarketplaceJoined Facebook in 2009
```

`detailsKatrina`, `MarketplaceJoined`. The parser split on newlines and took the
first non-heading line as the name, so with one "line" the entire block became
the seller's name and the detail screen rendered it as a three-line heading
beside the stars. It now flattens and matches by shape — `(N)` for the count,
`Joined Facebook in YYYY`, name is what precedes them — which handles both the
separated and the run-together forms. **Do not assume either form**; this block
has now been seen both ways on the same surface.

**It arrives late.** Separately, the detail poll's readiness test is
"description and gallery", both of which are at the top of the page. Seller
identity renders after both, so a fast page was handed back before the block
existed: `none of 1460 nodes` scanned for a section that is present seconds
later. Fixed with one short re-poll once the caller already has text and photos,
so it costs nothing anyone is waiting on.

**What the block carries, now that it parses.** Name, join year, star score,
rating count, and Facebook's own `Highly rated on Marketplace` badge — the last
of which was being matched and thrown away. It is stored as
`ListingDetail.sellerIsHighlyRated` rather than derived from the score, because
it is Facebook's bar against its own unpublished threshold; inventing one here
would put the badge on sellers Facebook doesn't.

Ratings are commoner than §1a's "tracks the category" suggested — a casual
5-rating furniture seller carried one — so the unrated case is the minority, but
it exists (a named seller with a join year and no score at all), and the detail
screen now says "No ratings yet" rather than leaving the line blank. Absence and
breakage look identical otherwise.

**The wrong diagnosis is the part worth keeping.** The obvious explanation was
"it's below the fold and unbuilt until something scrolls there", and a scroll
was written to fix it. The scroll reported `moved: nothing` on the very page
that then produced a seller 33 ms later — the re-poll did the work. The scroll
survives as cheap insurance, labelled as such in the code, because a mechanism
credited with a fix it did not perform is worse than no mechanism at all: the
next person removes the wrong one.
