# Discover: the home screen feed

**Date:** 2026-08-10
**Code:** `apps/ios/Sources/Store/DiscoverFeed.swift`,
`ResultsView.discoverSection`
**Related:** `embedded-payload.md` §8, `filter-parameters.md` §3 and §11,
`logged-in-findings.md` §2–§4, `mobile-location-radius-notes.md` §3

The home screen is three sections: **Recently viewed** and **Saved**, one
horizontal rail each and both read from disk, then **Discover**, which runs to
the bottom of the scroll. Either rail disappears when empty, so a new install
lands directly in Discover.

Discover exists because the home screen used to be entirely local. That is the
right content for someone coming *back*, and nothing at all for someone
arriving: a new install saw an empty state and a search field, and had to think
of something to type before the app would do anything.

---

## 0. One Discover: Facebook's own feed, cut to the radius

Facebook's own Marketplace feed for the user's place — the default Discover
screen — scrolled, and cut to the radius the user set. Same feed signed in or
out. **The session decides one thing: whether it scrolls.**

| | Anonymous | Signed in |
|---|---|---|
| Fill | one page, published as-is | scroll until `browseTarget` (12) in-radius cards |
| Pagination | none — Facebook stops at ~20–24 cards and never loads more | a screen at a time, never yet observed to stop |
| Footer | the offer to log in | no terminal claim; a later drag may retry |
| Ranking | a popularity pool on an IP and a cookie (§3) | the account's own history |

**This replaced the search-seeded feed on 2026-08-10**, which is what §1 used to
describe: up to three of the user's own recent searches, re-run and mixed,
topped up from interests picked at onboarding. Two things ended it.

- **It cost three page loads to draw one screen.** Concurrency had already taken
  that from 13–20 s to 2–3 s (§4.2) and it was still three Facebook page loads
  on the screen the app opens with, with nothing shown until the slowest
  finished.
- **It could not show anything new.** By construction it only ever contained
  categories the user had already searched for or ticked at onboarding — §3's
  closing trade, and the thing a home feed is most obviously for.

The measured swap, San Francisco, 10 mi, signed out: **~10.1 s → ~3.9 s** to
first paint, and the interest picker stopped being load-bearing (§6.1).

**§3 is still true and is the price.** Logged out this feed is a rotating
popularity pool, not a recommendation, and no measurement here contradicts that.
What changed is what it is being compared against — a feed of the user's own
search terms was more legible but strictly narrower — and what the screen
*claims*: the caption states the place and the radius and nothing about the
user, so there is no "from your searches for lamp · desk" to be wrong about.

### 0.0 Anonymous is one page, deliberately

An anonymous fill does not scroll at all. `DiscoverFeed.fill` sets `reachedEnd`
the moment the first page is in.

This was not the first version, and the first version is why. Measured 2026-08-10,
signed out, San Francisco, 10 mi:

```
loading cards from https://www.facebook.com/marketplace/sanfrancisco/
20 markup cards                                        (3.4 s)
batch: 20 raw, 0 unparsed, 1 ships, 0 dupes, 19 new, 4 in radius
scroll: 0->661 of 3188,    cards 20->20               ×5 screens
scroll: no further movement
browse feed stopped growing after 5 screens
4 cards from Marketplace, anon=true, end=true          (10.1 s total)
```

Six of the ten seconds went on scrolling a feed that never grows: the scroll
position advanced 0→2410px of a fixed 3188px container while the card count sat
at 20 the entire way. `dryScreenBudget` cannot catch this — it counts screens
that produced *new* listings and kept none, and these produced no new listings
at all (§0.1, and that rule is correct for the signed-in top-up it was written
for). The cap itself is not new: `feasibility-2026-07-31.md` §9.1 recorded it as
"the page simply never loads more", and the README's surface table has carried
it as `no (~24 cap) logged out` throughout.

So the scroll is what an account buys. Anonymous, the same run now publishes in
**3.9 s**.

### 0.0a A login wall is treated as anonymous

`loadCards` reports `.loginWall` only when *nothing* rendered, and that means the
same thing whichever session asked: signed out it is Facebook declining the page,
signed in it is cookies that have stopped working. Either way there is nothing to
scroll for and a login is the accurate next step, so the feed sets `isAnonymous`
and ends there.

`isAnonymous` is therefore not "is the user signed in". The session actually
asked under is kept separately (`filledUnder`) and is what triggers a refill —
sharing one value would make every subsequent `loadIfNeeded` see a mismatch and
refetch the wall.

### 0.1 Paging Facebook's feed

One engine, one page, scrolled a screen at a time with a harvest between each —
the desktop feed virtualises, so reading once at the bottom returns the last
window rather than the feed (`logged-in-findings.md` §3). The other two engines
sit idle for as long as the session lasts.

**Infinite scroll works, and confirming it took four bugs off the pile.** The
first signed-in build showed ~19 cards and then "There's nothing else in your
area" immediately. Measured on a real session, Seattle, 10 mi:

| | Symptom | Cause |
|---|---|---|
| 1 | Discover built the *signed-out* feed for a signed-in account | `allCookies()` answers before WebKit has read its store off disk, and answers empty. Discover asked at launch+0.5s and got `false`; the scene-phase check 400ms later got `authed` from the identical call. Now an empty jar is retried and anything else is trusted at once (`SessionState.isSignedIn`) |
| 2 | `scrollOnce()` returned false on its **first** call, every time | It moved `webView.scrollView.contentOffset`. At 1280x900 the document is exactly one viewport tall and the feed is an inner `overflow-y:auto` div — 900 over 3102 — so `contentSize - bounds` was 0. `window.scrollTo(0,5000)` left `scrollY` at 0. Now an element is scrolled, found by walking up from a card |
| 3 | Every reading silently discarded | `scrollTop` is fractional; `moved` arrived as `0.5` and failed to decode into an `Int`. Then the read-only script omitted `moved` entirely — Swift's synthesized `Decodable` does not fall back to property defaults. Both failures returned nil, and nil reads as "can't scroll", which reads as the end of the feed |
| 4 | 0 cards kept over 14 screens, while scrolling 0 → 8647px | **Cards past the first page carry no `aria-label`.** 16-of-16, 21-of-21, 23-of-23 rejected per screen, anchors and images present, `label=[]`. See below |

Only bug 2 was specific to Discover. **Search pagination had the same defect and
had never worked either** — `canLoadMore` is false without a session, so the only
callers were signed-in ones, and the app has been developed signed out.

Two properties of this feed defeat the obvious end-of-feed tests, and both cost a
wrong "nothing else in your area" before being understood:

- **Document height is not a progress signal.** The recycler collapses content
  above the viewport as well as below, so `scrollHeight` oscillates while paging
  *forward*: 8515, 4711, 5043, 6330, 6854, 7954, 6748, 4247. A shrink can even
  clamp the scroll position backwards (3800 → 3469). The test is therefore
  whether the position *advanced*, with one retry for a clamp.
- **"No new cards" does not mean "no more cards".** A fill has already taken
  every card in the DOM, so the first several screens of a top-up legitimately
  return nothing but duplicates. Counting those as evidence ended the feed at
  2644px of a 6650px document. Only a screen that produced *new* listings and
  rejected all of them on distance counts against the area.

### 0.1a The first page and the rest are different markup

`aria-label` — which carries title, price, city and the listing id in one string
— exists **only on the server-rendered first page**. Every card the infinite
scroll inserts has an empty one:

```
id=1409179587931105  label=[]  img=true  text=[$0 / Free Baby Grand Piano! / Bellingham, WA]
```

So `DesktopCardParser` has two routes. The label route is unchanged and still
preferred; `parseLines` reads the card's own visible text, one field per line,
matching by shape — a `$`-prefixed line is the price, a line ending in a
two-letter uppercase state is the city, the longest remainder is the title.

This is why the `renderedCards` extractor now returns `lines` rather than a
flat 140-character `text`: the newlines *are* the field boundaries, and the old
slice both flattened them and truncated longer titles before the city.

The label route cannot be dropped in favour of this one. It carries the
was-price and the empty-city shipping signal, neither of which the text route
can see — `parseLines` therefore never claims `Ships`, because "no city line"
and "card mid-render" look identical to it.

**The radius is applied inside `DiscoverFeed`, not in the view.** This is the
one list in the app that filters distance before it publishes, and the reason is
that the fill has to *know*: Facebook's feed reaches wherever Facebook feels
like reaching — one measured load returned 20 cards across 11 cities, of which a
6 mi radius kept 9 — so a page-once-and-hide-the-rest design shows four cards
and calls it the neighbourhood. Filtering during the harvest is what lets a fill
keep scrolling until it has `browseTarget` (12) cards actually worth showing.
`ResultsView.winnowed` still runs afterwards; it is a few cached lookups and it
keeps one distance rule in one place for every list on screen.

**Listings whose distance isn't known are dropped here** — the opposite of the
rule everywhere else in the app, and the exception is deliberate. Everywhere
else the list is a search Facebook already localised, so an unresolved place is
probably nearby and hiding it punishes a card for being unrecognised. This feed
is not localised in any comparable sense: a signed-in Seattle feed served
Vancouver WA, Bellingham, Wilsonville OR, and a cardboard cutout of a US senator
in Citrus Heights, California — the last of which reached the screen under the
keep-if-unknown rule, with no distance line, ~700 miles out.

Safe to drop rather than defer because `resolveAll` has already had its turn by
then: this runs after geocoding, not during it, so the card never enters the feed
and nothing vanishes from under a reader later. Geocoding is lossy — one measured
batch resolved 1 of 2 places — so this does discard the occasional real
neighbour, which is the price of not showing California.

A signed-in harvest attempt stops on one of three things:

| | Meaning | Next drag |
|---|---|---|
| Scroll position stops advancing (after a retry) | Facebook may still be hydrating | retries |
| 4 screens that produced new listings and kept none | This attempt's distance budget is spent | retries |
| 14 screens scrolled | This attempt's total budget is spent | retries |

Note what the middle row counts, and §0.1 for why: screens that produced nothing
*new* are not counted at all.

Measured after the fixes, signed in, 10 mi: a fill publishes 19 cards, and a
top-up returned `26 raw, 0 unparsed, 2 dupes, 24 new, 9 in radius` — 12 kept over
6 screens. Roughly a third of what Facebook offers survives the radius.

### 0.2 What a browse card is worth

Markup only, and permanently: the browse page embeds no usable listing payload —
6 `"listing"` blocks against 20 rendered cards, none carrying a title, price or
photo (`embedded-payload.md` §8) — and signing in does not extend the payload on
any surface (`logged-in-findings.md` §2). So every card in a signed-in Discover
is at the quality level §4.6 describes, from the first one rather than from the
sixteenth. Titles, prices, cities and ids all come off the `aria-label`, which
carries them; timestamps, delivery types and sold state do not exist until the
card is opened.

This is why the engine has `loadCards` alongside `load`. Putting the browse page
through the payload harvester would spend its full 20-second timeout waiting for
something that is never coming — on the screen the app opens with.

### 0.3 What the bottom of the screen says

The footer counting what the distance filter removed, with a button offering to
widen the radius by five miles, is **gone**. So is `Preferences.widenedRadiusKM`.

It was wrong in two independent ways. It was addressed to nobody: §4.3 records
that a home feed is scrolled until something catches the eye, so a disclosure
placed after the grid is functionally invisible — that criticism was already
written down and the fix proposed there (move it into the header) is what
happened. And §4.4 records that the offer it made is a lie for exactly the users
who now get Facebook's feed: signed in, the account's own radius is a floor the
app cannot raise, so tapping "try 15 mi" changes a number and not the results.

What replaces it:

| | Bottom of Discover |
|---|---|
| Anonymous (always at `reachedEnd`, §0.0) | The offer to log in — nothing else |
| Signed in, fresh-fill tail or top-up running | Two rows of card skeletons |
| Signed in, top-up paused | Nothing; the next drag can retry |

The anonymous row is not a nudge dressed as information. Its feed genuinely
stops, so "log in to keep scrolling" is a statement about the next scroll. It
also stands in for "nothing else in your area", which would be the wrong claim
to make there: the feed ended because the session ran out, not the neighbourhood.

The radius moved into the caption beside the heading — "Facebook Marketplace,
within 10 mi of Seattle, WA" — which is where §4.3 said to put it and is read
before the scrolling rather than after it stops.

Search pagination follows the same retryable rule. Three windows that add no
cards pause that attempt without claiming the area or result set is exhausted;
the next drag may try again, and two skeleton rows stand in for the incoming
page while it does. The "already viewed" notice keeps its own line and its own
undo, because that filter is the app's own and has something to undo.

Search and Discover share the navigation shell and `PaginatedListingGrid`, but
not a webview, store, or scroll view. Both scroll surfaces remain mounted while
the other is visible. Submitting a search resets only Search to its top; Cancel
reveals Discover at the same cards and offset without loading it again. Keeping
the engines separate is load-bearing: navigating one hidden webview between a
browse URL and a search URL would make either surface destroy the other's paging
context.

The shared result grid is row-aligned rather than masonry. Every listing reserves
the same 180-point image, two title lines, and one location/distance line, even
when a field is missing or shorter. Loading skeletons use the same two-column
geometry. That makes each row a stable unit for pagination, future controls, and
the Search ↔ Discover transition instead of letting card copy reshape the feed.
Pagination placeholders are inserted into that same grid, so an odd final result
is paired with the first skeleton instead of leaving a hole above a detached
block of loading rows.

The blanket empty state — a full-screen "Nothing saved yet" with advice about
bookmarks — is gone with them. An empty home screen is a statement about the
area or the session, and Discover's own footer makes it.

---

## 1. The search-seeded feed — removed 2026-08-10

Up to three of the user's own recent searches, re-run and mixed, topped up from
onboarding interests when history was short. Gone; §0 is why. Kept here because
three of its findings outlived it and one of its rules did not.

**Still true, and load-bearing elsewhere:**

- **An engine can't be shared.** Not with the browse tab, for the reason
  `ComparableSearch` has its own: the home feed and the user's first search
  would take turns navigating one webview. And not between concurrent searches
  either — an engine is one `WKWebView` with one in-flight navigation, and the
  markup fallback reads whatever document that webview is *currently* showing,
  so two concurrent searches through one would read each other's cards. Discover
  is down to one engine now, but the rule is what keeps it from borrowing
  someone else's.
- **`RequestPacer` had a reservation bug**, found by being the first thing in the
  app to make two requests at once: `waitForSlot` slept and *then* stamped
  `lastRequest`, and an `await` inside an actor method lets the next call in, so
  all three callers measured the same gap and two left in the same millisecond.
  It now reserves the slot before sleeping. Nothing else has exercised that path
  since; it is one concurrent caller away from mattering again.
- **A fill publishes once.** It used to republish after each search, so the grid
  arrived in three instalments and reflowed twice — cards moving out from under
  a thumb, which is the one thing a feed must not do — and it made the wait look
  longer by drawing attention to each stage of it. The section holds a skeleton
  under its heading and caption for the whole fill; on a *refresh* the current
  cards stay up instead, because there is something better than a skeleton to
  look at and the gesture meant "get me a fresh one", not "take this away".

**Dead with the feed:** the seed rules (recent-first, interests shuffled in
behind, shuffle-then-take-ten, round-robin across buckets), the caption that
named them ("From your searches for lamp · couch · desk"), and the concurrency
that made three page loads bearable — 13–20 s sequential, 2.0 s and 3.3 s
concurrent on two measured launches. Two of the three hidden webviews went with
it.

One rule died that is worth naming, because it was right: the search-seeded feed
**applied the user's own filters** — delivery, price, condition, sort — on the
grounds that a Discover ignoring them would show results the user's own search
wouldn't. The browse URL carries no parameters at all, so the home screen no
longer honours any of them. That is §4.10, promoted from a signed-in-only
complaint to the whole screen.

## 2. Cache lifetime

Four things rebuild it: **relaunching the app, pulling to refresh, changing the
city or the radius, and the session changing.** Nothing else.

**The radius is a trigger because this feed applies it while fetching**, not on
the way to the screen (§0.1). Widening it therefore cannot be honoured by
re-filtering what is in hand: the cards it would now keep were dropped during
the fill and never stored. It doesn't refill on the spot — the sheet that
changed it is over the top of the feed, so there'd be nothing to watch — it
marks the feed stale and rebuilds when that sheet closes. Both sheets that can
reach the radius, Settings and the location picker, do this.

Editing interests used to be on this list and no longer is: they aren't an input
to the feed any more (§6.1).

**Signing in or out is a stronger trigger than any of them**, and it used to be
explicitly excluded. It no longer can be: the session decides whether this feed
scrolls and how Facebook ranks it (§0), so a stale answer isn't an hour-old
shuffle. `DiscoverFeed` records the session it filled under and compares on every
`loadIfNeeded`, so both sign-in routes and a Facebook-side expiry are covered
without any of them having to remember to call it.

It reads the cookie store itself rather than taking `ListingStore.session` from
the caller, because that value is set by an async check that may not have landed
on the launch this screen fills on — capping a signed-in user's feed at one page
and marking it done would leave them there until they relaunched.

Not a new search: nothing on this screen is built from search history any more,
so a search has no bearing on it at all.

A change of city **is** a trigger, and used not to be. The old reasoning was
that a reshuffle under someone halfway down the feed beats a feed that is an
hour old, which is true of a reshuffle of the same place and false here: a home
screen of listings in the city the user has just left isn't stale, it is wrong,
and it is exactly what they land on when they clear the search box.

**Nothing is written to disk.** Restoring a shuffle from yesterday and presenting
it as today's would be a lie the cache tells for free. The cost is a slower cold
start, which §4 tracks.

## 3. Why not Facebook's own feed — *logged out*

> **Scope note, 2026-08-10.** Everything below was measured with no account. It
> was the case for building the signed-out feed out of the user's own searches
> instead; that feed is gone (§1) and this is now the standing description of
> what an anonymous Discover *is*, not an argument against shipping it. Nothing
> here has been contradicted — the churn is real, and the app's answer is to
> claim nothing in the caption that the feed can't support.

The first version loaded `/marketplace/<place>/` — "Today's picks". Measured,
logged out, three loads of the identical URL in one session:

| | vs previous load |
|---|---|
| load 1 → 2 | **0 of 5** top cards survived |
| load 2 → 3 | 17 of 20 overlapped |
| load 4 | reverted to load 1's contents |

The geography swung with it: 9-of-20 in San Francisco on one load, an East Bay
spread reaching Napa and Antioch (~50 mi) on the next. That is a couple of cached
popularity pools being alternated, not a ranking.

Logged out there is also very little to personalise *with*: an IP, an anonymous
cookie, and whatever item pages that cookie has opened. The last one does reach
Facebook — every engine shares one persistent `WKWebsiteDataStore`
(`BrowserSession.dataStore`), so opening a listing is visible to it. Whether that
feeds the picks is **untested and expensive to test**: the feed's own churn
(0–100% between loads) is far larger than the effect a personalisation test would
be looking for. One trial — three guitar item pages, then a reload — returned one
guitar in twenty, which establishes nothing.

It was also markup-only: the embedded payload is effectively absent on that path
(6 `"listing"` blocks against 20 rendered cards, none carrying a title, price or
photo — `embedded-payload.md` §8). That was the *smaller* of its two problems.

**The trade this described has since been taken the other way.** The
search-seeded feed bought relevance with novelty — it could not show you
anything in a category you had never asked about or picked at onboarding — and
§0 is the decision to accept a churny popularity pool that can. What that means
in practice is above; what it means here is that none of the measurements in
this section are stale, only their conclusion.

## 4. Known issues

Open, in rough order of how likely they are to bite.

### 4.1 The anonymous feed is thin after the radius

The live problem with §0's swap, and the one to watch. Four measured fills, San
Francisco, 10 mi, signed out, 2026-08-10:

| | Raw cards | Ships | In radius |
|---|---|---|---|
| run 1 | 20 | 1 | 4 |
| run 2 | 20 | 0 | **3** |
| run 3 | 20 | 1 | 10 |
| run 4 (a pull, ~30 s later) | 20 | 1 | 7 |

Always twenty raw; 3 to 10 of them survive the radius. Facebook's anonymous feed
reaches wherever it likes — §3 measured it spreading to Napa and Antioch, ~50 mi
— and there is no second page to make up the difference (§0.0), so a bad draw is
a three-card home screen with nothing to do about it. The search-seeded feed it
replaced published up to 30, and the spread here is §3's churn measured from a
different angle: same URL, same session, half the feed different.

Neither obvious lever is free. Keeping unknown-distance cards is the wrong one:
§0.1 explains why this feed drops them, and the runs above resolved every place
they were given, so the losses are genuine distance rather than geocoding.
Widening the radius is the user's setting, not ours to override. The honest
candidates are to say more in the empty case than the grid currently does, or to
treat "your area is quiet without an account" as a first-class state on this
screen rather than an empty grid with a login button under it. Not implemented.

### 4.2 Cold start is one page load, and it is all of the wait

With no disk cache (§2), the first launch of a session has nothing to paint and
has to fetch everything. That is now a single browse page: **3.9 s** measured
signed out, against ~10.1 s for the same screen when the fill also scrolled
(§0.0) and 2–3 s for the three concurrent searches before that (§1) — which were
faster to *finish* and slower to *start*, since they needed three page loads to
begin at all.

What remains: it is still a network wait on a screen the user did not ask to
wait for, and it is now a floor set by one Facebook page load with no
concurrency left to hide behind. A bad connection restores the old problem. The
lever at that point is the no-disk-cache rule, which exists for honesty (§2),
not for speed.

### 4.3 The distance-filter disclosure is at the bottom, where nobody is

**Fixed 2026-08-08**, roughly as proposed. The footer is gone and the radius is
stated in the caption beside the heading (§0.3).

What went with it is the *count*: nothing now says "11 were further than 6 mi",
only that the feed is limited to 6 mi. That is a deliberate trade — a standing
statement of the constraint, read before scrolling, against a per-load tally read
after it — but it does mean a feed that came back thin and a feed that was cut
to ribbons look identical on screen. The counts are still in the log.

### 4.4 Signed in, Facebook's own radius is a floor we cannot raise

An account carries its own Marketplace radius, it is the only thing that actually
filters server-side, and the URL parameter is ignored (`filter-parameters.md`
§11). So a signed-in user whose account says 10 mi cannot see a 30-mile listing
in Discover no matter what the app's control says — including "Any".

**This got worse before it got better.** The widen button — a lie for exactly
these users — is gone (§0.3). But the signed-in feed is now *entirely* Facebook's,
so the account radius is the outer bound on the whole home screen rather than on
one section of a search. The app's own radius can only narrow what arrives. A
user whose account says 10 mi and whose app says 40 will see 10 miles of
listings and nothing to say why.

The honest fix is to read the account's radius off the feed's own location pill
(`DesktopFeedEngine.readLocation` already parses it) and say so when it is
tighter than the app's. Not implemented.

### 4.5 A saved listing can appear twice on the same screen

The Saved rail and Discover are independent, so a saved item that Facebook also
puts in the feed renders in both. Not a correctness bug — the rail uses `RecentCard`, which
carries no `matchedGeometryEffect`, so the hero-transition ids stay unique — but
it is the same card twice within one scroll.

### 4.6 Discover cards are markup-grade until opened

**Every** card, from the first one, signed in or out: the browse page embeds no
usable payload (§0.2). Nothing downstream should assume an exact
`creation_time`, `delivery_types` or sold state on a Discover card. Opening one
enriches it from its item page.

Worse than it was — the search-seeded feed carried the embedded payload on the
first ~15 cards of each search — and unavoidable on this surface.

### 4.7 The three-interest requirement has outlived its reason

**Closed as a Discover issue, opened as an onboarding one.** The old 4.7 was
about search history retiring the interests once there were three of it;
`DiscoverFeed` no longer reads either, so there is nothing here to fix.

What is left is a first-run gate that stops everybody, including users who sign
in immediately, to collect three categories that now do one thing: fill the
search field's "Try" list (§6.1). The number three came from
`DiscoverFeed.searchCount`, which no longer exists. Making the step optional, or
cutting the minimum, is a live question and is not this document's to answer.

### 4.8 An interest's search term is a guess

Each interest searches for the searchable half of its category, and some of
those choices are more obviously right than others. "Furniture" and "Plants"
match how people title listings; `home decor` for "Home & garden" and
`sports equipment` for "Sports gear" are editorial guesses at what a listing in
that category actually says. None have been measured against result counts.

Much cheaper than it was: a bad term used to cost a third of a fresh install's
home screen, and now costs one suggestion that returns little when tapped.

### 4.9 "There's nothing else in your area" was inferred, never observed

**It was simply wrong** — first because it fired on the first scroll of every
signed-in session for the four implementation failures in §0.1, then in
production because four consecutive windows outside the radius permanently
ended an otherwise live feed. Neither condition had anything to do with the
area actually running out.

A stationary scroll position is not conclusive either. It may be the end of the
feed, a transient network boundary, or a WebKit/script failure; whether the
signed-in feed caps has still never been observed. Four dry screens is likewise
a useful time budget for one attempt, not evidence about a ranking nobody has
documented. Both now pause the current harvest and leave the next drag free to
retry. Signed-in Discover therefore makes no terminal claim.

**The anonymous case is no longer one of these**, which is the one improvement
here since it was written: that feed reaches its end by construction (§0.0) and
says "log in to keep scrolling", a claim about the session it can support,
rather than a claim about the neighbourhood it cannot.

The general lesson, which cost most of the debugging: **every failure path in the
scroll returned the same value as "the feed ended"** — a nil script result, an
undecodable reading, a clamped scroll — so four unrelated bugs all surfaced as
one confident sentence about the user's neighbourhood. `feedScroll` now logs why
it returned nil, and `nearby` counts raw, unparsed, ships, dupes and in-radius
separately rather than reporting "0 new".

### 4.10 Discover ignores the user's filters

The browse URL carries no parameters at all: no `sortBy`, no `deliveryMethod`,
no price bounds. That is what "the default Discover screen" means, and those
parameters have never been verified on a browse path — the README's surface
table lists them `?` for Web browse, and only `/search/` has been tested.

The visible consequence is that someone who has set "Under $50" or "Local pickup
only" sees a home screen that ignores both, while their searches honour them.
The delivery half is partly covered — `Ships`-badged cards are dropped on the
device — and the rest is not.

**This now applies to everybody.** The search-seeded feed deliberately did apply
them (§1), so removing it took the last part of Discover that honoured a filter
the user set.

Worth measuring before adding: send one filter to a browse URL and check whether
the result set moves, using the §3 discipline of comparing result sets rather
than trusting the chip.

### 4.11 A top-up can cost several seconds

A `loadMoreIfNeeded` may scroll up to 14 screens before
returning anything. Two rows of skeleton cards now reserve the incoming space
under the existing grid for the duration; they replace the detached circular
spinner that gave no sense of what was loading.

Validated against a live signed-in feed with an intentionally sparse radius.
The levers remain `scrollBudget`, `dryScreenBudget`, and triggering the top-up
earlier than 10 cards from the end.

Signed-in only: an anonymous feed never tops up (§0.0), which is the one form
of silent scrolling that has been removed rather than tuned.

## 5. If Discover ever draws on external or older sources

Right now every card in Discover was fetched seconds ago, in this session, which
hides two problems that a wider source would expose immediately. Anything that
adds cached, shared, or externally-supplied listings has to deal with both.

### 5.1 Photo URLs expire

fbcdn image links are generated with an expiry and a signature — they are not
stable addresses for a photo. A URL captured a couple of days ago will stop
resolving, and the failure is silent: `AsyncImage` renders an empty frame, so a
stale feed degrades into a grid of grey rectangles rather than an error anyone
can act on.

Consequences for any design that stores cards for longer:

- **Never treat a stored photo URL as durable.** It is a fetch hint with a
  shelf life, not an identifier.
- **The identity built from it is fine.** `Listing.photoFBID` parses the fbcdn
  *filename segment*, which is stable across surfaces and outlives the signed
  URL — that is why dedupe is an equality check. Identity and fetchability are
  different properties of the same string and only one of them expires.
- **A card whose image won't load needs a visible state**, or "expired" and
  "still loading" look identical forever.

### 5.2 Sold status goes stale, and we can't cheaply re-check it

A cached card says what was true when it was captured. Listings sell. The app has
no push, no polling, and no route to a listing's current state short of loading
its item page — which is a request per card, and exactly the automation-shaped
traffic the app avoids everywhere else (`decision-desktop-primary.md`).

It is worse than ordinary staleness, because a default search *cannot* see sold
listings at all: a plain search returns 0 sold and 0 pending, so everything the
app has ever shown is live **by construction of the query**, not by verification
(`filter-parameters.md` §10). A stored card carries no evidence of still being
for sale; it carries evidence that it was for sale once.

So any longer-lived Discover has to:

- **Say how old a card is**, rather than presenting stored state as current.
- **Re-check on open, never in bulk.** The detail path already re-fetches, and
  the item page does carry `is_sold` — read anchored on `location_text`, since a
  sold page carries 21 `is_sold` values and only one of them is the listing's.
- **Not claim sold status it hasn't seen.** `ListingDetail.isSold` is optional on
  purpose: `nil` means "nothing told us", never "available".

Both risks point the same way: the further Discover moves from "fetched just
now", the more it needs to state its own age rather than imply freshness.

## 6. The two things this screen used to read, and no longer does

**Discover's only inputs are now the place, the radius, and the session.**
Interests and search history were the other two, and both have been cut loose.
They are documented here because the app still collects both, and what they are
*for* changed without their storage or their settings changing at all.

### 6.1 Interests

Picked during onboarding, required, three minimum, stored as `Interest` ids in
`Preferences.interests` (`docs/onboarding.md`). They were what Discover was made
of before there was any history, and that was their whole reason to exist.

What is left is the search field's "Try" list: the completion inserted is the
*term*, not the label, because searching for "Home & garden" finds nothing. That
is a real job and a much smaller one than a required first-run gate is priced
for — see 4.7.

Ids rather than labels or terms, so a category can be re-worded or its search
term improved without emptying anybody's saved choices — and `Interest.resolve`
drops ids this build no longer knows, so a retired category can't sit in the
count as a ghost.

### 6.2 Search history

Recording a search briefly meant more than it looked like: while Discover seeded
from `recentSearches`, anything searched once became the home screen until it
aged out, which is a different bargain than the user struck when the list only
drove autocomplete. That is over — Discover doesn't read it — and the rules it
prompted are worth keeping anyway, because a suggestion list is still a list of
what you looked for, drawn every time the field takes focus.

Both are enforced in `Preferences.recordSearch` rather than at call sites:

- **`recordSearchHistory` gates it** — Settings → History → "Include searches in
  history". Off means a search leaves no trace in the suggestions. It does not
  clear what is already saved; "stop recording" and "erase" are different
  requests and there is a separate button for the second.
- **The Seller tab never records.** Its search terms are derived from whatever
  the user is drafting a listing for, so recording them would offer the thing
  you are trying to sell back to you as something to buy. `SellerToolsModel`
  reads `Preferences` for location and filters and never writes to it.
