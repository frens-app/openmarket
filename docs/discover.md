# Discover: the home screen feed

**Date:** 2026-08-08
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

## 0. There are two Discovers, and the session picks

**Signed in:** Facebook's own Marketplace feed for the user's place — the default
Discover screen — scrolled, and cut to the radius the user set.

**Signed out:** up to three of the user's own recent searches, re-run and mixed.
This is the feed §1 describes, and it is unchanged.

The split replaced a single search-seeded feed on 2026-08-08. §3 is the case
against Facebook's feed and every measurement in it still stands — **logged
out.** All of it was measured with no account, and the two objections it raises
are both objections to *anonymity* rather than to the feed:

| §3's finding | Why an account changes it |
|---|---|
| 0–100% churn between identical loads; geography swinging 50 mi | That is what a couple of cached popularity pools look like. Facebook serves them because an anonymous session gives it an IP and a cookie to rank with |
| Nothing to personalise with | An account is a real history — more than this app can assemble from search terms held on the device |
| Markup-only, no embedded payload | Still true, signed in or out (§0.2). Now a cost we accept rather than a reason not to |

What the signed-in user gets that the search-seeded feed structurally cannot
give them is **novelty** — §3's closing trade, taken the other way. The
search-seeded feed cannot show you anything in a category you have never asked
about or picked at onboarding; Facebook's feed is under no such limit.

And the signed-out user keeps a feed built entirely from signals that never
leave the device, which is the app's position when there is no account in play.
That the better screen is behind a login is the honest shape of the situation
rather than a lever: the offer at the bottom of the signed-out feed (§0.3)
describes something that actually happens.

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

A harvest stops on one of three things:

| | Meaning | `reachedEnd` |
|---|---|---|
| Scroll position stops advancing (after a retry) | The literal end of the feed | yes |
| 4 screens that produced new listings and kept none | The end of the part of it this app is for | yes |
| 14 screens scrolled | This call's turn is over | no — the next scroll resumes |

Note what the middle row counts, and §0.1 for why: screens that produced nothing
*new* are not counted at all.

Measured after the fixes, signed in, 10 mi: a fill publishes 19 cards, and a
top-up returned `26 raw, 0 unparsed, 2 dupes, 24 new, 9 in radius` — 12 kept over
6 screens, `exhausted false`. Roughly a third of what Facebook offers survives
the radius.

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
| Signed out | The offer to log in — nothing else |
| Signed in, more to come | Nothing (a spinner while a top-up runs) |
| Signed in, `reachedEnd` | "There's nothing else in your area." |

The radius moved into the caption beside the heading — "Facebook Marketplace,
within 10 mi of Seattle, WA" — which is where §4.3 said to put it and is read
before the scrolling rather than after it stops.

The same footers now end a **search result set**, which previously ended in
silence for a signed-in user; `ListingStore.reachedEnd` records three scrolls
that produced nothing. The "already viewed" notice keeps its own line and its
own undo, because that filter is the app's own and has something to undo.

The blanket empty state — a full-screen "Nothing saved yet" with advice about
bookmarks — is gone with them. An empty home screen is a statement about the
area or the session, and Discover's own footer makes it.

---

## 1. The signed-out feed

Up to three of the user's own recent searches, re-run and mixed.

| Step | Rule | Why |
|---|---|---|
| Seed | `recentSearches`, newest first, up to 3 | The one strong statement of interest anyone makes in this app |
| Seed fallback | The interests picked at onboarding, shuffled, topping up to 3 | A new install has no history and this is the screen it lands on. Shuffled because there are usually more than three and the array is in pick order — taking the first three every launch would make the rest decorative |
| Sample | shuffle the results, *then* take 10 | Taking the top 10 would make Discover the first rows of three searches — which the user could have got by running them |
| Mix | round-robin across the three buckets | The mix has to be visible in the first row, not three blocks stacked up |
| Filters | the user's own — delivery, price, condition, sort | A Discover that ignored them would show results their own search wouldn't |
| Drop | cards badged `Ships` | A local marketplace's home screen isn't a shipping catalogue |
| Distance | applied on-device, as everywhere | No surface honours `radius` (§3) |

**One engine per search**, and all of them run at once.

An engine can't be shared, in either direction. Not with the browse tab, for the
reason `ComparableSearch` has its own: the home feed and the user's first search
would take turns navigating one webview. And not between the three searches
either — an engine is one `WKWebView` with one in-flight navigation, and the
markup fallback reads whatever document that webview is *currently* showing, so
three concurrent searches through one would read each other's cards.

The cost is two more hidden webviews resident for the app's lifetime; the return
is the entire wait on the home screen, since nothing is shown until the fill
finishes:

| | Fill, three searches |
|---|---|
| Sequential, one engine | 13–20 s |
| Concurrent, one engine each | **2.0 s** and **3.3 s** on two measured launches |

No extra request budget — `RequestPacer` is shared and still spaces the starts
0.4 s apart. It did not, at first: `waitForSlot` slept and *then* stamped
`lastRequest`, and an `await` inside an actor method lets the next call in, so
all three callers measured the same gap and two of them left at the same
millisecond. It now reserves the slot before sleeping. Nothing had exercised
that path before, because nothing in the app had ever made two requests at once.

**A fill publishes once, when all of it is in.** It used to republish after each
search, so the grid arrived in three instalments and reflowed twice — cards
moving out from under a thumb, which is the one thing a feed must not do. It
also made the wait look longer than it was by drawing attention to each stage of
it. The section holds a skeleton under its heading and caption for the whole
fill; on a *refresh*, the current cards stay up instead, because there is
something better than a skeleton to look at and the gesture meant "get me a
fresh one", not "take this away".

**The seed terms are printed under the heading** ("From your searches for
lamp · couch · desk"). This is load-bearing, not decoration: a shuffled feed with
no stated basis is indistinguishable from a random one, which was the complaint
that got the previous version deleted.

Each seed carries where it came from, and the sentence changes with it — "From
your interests: Furniture · Bikes · Plants" on a fresh install, "From your
searches and interests" while history is filling up. Printing the interest
labels under the searches wording would claim a history the user doesn't have
yet, on a screen whose entire job is to be legible as a consequence of something
they did.

Note the labels are not the terms. An interest searches for the searchable half
of its category — "Home & garden" runs `home decor`, "Jewellery" runs `jewelry`
— because Marketplace search is a fuzzy match over listing text, not a category
filter. The chip is what the user chose; the term is what finds anything.

## 2. Cache lifetime

Four things rebuild it: **relaunching the app, pulling to refresh, editing
interests in Settings, and the session changing.** Nothing else.

Editing interests doesn't change what the feed *contains*, it changes what the
feed is *for*. It doesn't refill on the spot either — the Settings sheet is over
the top of the feed, so there'd be nothing to watch — it marks the feed stale and
rebuilds when the sheet closes.

**Signing in or out is a stronger trigger than any of them**, and it used to be
explicitly excluded. It no longer can be: the session decides which of the two
feeds this is (§0), so a stale answer isn't an hour-old shuffle, it is somebody
else's screen. `DiscoverFeed` records the session it filled under and compares
on every `loadIfNeeded`, so both sign-in routes and a Facebook-side expiry are
covered without any of them having to remember to call it.

It reads the cookie store itself rather than taking `ListingStore.session` from
the caller, because that value is set by an async check that may not have landed
on the launch this screen fills on — starting the wrong feed and marking it done
would leave a signed-in user on the signed-out one until they relaunched.

Not a new search — recent searches seed the signed-out feed, so every search
would otherwise throw away the screen the user is about to return to, and they'd
come back from a search to one mid-reload. Not a change of city either: a
reshuffle under someone halfway down the feed is worse than a feed that is an
hour old.

**Nothing is written to disk.** Restoring a shuffle from yesterday and presenting
it as today's would be a lie the cache tells for free. The cost is a slower cold
start, which §4 tracks.

## 3. Why not Facebook's own feed — *logged out*

> **Scope note, 2026-08-08.** Everything below was measured with no account, and
> it is why the signed-*out* feed is still built from the user's own searches.
> It is no longer an argument against Facebook's feed in general; §0 sets out
> which of these findings an account changes and which it doesn't.

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

**What the current design gives up is novelty.** Discover cannot show you
something in a category you have never asked about *or picked at onboarding*.
That is the trade: relevance over surprise, from signals that never leave the
device. Interests widen it slightly — eighteen categories is more range than
most people's recent searches — but the ceiling is still the user's own stated
taste, by construction.

## 4. Known issues

Open, in rough order of how likely they are to bite.

### 4.1 Junk terms in history become permanent home-screen seeds

Observed live: a mangled term from an earlier session — `Couchantique writing
desk`, two searches run together — was one of the three seeds. Facebook's fuzzy
matching rescued it into desk results, but a term that returns **nothing**
silently costs a third of the feed, and there is no signal to the user that it
did.

Two candidate fixes, neither implemented: don't record a term that returned zero
results, or have Discover skip a seed that comes back empty and fall through to
the next one. The second is better — it also handles a term that worked once and
stopped, like a sold-out model name.

Interests make this worse rather than better, because there is now something
good to fall through *to*: a junk term costs a third of the feed that an
interest would otherwise have filled.

### 4.2 Cold start is still three page loads — but they overlap now

**Largely fixed 2026-08-07.** With no disk cache (§2), the first launch of a
session has nothing to paint and has to fetch everything. Running the three
searches concurrently took that from 13–20 s to 2–3 s (§1), which is short
enough to hold a skeleton through rather than something to paper over.

What remains: it is still a network wait on a screen the user did not ask to
wait for, and it is a floor set by the slowest of three Facebook page loads, so
a bad connection restores the old problem in full. The levers if that shows up
are `searchCount` and, at that point, reconsidering the no-disk-cache rule —
which exists for honesty (§2), not for speed.

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

The Saved rail and Discover are independent, so a saved item matching a seed term
renders in both. Not a correctness bug — the rail uses `RecentCard`, which
carries no `matchedGeometryEffect`, so the hero-transition ids stay unique — but
it is the same card twice within one scroll.

### 4.6 Discover cards are markup-grade until opened

Signed out, cards come from search results, so the first ~15 of each search carry
the embedded payload and anything past that is markup only. Signed in, **every**
card is markup only from the first one (§0.2). Nothing downstream should assume
an exact `creation_time`, `delivery_types` or sold state on a Discover card.
Opening one enriches it from its item page.

### 4.7 Three searches retire the interests completely

Seeds are recent-first and there are three of them, so the moment someone has
three searches in history their interests stop contributing anything at all —
including a one-off search for a gift, or a term typed once a month ago. The
standing preference loses to the incidental one, permanently, and the only route
back is clearing search history.

The fix is probably a mix rather than a precedence: two searches and one
interest, say, so a chosen category keeps a seat. Not implemented, because it
wants a real feed to judge — the alternative failure is a home screen that keeps
showing furniture to someone who has moved on to bike parts.

Note this only bites logged out now, which lowers the priority without changing
the argument.

### 4.8 An interest's search term is a guess

Each interest searches for the searchable half of its category, and some of
those choices are more obviously right than others. "Furniture" and "Plants"
match how people title listings; `home decor` for "Home & garden" and
`sports equipment` for "Sports gear" are editorial guesses at what a listing in
that category actually says. None of them have been measured against result
counts, and a term that under-returns costs a third of a fresh install's feed —
the same failure as 4.1, with nobody to blame it on.

### 4.9 "There's nothing else in your area" is inferred, never observed

**It was also, for a while, simply wrong** — it fired on the first scroll of
every signed-in session, for the four reasons in §0.1, none of which had anything
to do with the area. Fixed; the wider point stands and is worth keeping.

The message fires on either of §0.1's two `reachedEnd` conditions, and only one
of them is what it says. A position that stops advancing is the end of *the
feed*, which may be a cap rather than an exhausted area — the logged-out browse
surface caps at ~24 (README's surface table), and whether the signed-in one caps
has still never been observed, because in testing it never stopped. Four dry
screens is a heuristic about a ranking nobody has documented.

So the sentence is a reasonable summary of "we scrolled and found nothing else
close enough", stated more confidently than the evidence supports. The two causes
are now logged separately, which is what makes the next round of this decidable.

The general lesson, which cost most of the debugging: **every failure path in the
scroll returned the same value as "the feed ended"** — a nil script result, an
undecodable reading, a clamped scroll — so four unrelated bugs all surfaced as
one confident sentence about the user's neighbourhood. `feedScroll` now logs why
it returned nil, and `nearby` counts raw, unparsed, ships, dupes and in-radius
separately rather than reporting "0 new".

### 4.10 The signed-in feed ignores the user's filters

The browse URL carries no parameters at all: no `sortBy`, no `deliveryMethod`,
no price bounds. That is what "the default Discover screen" means, and those
parameters have never been verified on a browse path — the README's surface
table lists them `?` for Web browse, and only `/search/` has been tested.

The visible consequence is that someone who has set "Under $50" or "Local pickup
only" sees a home screen that ignores both, while their searches honour them.
The delivery half is partly covered — `Ships`-badged cards are dropped on the
device, same as before — and the rest is not. Contrast §1's rule for the
signed-out feed, which deliberately does apply them.

Worth measuring before adding: send one filter to a browse URL and check whether
the result set moves, using the §3 discipline of comparing result sets rather
than trusting the chip.

### 4.11 A top-up can cost several seconds of silent scrolling

A `loadMoreIfNeeded` may scroll up to 10 screens at ~0.9s of settling each before
returning anything, and the spinner only appears under cards that are already on
screen. In a sparse area — where most screens are dry — the user reaches the
bottom and waits with nothing to read.

Untested against a real sparse feed. The levers are `scrollBudget`,
`dryScreenLimit`, and triggering the top-up earlier than 6 cards from the end.

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

## 6. The two inputs to this screen, and what that changed

### 6.1 Interests

Picked during onboarding, required, three minimum, stored as `Interest` ids in
`Preferences.interests` (`docs/onboarding.md`). They exist for this file and
nothing else: they are what Discover is made of before there is any history.

Since §0, that is *signed-out* Discover, which puts onboarding in an awkward
place — it requires three interests from everyone, including users who sign in
immediately and will never see a feed built from them. They still drive the
search field's "Try" suggestions (below), and they are what the home screen falls
back to on a sign-out, so the step is not wasted. But "required, three minimum"
was set when this file was the only consumer, and that is no longer true for
everybody.

Ids rather than labels or terms, so a category can be re-worded or its search
term improved without emptying anybody's saved choices — and `Interest.resolve`
drops ids this build no longer knows, so a retired category can't sit in the
count as a ghost.

They are also what the search field offers under "Try", which is the same answer
to the same question: the completion inserted is the *term*, not the label,
because searching for "Home & garden" finds nothing.

### 6.2 Search history

Recording a search used to be a private matter between the search field and its
own suggestions. Seeding Discover from it changed the stakes: anything searched
once becomes the home screen until it ages out, which is a different bargain than
the user agreed to when the list only drove autocomplete.

Two rules follow, both enforced in `Preferences.recordSearch` rather than at call
sites:

- **`recordSearchHistory` gates it** — Settings → History → "Include searches in
  history". Off means a search changes neither the suggestions nor Discover.
  It does not clear what is already saved; "stop recording" and "erase" are
  different requests and there is a separate button for the second.
- **The Seller tab never records.** Its search terms are derived from whatever
  the user is drafting a listing for, so recording them would fill the home
  screen with the thing they are trying to sell. `SellerToolsModel` reads
  `Preferences` for location and filters and never writes to it.
