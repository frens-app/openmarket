# Open Market

A native iOS app for browsing local Facebook Marketplace listings. SwiftUI
renders everything the user sees; a hidden `WKWebView` is the data layer. Any
action that needs an account — messaging, offers, saving on Facebook — hands off
to the Facebook app via a universal link.

**The app is built for a signed-in user.** A Facebook session is what makes
sellers identifiable, keeps results loading past the first page, and lets
Discover show Marketplace's own picks instead of three canned searches — the
measurements are in `docs/logged-in-findings.md`. Signing in happens on
Facebook's own page inside the app; there is no login form of this project's
own, and there won't be. Browsing without an account still works and is worth
shipping — search, distance, filters, saved listings and interest-seeded
Discover all function — but it is the reduced version, and the app says so
rather than selling it as the point.

Two tabs. **Browse** searches and reads listings. **Seller** goes the other way:
describe something you own and it finds what similar things are listed for near
you, what has actually sold, and what to ask.

```
apps/ios/       the app (xcodegen: `xcodegen generate`, then build the OpenMarket scheme)
apps/backend/   placeholder — runtime not chosen yet, see its README
tools/probe/    harness for measuring the live site; every finding below came from it
docs/           findings and decisions, listed at the bottom
```

---

## Which surface has what

Facebook serves two completely different sites depending on the user agent, and
they expose different data. This is the practical breakdown.

Legend: **yes** · **no** · **~** partial or conditional · **?** not yet verified

| | Mobile search | Mobile browse | Mobile item | Web search | Web browse | Web item |
|---|---|---|---|---|---|---|
| **Listing ID** | no | no | n/a | **yes** | **yes** | n/a |
| Title | **yes** untruncated (aria) | ~ truncated | yes | **yes** untruncated | yes | yes |
| Price | yes | yes | yes | yes | yes | yes |
| Was-price (strikethrough) | yes | yes | yes | yes | yes | yes |
| Badge ("Price drop") | yes | yes | — | ? | ? | — |
| City ("San Francisco, CA") | **yes** (aria) | yes | yes | yes | yes | yes |
| **Approximate coordinates** | no | no | **yes** (map URL) | no | no | **yes** (JSON) |
| "Location is approximate" note | — | — | no | — | — | yes |
| Description | — | — | yes (labelled) | — | — | ~ present, unlabelled |
| Condition | **yes** (aria) | ? | ~ layout-dependent | — | — | **yes** |
| Posted ("Listed 5 weeks ago") | — | — | yes | — | — | yes |
| Photos (full set) | — | — | yes (24) | — | — | yes (29) |
| **Seller name** | — | — | **yes** | — | — | **no** |
| Seller joined date | — | — | yes | — | — | no |
| Seller rating | — | — | ~ when present | — | — | no |
| Dimensions | — | — | yes | — | — | yes |
| Category breadcrumb | — | — | yes | — | — | yes |
| **Pagination past first batch** | **yes** (26→50→74→99) | **yes** | n/a | **no** (~16 cap) | **no** (~24 cap) logged out; **yes**, unbounded, signed in | n/a |
| Cards carry `aria-label` | yes | yes | n/a | yes | **first page only** — scroll-inserted cards have none | n/a |
| **Embedded GraphQL payload** | **no** | **no** | **no** | **yes** (per card) | ? | **yes** |
| Exact posting timestamp | no | no | **no** | **yes** (`creation_time`) | ? | **yes** |
| Location settable by URL | **yes** (place id; slug only if it exists) | ~ entry point only | n/a | **yes** (same) | yes | n/a |
| `radius` URL parameter honoured | **no** (stripped) | **no** (stripped) | n/a | **no** (chip only) | ? | n/a |
| Sort / filter parameters honoured | **no** (all stripped) | **no** | n/a | **yes** (all but `radius`) | ? | n/a |
| `latitude`/`longitude` honoured | **no** (ignored, falls back to IP) | no | n/a | **no** (same) | ? | n/a |
| Shipping listings mixed in | yes | yes | — | yes, and filterable | yes | — |

Measured from a `WKWebView` on an iPhone 17 Pro simulator, logged out, between
2026-07-31 and 2026-08-04. "Web" means a desktop user agent — the desktop site
renders fine on iOS; the server keys purely off the UA string.

---

## The findings that shape the app

**Listing IDs exist only on the web surface.** Mobile is WebLite, a
server-driven UI where taps are opaque tokens resolved server-side, so the
client is never told which listing a card is — verified against every pattern
the web surface uses (hrefs, accessibility labels, `listing <id>` phrasing,
long numeric runs). The web surface puts the ID in the `href` *and* in an
aria-label that also carries title, price and city:

```html
<a aria-label="Anthurium Red Gunsal x Bess add, $38, San Francisco, CA, listing 1030250539438843"
   href="/marketplace/item/1030250539438843/?ref=search…">
```

**Item pages carry approximate coordinates — both surfaces, same value.** This
is the only place anything more precise than a city name appears:

- Web: embedded JSON — `"latitude":37.735290527344,"longitude":-122.39318847656`
- Mobile: the same pair inside a static map image URL —
  `static_map.php?…&center=37.735290527344%2C-122.39318847656&zoom=11`

Identical for the same listing on both surfaces, so it's the listing's
published approximate point rather than anything client-derived. It is
deliberately fuzzed — Facebook labels it "Location is approximate" — but it is
far better than a city centroid: for the sample listing it sits ~4.5 km from
the San Francisco centroid the app currently geocodes to.

**How fuzzed, measured (2026-08-06).** Facebook publishes no number for this.
Every range the item page shows — "Within 40 mi" in the sidebar, "San Francisco
· 40 mi" over the picks — is the *viewer's own search radius*; against the
listing it says only "Location is approximate". But the coordinates are
quantised, and 56 cached item pages (46 distinct points, Bay Area, logged out)
recover the lattice exactly:

| axis | step | on the ground at 37.8°N |
| --- | --- | --- |
| latitude | `360/2^16` = 0.0054931640625° | 611 m |
| longitude | `360/2^15` = 0.010986328125° | 966 m |

Worst residual across the sample is `4.6e-10°` — this is exact snapping, not
rounding noise — and five different listings share one identical point, which
is what a grid this size looks like in a dense city. So a published point means
"somewhere in this cell", the cell is **wider than it is tall**, and the true
location is at most ~572 m away (half-diagonal).

`FacebookCoordinateGrid` holds the constants. The map draws the **circle that
circumscribes** the cell rather than the cell itself: Facebook shows an area
around its own listings, and matching that shape is worth more to someone
comparing the two screens than the extra fidelity of a rectangle. The size is
still measured — the circle can overstate slightly at the corners and can never
understate.

The lattice is a *lower* bound: Facebook may also jitter before snapping, and
nothing observable from outside can rule that out.

Coordinates are **per item page only**. Feed cards never carry them, so
card-level distance still has to come from geocoding the city name.

**Those lookups happen in one batch, before a result set is published.** They
used to run through a trickle queue — one geocode every 250 ms, started by each
card's own `.task` — and the distance filter can only remove a card once it
knows where the card is, so the grid was drawn full and then visibly shrank for
several seconds afterwards. `LazyVStack` made it worse: a card only asks for its
lookup when it is built, near the viewport, so the shrinking followed the user
down the page as they scrolled. Measured on "anthurium", San Francisco, newest
first: 24 cards drawn, 19 of them removed one at a time.

Batching it costs almost nothing, because the one-request-at-a-time rule belongs
to a `CLGeocoder` *instance* rather than to the service:

| Twelve Bay Area city names | |
|---|---|
| Trickle queue, 250 ms gap | ~4 s |
| Four serial, no gap | 439 ms |
| **Twelve concurrent, one geocoder each** | **205 ms** |

So `DistanceResolver.resolveAll` runs eight at a time and is awaited immediately
before every publish. The same anthurium search now geocodes 11 new places in
413 ms and draws five cards, once. The place cache persists across launches, so
after a search or two in a metro area the batch is a no-op.

**What this can't fix is enumerating a region in advance.** Seeding the cache
with nearby townships when the location is set would make even the first search
free, but no Apple API lists the municipalities inside a region: `MKLocalSearch`
for "city" in an 80 km box around San Francisco returns *San Diego*, 739 km
away, and "town" returns Town Creek, Alabama. It is a name search, not an
administrative-area query.

That point is also what the detail screen routes against: `MapKitTravelTime`
asks Apple for a walking, driving and transit ETA from the device's own fix
(`MKDirections.calculateETA`). **Both ends have to be real or the row doesn't
draw**: the destination must be the listing's own point, never a city centroid
— routing to the middle of San Francisco from the Inner Sunset returns a
confident "8 min walk" for something an hour away, and a travel time reads as a
plan in a way a fuzzy distance doesn't — and the origin must be a live device
fix, since the chosen search city says which listings come back, not where the
user is. With no fix, an inline prompt offers one. Transit is ETA-only by
design: the SDK marks `MKDirectionsTransportType.transit` as "Only supported for
ETA calculations", which is exactly the question being asked. The row is hidden
outright without a live fix, since the chosen search city says which listings
come back, not where the user is standing.

**Seller identity is mobile-only.** The mobile item page shows a seller name,
join date, and rating where present; the web item page shows none of it.

**Mobile search cards carry everything in an `aria-label`.** The visible text
of a card is only a price and a truncated title, but every card labels itself:

```
Desk for sale - Used - Good - $75 in Oakland, CA
Free Computer desk for sale - Used - Like New in El Sobrante, CA
```

Measured 2026-08-04: **27 of 27 cards** carry one, on both search layouts, and
every card that is actually a listing parses. Two shapes — priced listings put
the price between condition and `in`; free listings prefix `Free ` to the title
and omit the price segment entirely. The only non-parsing label is the Facebook
logo, which isn't a listing and is already excluded by the `scontent` guard.

That single attribute supplies the **untruncated title**, the **city**, and the
**condition**, none of which are in the rendered text. Conditions observed form
a clean set: `New`, `Used - Like New`, `Used - Good`, `Used - Fair`.

**The search layout is decided by the URL, not by chance.** Requesting a place
that differs from the IP-inferred one yields the layout with a city printed on
every card; requesting the place you already appear to be in yields the one
without. Eight search observations, no exceptions:

| requested | IP says | layout |
|---|---|---|
| no place segment | San Francisco | no per-card city |
| `?latitude=&longitude=` (ignored) | San Francisco | no per-card city |
| `/sanfrancisco/` ×4 | San Francisco | no per-card city |
| `/sanjose/` | San Francisco | **city on every card** |
| `/oakland/` | San Francisco | **city on every card** |
| `/107929532567815/` (South SF) | San Francisco | **city on every card** |

This matters much less than it used to, because the aria-label carries the city
either way. It was previously recorded as a "server-side layout lottery"; it
isn't one.

**Condition is web-only among *item* pages.** Mobile item pages come in two layouts,
and only one of them renders a Details/Condition block — measured 1 of 3
listings (2026-08-04). The condition string does appear in the raw HTML of the
other two, which is a trap: it belongs to the "Today's picks" cards at the
bottom of the page, whose `aria-label`s read `"<title> for sale - <condition>"`.
Those sit ~80,000 characters away from the listing's own id and in zero script
tags, so there is no embedded JSON to fall back on. Reading the first HTML match
would silently attribute a neighbouring listing's condition to this one.

Consequence, given the aria-label finding above: condition no longer needs an
item page at all, so the web **item** page is only worth loading for its
embedded coordinates. A full record is card aria-label + mobile item page
(description, photos, coordinates, seller) + one desktop *search* to resolve the
listing id.

**Depth and precision are on opposite surfaces.** Mobile paginates
indefinitely. Desktop cannot: there is exactly **one** free dismissal of its
login overlay per page load. It serves 15 cards with a dismissable "See more on
Facebook" overlay up from the start; clicking Close unlocks scrolling and
paginates to 39; the overlay then returns as a *different* modal offering only
Log In and Create Account — no close control, Escape and backdrop clicks both
no-ops. Hard ceiling: **39 cards, of which only the first 15 carry the embedded
payload** (the rest are markup only, no `creation_time` or `delivery_types`).
All 39 stay extractable behind the modal. `docs/surface-strategy.md` §3.

**Filters and sorting are desktop-only, and `radius` works nowhere.** Facebook's
own desktop controls emit `sortBy`, `deliveryMethod`, `daysSinceListed`,
`itemCondition`, `minPrice`/`maxPrice` and `radius`; every one of them is
verified to change the desktop result set except `radius`, which only repaints
its own chip — `radius=8` and `radius=161` return the same 15 listings, and a
search labelled "Within 5 mi" comes back with results 60 mi out. Mobile strips
all of them: twelve URLs, one per parameter, all normalised back to
`?query=desk` and all returning a byte-identical 26-card page. Neither applying
a filter on desktop and switching user agent mid-session nor driving mobile's
own "Distance" chip (an opaque WebLite action with no href) gets round it.

So the app's radius control is decorative, and distance can only be enforced
client-side against per-listing coordinates. Full matrix in
`docs/filter-parameters.md`.

**The desktop surface embeds its GraphQL response, and it's a goldmine.** Every
card on a desktop search page ships a structured `listing` object — exact
`creation_time` as a unix timestamp, numeric price, `delivery_types`,
`is_sold`/`is_live`, the city's place id, the untruncated title, and the photo
FBID the app already uses as its identity key. That removes the need to call
Facebook's internal GraphQL endpoint at all, which would otherwise mean a
`doc_id` that rotates every few weeks plus a session-bound CSRF token. There is
no public Marketplace API and never has been; the official research API is
cleanroom-only.

Mobile embeds **none** of it — zero occurrences of every key on a page rendering
26 listings, against 15-of-15 on desktop from the same webview. WebLite ships
rendered components, not a hydration payload. Details and verification in
`docs/embedded-payload.md`.

**Freshness and locality trade against each other.** With `radius` dead,
`sortBy=creation_time_descend` returns a genuinely fresh page — first and last
of 24 results were listed one and nine hours ago — but drags the geography out
to Stockton, Davis and Sacramento. `daysSinceListed=1` keeps 10 of 15 results in
the requested city. For a local browser the date filter is the better lever, and
ordering can be done client-side.

**A sold listing's item page renders no gallery at desktop width.** Measured
2026-08-07 at 1280px, the viewport the detail engine uses: zero
`alt="Product photo of ..."` images on three sold item pages, against two to
three on any listing still for sale, and against three on the *same* sold pages
at a narrower viewport. The DOM scrape therefore returned nothing for exactly
the listings the Seller tab's sold strip opens, and the detail screen spent its
full eight-second photo timeout finding that out.

The photos are in the payload regardless. `listing_photos` appears **exactly
once** per item page — against twenty `primary_listing_photo` objects belonging
to the picks rail — so it needs no discriminator, and it does not depend on
anything having rendered. It is now the primary source, with the rendered
gallery appended for anything it missed, deduped by the fbcdn filename's photo
id since the same photo is served at several sizes.

The same page carries the listing's own `is_sold` and `is_pending`, anchored on
`"location_text"` — the discriminator the coordinate extraction already trusts.
That anchor matters: a sold item page carries twenty-one `is_sold` values, one
true for this listing and twenty false ones from the picks rail, so taking the
first or counting occurrences would report a neighbour's availability as this
listing's. Verified both ways: `true` on a sold page, `false` on one still for
sale. The detail screen now dims the photo, stamps SOLD across it, strikes the
price through and greys the button to "Sold — view on Facebook", rather than
relying on a card badge that can be days stale.

**Some search terms return nothing, and it isn't relevance.** Measured
2026-08-07 in San Francisco, logged out, all within six minutes of each other:

| Query | Result |
|---|---|
| `Outside lands` | 24 cards |
| `Outside lands tickets` | **0 cards**, four attempts |
| `Outside lands sunday tickets` | **0 cards** |
| `Tickets` | **0 cards** |
| `Couch` | 24 cards, payload in 0.75 s |

So it is the word, not the phrase, and not the session: `Couch` was fast and
full in the same minute as the empty ones. Nothing that would indicate pushback
appeared either — no login wall, no pacer refusal, no backoff.

The leading explanation is that Marketplace prohibits ticket sales, so a query
naming them is filtered by *policy* rather than scored by relevance. **That is a
hypothesis, not a finding.** The test that would settle it is whether other
prohibited categories behave the same way — firearms, alcohol, animals,
prescription drugs — and it hasn't been run. Worth running, because the two
explanations imply very different behaviour: a policy filter is a stable list we
could recognise and explain, whereas a matching quirk that drops results when a
common noun is added would be a much broader problem with every multi-word
search in the app.

Either way it costs the user twenty seconds to find out. `harvest()` polls until
it gets a non-empty payload and there is no "Facebook returned nothing" signal,
so an empty result set spends the full timeout before giving up, and an empty
page is indistinguishable from a slow one until then. It hits both tabs: a
Seller draft for anything in a filtered category finds no comparables and so
can't price at all.

---

## Onboarding asks for three things, and requires two

Four screens: what this is, **where you're shopping**, **what you shop for**,
and **your Facebook account**. The middle two are gates rather than greetings;
the account is asked for properly and can be passed.

The first run used to be three explanatory cards and a Start button. They were
honest and completely inert — the app came out of them knowing nothing, so the
first screen anyone saw was a hardcoded fallback city searched for a shuffle of
hardcoded categories. Whether that was any good depended on whether the user
happened to live in San Francisco and happened to want furniture.

- **A place**, by device fix or by searching a city — either way it goes through
  Facebook's own picker, so the slug is one Facebook recognises
  (`PlaceChooser`). Distance is the app's organising idea and it is applied on
  this device, so without a place there is nothing to measure from.
- **Three interests**, stored long-term as an array of ids and used as Discover's
  seeds until there's search history. Three because Discover runs three searches
  per fill; fewer would make a first screen out of one topic.

No skip link on either. A skip buys thirty seconds and costs the app any idea of
what to show, and the screen it skips to is the one that then can't do its job.
The explaining is folded into the first screen, where it costs one tap instead
of three. Interests stay editable afterwards in Settings → Interests, and
changing them refills Discover when the sheet closes.

- **A Facebook account**, on the last screen, with the three things it changes
  named on it: seller identity, results that keep loading, and a Discover made
  of Facebook's own picks. The primary button signs in — on Facebook's own page,
  presented by `SignInView` — and "Not now" is a text button underneath it,
  next to an honest line about what the signed-out app still does. This is the
  one step that isn't a gate, because the reduced version genuinely works;
  it is not, for the same reason, buried or apologised for. Signing in here also
  updates the store's session immediately, since the scene-phase re-check that
  normally notices a session won't fire for an app that never backgrounded.

Both requirements are re-checked on every launch rather than trusted to a
one-time flag, so an install that ends up without a place, or with its interests
emptied, gets asked again instead of landing on a home screen with nothing
behind it. Existing installs are asked once: the old "seen the first run" flag
is deliberately not read, because seeing those cards told the app nothing.

---

## The home screen

Three sections, top to bottom, and any of the first two disappears when it has
nothing in it:

**Recently viewed** and **Saved**, one horizontal rail each, both read entirely
from disk. They answer the same kind of question — "the thing I was just looking
at", "the thing I kept" — and both are a route back to one specific listing
rather than something to browse, which is why they're rails: two rows, and then
the screen belongs to something else.

**Discover** is that something else: up to three of the user's own recent
searches, re-run and shuffled together. Before it existed, a new install landed
on an empty state and a search field and had to think of something to type
before the app would do anything at all.

**With no search history, the seeds are the interests picked during
onboarding** — that is what the required three-interest step is for. Searches
are about *now* and always come first; interests are a standing statement made
once, and they recede as history accumulates. The heading says which it used,
because "from your searches for lamp · desk" would be a lie on a screen built
out of a list somebody picked off a menu thirty seconds ago.

Each search's results are shuffled *before* being cut to ten and the three are
interleaved, so Discover is a random sample of three searches rather than their
top rows — which the user could have got by running them. The seed terms are
printed under the heading, because a shuffled feed with no stated basis is
indistinguishable from a random one.

**Facebook's own "Today's picks" was tried first and rejected on measurement:**
three loads of one URL in a single session shared 0 of 5 top cards between the
first and second and 17 of 20 between the second and third, with the geography
swinging from mostly-San-Francisco to an East Bay spread reaching Napa. A
rotating popularity pool, not a ranking — and logged out there is little to
personalise it with anyway.

**It rebuilds on relaunch, on pull-to-refresh, and when interests change.** Not
on a new search — recent searches are the seed, so every search would throw away
the feed the user is about to return to.

**The three searches run at once, one engine each, and the grid appears in one
piece.** It used to run them sequentially and republish after each, which took
13–20 s and reflowed the grid twice under whoever was reading it; concurrent it
measured 2.0 s and 3.3 s on two launches, which is short enough to hold a
skeleton through. Nothing is written to disk, so that fetch happens on every
cold start.

The distance filter applies, as it does to search results. The "only new
listings" filter does *not* — that one means "new to me in this search", and
quietly emptying a feed nobody asked for would be a strange reward for using the
app.

Full design, the measurements behind it, the open issues, and what breaks if
Discover ever holds older cards: **`docs/discover.md`**.

### Search history is a home-screen input now

Seeding Discover from `recentSearches` changed what recording a search means —
anything searched once becomes the home screen until it ages out. So Settings →
History carries **"Include searches in history"**, and the **Seller tab never
records**: its terms come from whatever the user is drafting a listing for, and
recording them would fill the home screen with the thing they're trying to sell.
Both rules live in `Preferences.recordSearch` rather than at the call sites.

---

## The Seller tab

The app has two tabs now. **Browse** is everything above. **Seller** takes a
description of something you own, searches Marketplace for it, shows what is
listed nearby and what has recently sold, and works out what to ask.

It is two page loads per run — the active board, then what has sold — and it
opens no item pages. It shares `RequestPacer` with the browse engines and runs
on its own `DesktopFeedEngine`, so pricing an item doesn't navigate the results
the user was reading. Nothing typed there leaves the phone.

**It can see sold listings, which nothing else in the app can.** A plain
Marketplace search returns **0 sold and 0 pending** cards, so every listing this
app has ever displayed was something still sitting unsold.
`availability=out of stock` is the only route past that, and it works
(`docs/filter-parameters.md` §10). Four things about it shape what the feature
is allowed to claim, all measured 2026-08-07:

- **There is no sale date.** `creation_time` is the only time field on a
  listing, sold or not. So "recently sold" is an inference — listed *n* days
  ago, gone now, therefore sold in **at most** *n* days — and the UI states it
  as the bound it is ("Sold in ≤4 days").
- **The prices are still asking prices.** Facebook publishes what a sold item
  was *listed* at, never what changed hands. An accepted offer below asking is
  invisible.
- **Sold prices are not systematically lower.** San Francisco dressers: active
  asking median $50 across 12, sold-and-listed-at median $52.50 across 10. The
  hypothesis was the obvious one and it didn't survive. The sold set's value is
  liquidity — evidence a price is achievable, and how fast — not a truer price.
- **It is a survivor's list.** Things that failed to sell at a price are exactly
  the ones missing, so it can support "this price works" and can never support
  "this price is too high". The prompt says so in as many words, because a model
  given a set of sold prices will otherwise treat them as a target.

### The on-device writer, and why it's out

An earlier version used Apple's on-device model (`FoundationModels`) to name the
item, choose a price inside the measured band, and draft a description. It
worked — verified against the real model — and it is **removed for now**, for a
reason that has nothing to do with output quality.

`SystemLanguageModel.availability` reports `.available` on the strength of Apple
Intelligence being *switched on*. It says nothing about whether the 3B model
asset is actually installed, and there is no API that distinguishes the two. So
the app passes its availability check, calls the model, and fails — with an
error that arrives bridged to `NSError`, so even the case name is unrecoverable
and the framework's own message is the useless `"The operation couldn't be
completed. (…GenerationError error -1.)"`.

That is the permanent state of the **iOS simulator**, whose assets all carry
`version: (none)` with `update available false` — not downloading, and not going
to. So the feature degraded to an apology on the machine it gets developed on,
and shipped a "may still be downloading" message that was false there. Removing
it costs the title and description and nothing else: every number was Swift's
already, and the price is the median the model was steered towards anyway.

The implementation and its prompts are in commit `1c54a9f`. What was learned is
worth keeping whether or not it comes back, all measured against the real model:

- **It cannot do arithmetic about its own evidence.** Asked to justify its
  figure against fourteen prices it had just been shown, it wrote "you are
  asking CA$20 more than the median price of CA$80". The median was CA$77 and
  the gap was CA$33 — two wrong numbers in one confident sentence, printed under
  the one figure a person acts on. `PriceGuide.explanation` writes that line
  now, and still does.
- **It is not repeatable at the default temperature.** Three runs on one dresser
  returned CA$100, CA$110 and CA$140. `temperature: 0.3` holds it. Its answer
  was also clamped to the observed price range, because a recommendation outside
  the evidence isn't a bolder opinion, it's a number with nothing behind it.
- **It invents condition, and pushing for richer prose makes it worse.** It
  wrote "the rest of the dresser is in good condition" about an item whose only
  stated fact was a scratched top, and "a few minor scratches on the frame"
  about a bike whose seller mentioned none. Asking for each fault in its own
  sentence produced *three* invented faults for a stroller described only as
  "folds flat, barely used".
- **It takes the item's identity from the comparables if you let it.** Given a
  stroller to name and a page of dressers to price against, it titled the
  stroller "IKEA Malm 4 Drawer Dresser White" on all three runs. The comps are
  numerically load-bearing and semantically poisonous, and the prompt has to say
  so.
- **Four narrow calls beat one wide one.** Asked for title, price, rationale and
  body together it wrote a clean title and had slid into advertising copy by the
  fourth field. Split into separate sessions, the same rules held.
- **The safety guardrail is reachable in ordinary use.** "WhiteIKEAMalm dressed"
  trips it where the same words spaced properly do not — a keyboard swallowing
  spaces is enough to get a refusal.

The one job it did that survived is turning "IKEA Malm 6 drawer dresser, white,
barely used, from a pet-free home" into a query that finds anything. `SearchTerm`
does it with a filler-word list, and produced the same query as the model on the
cases tried.

What is left needs no model at all: the market search, the sold check, the
arithmetic, and the price. That was always the load-bearing half.

---

## Feedback from use

From Matt, recorded 2026-08-06. Kept in his words, because a thing a user asked
for reads differently from a thing we thought of — and four of these five landed
on work already on the list, which is worth knowing.

| What he said | Where it's tracked |
|---|---|
| **"location doesn't work"** | Confirmed, and worse than it looked: five of the twelve cities the picker offered were not places Facebook recognises, and a rejected place silently serves the IP-inferred city instead of failing. Fixed for those five; the general fix is **Location and radius** below (`docs/location-targeting.md`) |
| **"Feed should be recency based (recently listed)"** | **Feed quality**, first item. Unblocked — the desktop payload dates every card with an exact `creation_time`, so this sorts in Swift without opening a listing |
| **"Custom items that are ordered"** | **Feed quality**, the business/drop-shipper filter. Read as made-to-order listings — a seller advertising a thing they'll build rather than a thing they have. *Check this reading:* it is the one item here I inferred rather than confirmed |
| **"Agent, I want a new table and find the best ones on marketplace"** | **Agent shopping**. Almost exactly the framing already written there ("a desk under $100 within 5 miles, no particleboard"), which is a good sign for the shape of that feature |
| **"Filter out drop shipping"** | **Feed quality**, same bullet as above. Partly solved already: the app defaults to local pickup, and desktop marks shipping per card via `delivery_types` |

The pattern worth noting: nothing here is a request for a feature nobody had
considered. It is a request for the *local browsing* promise to actually hold —
right place, fresh listings, real people selling real objects. That is one
theme, not five items.

## To do

Unchecked means not started. Notes are what we already know that bears on the
item — several of these are harder or easier than they look. Items marked
**(Matt)** came from the feedback above rather than from us.

**Location and radius**

- [ ] **Cache city → place id, for a fast path.** Confirmed 2026-08-07: a
      coordinate resolves to a **city**, not a neighbourhood. Inner Sunset,
      Mission and SoMa all return `/marketplace/sanfrancisco`; Midtown East and
      Williamsburg both return `/marketplace/nyc`. Radius doesn't carry the
      neighbourhood either — every result came back at 5 mi regardless. So the
      ~10 s picker round-trip buys nothing a lookup couldn't, *for cities we
      already know*.
      Two caveats that shape the table. The grain is "incorporated city", not
      "metro": Berkeley, Daly City and Palo Alto each resolved to their own
      place rather than folding into San Francisco or Oakland. And each of those
      came back as a **numeric place id, not a slug** — the same three whose
      guessed slugs failed. So the table must store place ids, and the picker
      stays as the slow path that discovers ids for anything not in it.
      (`docs/location.md` §5.)
      **But a table is not a full substitute.** Facebook also keeps the exact
      coordinate in *session state* and centres results on it: from one
      unchanging URL, Inner Sunset and Bayview return 62% overlapping result
      sets, against a **zero** noise floor — the same point returns identical
      results even after a different point intervened. A slug reproduces the
      city; it cannot reproduce the centring.
- [ ] **Run the picker in the store the searches use.** Following from the
      above: `MarketplacePlaceResolver` uses `.unauthed`, a fresh
      non-persistent store per instance, while `DesktopFeedEngine` searches on
      `.authed`. So the session state holding the coordinate is thrown away as
      soon as the resolution ends, and the app keeps the city while discarding
      the precision it just spent ~10 s obtaining. Worth deciding rather than
      just doing: it would tie the coordinate to the signed-in session, where
      today the resolution is anonymous.
- [ ] **Name the neighbourhood, where it's honest to.** "Inner Sunset, San
      Francisco" is far more useful than "San Francisco", and Apple supplies it
      — `CLPlacemark.subLocality` came back populated for six of six cached
      listings, with names a local would use. The blocker is our input, not
      Apple: geocoding the four corners of one lattice cell returned **four
      different neighbourhoods** for one cell and three for another, so the
      centre's name is a guess dressed as a fact.
      The check that makes it safe is cheap — geocode the cell's corners and
      show a name only when they agree, cached by cell since listings share
      them. It declines exactly where it should: almost always in San
      Francisco, usually passing in suburbs where neighbourhoods are larger
      than the ~600 × 950 m cell. (`docs/location.md` §8.)
      Related: `CLGeocoder` is deprecated as of iOS 26 in favour of MapKit's
      reverse-geocoding request, and `DistanceResolver` and `LocationProvider`
      both still use it.
- [ ] **The drawn radius still needs work.** It is currently the half-diagonal
      of the measured lattice cell (~572 m in SF), which circumscribes the real
      uncertainty and so never understates — but the cell is only a *lower*
      bound on the fuzz, since Facebook may jitter a point before snapping it,
      and nothing observable from outside settles that. Whether the circle
      should be larger than the cell, and by how much, is unanswered. Two
      loose ends alongside it: the `.city` fallback circle is still an invented
      6 km (`CLPlacemark.region` would give a measured one), and the enriched
      distance is quoted to a tenth of a mile, which is finer than the grid it
      is derived from.
- [ ] **Resolve the user's own location to a place id. (Matt: "location doesn't
      work")** Changing city is *not* solved, which is what the picker's
      curated list was hiding: five of its
      twelve slugs were not places Facebook recognises, and a rejected slug
      silently serves the IP-inferred city instead of failing
      (`docs/location-targeting.md`, measured 2026-08-06). Numeric place ids
      always work, and every search payload already carries one per card at
      `location.reverse_geocode.city_page.id` — so the app can harvest ids as it
      browses and never guess a slug. Steps and fallbacks in §7 of that doc.
- [ ] **Validate the place on every search.** An unrecognised place rewrites the
      path to `/marketplace/category/search/`, and an ambiguous slug resolves
      somewhere else entirely (`richmond` → Richmond, *Virginia*). Both return a
      full, healthy-looking result set for the wrong city, so the path segment
      and the dominant returned city both have to be checked.
- [x] **Feed a coordinate to the picker's centring arrow — the answer to both
      location problems.** Shipped: `MarketplacePlaceResolver` +
      `LocationPickerSheet`. "Use my current location" resolved the device fix
      to `San Francisco [sanfrancisco]`; searching "Toronto" in Apple's
      completer (which disambiguates Toronto ON / NSW / OH, something a guessed
      slug never could) resolved to `Toronto [toronto]` and searches came back
      in CA$ from Toronto and Kawartha Lakes. The curated seven-city list and
      the slug whitelist are both gone, along with the reverse-geocode that
      used to overwrite a chosen city with a guessed slug. Detail below. `latitude`/`longitude` as *URL
      parameters* are ignored (San Diego pair against a San Francisco IP →
      San Francisco ×15), and Facebook never reaches for the browser's location
      on its own during load or search. But the "Change location" dialog has a
      control that does ask —
      `div[role="button"][aria-label="Marketplace geolocation picker"]`, present
      logged out too. Clicking it calls `getCurrentPosition` once, synchronously,
      and *waits*. Resolved with a synthetic Toronto fix from a San Francisco IP
      it set the field to "Toronto, Ontario", and Apply gave
      `/marketplace/toronto/?radius_in_km=65` with an all-Ontario result set in
      CA$ (`docs/location-targeting.md` §5a, measured 2026-08-06 — this corrects
      §5, which had concluded no such route existed).
      The coordinate is consumed and discarded; what persists is a **place**. So
      it's a resolver: hook `getCurrentPosition` in our own webview, feed the
      device's real fix to browse where the user is, or geocode a typed city to
      a coordinate and feed that to browse anywhere else. Facebook picks the
      slug, so it's valid by construction and the broken-slug problem above
      disappears. Unverified: that it behaves the same in `WKWebView`, and
      whether `radius_in_km` from this route is real or decorative.
- [ ] **Enforce radius client-side** — it's the only option left. Cards carry a
      city but no coordinate, so this is either geocoded city centroids at card
      level (cheap, coarse) or the listing's own coordinate once enriched
      (accurate, but only for listings already opened). Probably both: filter
      loosely on the card, precisely on the detail.
- [ ] Consider per-city fan-out to widen coverage, since radius can't narrow it:
      the same query against neighbouring slugs recentres the results and only
      partly overlaps. Coverage, not precision.
- [x] ~~Place ids for cities with no vanity slug (e.g. South San Francisco).~~
      Solved for free: every card in the desktop payload carries its city's
      place id at `location.reverse_geocode.city_page.id` (San Francisco =
      `114952118516947`), so a single search yields the ids of every city it
      returns. No slug-guessing needed.

**Feed quality**

- [ ] **Order the feed by most recently listed. (Matt)** No longer blocked: the desktop
      search payload dates **every card** with an exact `creation_time`, so this
      can be sorted in Swift without opening a single listing
      (`docs/embedded-payload.md`). The server-side `sortBy=creation_time_descend`
      also works but is a worse tool — it's desktop-only *and*, because `radius`
      is dead, it drags results 60–90 mi out. Sort locally instead.
- [ ] **Decide the surface trade-off**, which is now the gating decision for
      everything in this section: mobile gives depth (paginates indefinitely)
      and seller identity; desktop gives every filter plus listing ids. Options
      are a desktop-backed "filtered search" mode alongside the mobile feed, or
      client-side filtering of the mobile feed on the fields cards already
      carry (price, condition, city — but *not* date).
- [ ] **Filter out businesses, drop-shippers and custom-order listings.
      (Matt: "filter out drop shipping", "custom items that are ordered")**
      Shipping is now a structured per-card field on desktop: `delivery_types`
      containing `SHIPPING_ONSITE` marked 24 of 24 cards on a shipping-filtered
      page and none on a local one, and it distinguishes *ships only* from
      *ships or collect in person*. `created_with_seller_app` is a plausible
      business signal but came back `false` everywhere measured, so it's
      untested. Remaining signals for the harder cases: duplicate coordinates
      across many listings from one seller, seller rating count, repeated
      titles (`docs/data-model.md`).
- [ ] Decide drop vs. badge. "Local marketplace browser" and "ships from three
      states away" are different products.

**Mobile's WebSocket**

- [ ] **Read item ids off the feed WebSocket instead of tapping for them.**
      WebLite streams the feed over `wss://kaios-d.facebook.com`, and a single
      124 KB binary frame carries a canonical `/marketplace/item/<id>` route for
      every card — 26 ids for 26 cards, in DOM order, verified by tapping cards
      1 and 2 and landing at socket positions 1 and 2. That removes the ~1.9 s
      per-listing resolve tap and the prefetch budget built around it.
      `docs/embedded-payload.md` §5b.
- [ ] Scope ids per frame and reset on navigation. The accumulated list is
      contaminated by item pages, which push their own "Today's picks" routes —
      measured growth 26 → 42 → 55 across two taps. A global `ids[cardIndex]`
      lookup drifts, and drifting means opening a stranger's listing.
- [ ] Keep DOM extraction as the correctness path. This is a private binary
      protocol with session-scoped ids; it wants fixtures, a health metric and
      a silent fallback before anything depends on it.
- [ ] **Raise the photo cap.** `WebLiteScripts.swift:406` hard-caps at
      `photos.slice(0, 12)`; sampled item pages carry 18–23. Independent of the
      socket work and roughly a one-line change plus a look at what the detail
      view does with more.

**Embeddings**

- [ ] **Vectorise listing titles, and descriptions where we have them.** Four
      things want it, in rough order of value: semantic search ("mid-century
      wooden desk, no particleboard" against a keyword-only backend);
      **repost detection**, below; "more like this" off a saved or opened
      listing; and clustering near-identical titles from one seller, which is a
      better version of the "repeated titles" business signal already noted
      under Feed quality.
- [ ] **Reposts are the case that actually needs it.** Identity is the photo
      FBID from the thumbnail URL (`Listing.identity`), so a seller who relists
      the same item with a re-uploaded photo produces a listing the app has
      never seen before. Everything keyed on that id inherits the blind spot —
      dedupe, saves, and the "Only new listings" filter, which will happily
      show you the same sofa every week as long as the photo keeps changing
      (`docs/filter-parameters.md` §8). Title similarity plus a matching price
      and city is the obvious detector.
- [ ] **Mind the data asymmetry.** Titles are available for *every* card and
      untruncated — from the desktop payload for the first ~15 and from the
      card aria-label for the rest. Descriptions exist only on item pages, so a
      description-based index covers only listings the user has already opened:
      sparse, and biased toward what they were already interested in. Titles are
      short enough to be noisy, which is the real risk here; a title-only index
      needs a similarity threshold set against measured pairs, not a guessed one.
- [ ] On-device first. Apple's Natural Language framework ships sentence
      embeddings (`NLEmbedding.sentenceEmbedding(for:)`, and
      `NLContextualEmbedding` on iOS 17+) — **unverified in this repo**, neither
      the API nor its quality on short listing titles has been measured. Local
      keeps it consistent with the two standing constraints: no extra traffic
      against Facebook, and nothing about what the user browsed leaves the
      device (`ViewedListings`). Vectors belong beside the profiles in
      `ListingCache` — 1,000 profiles × 512 floats is ~2 MB — and in
      `docs/data-model.md` if this ever moves server-side.

**Agent shopping**

- [ ] **Describe what you want, get a set of options. (Matt: "I want a new table
      and find the best ones on marketplace")** Tell it "a desk under $100
      within 5 miles, no particleboard" and have it run the searches, open the
      candidates, and come back with a shortlist and reasons. Matt's phrasing
      arrived independently and almost identically, which is the closest thing
      to validation this section has.
- [ ] Ranking the candidates is the Embeddings item above: the constraint
      "no particleboard" has to be matched against listing text, and Facebook's
      own search won't do it.
- [ ] Needs the enrichment path to be cheap enough to open many listings —
      currently ~2s each and every open is traffic against Facebook, so this
      wants the backend and the shared cache before it's practical at scale.

**Selling**

- [ ] **The comparables are whatever keyword search returned, and nobody checks
      they're comparable.** A search for "ikea malm dresser white" came back with
      a 3-drawer Malm at CA$40, a 2-drawer bedside at CA$30 and an unrelated
      white dresser at CA$150, all folded into one median. The strip is on screen
      precisely so the user can see this, but the arithmetic can't. The
      Embeddings item above is the real fix — embed the seller's description and
      each comparable, and weight the median by similarity instead of counting
      every card equally.
- [x] ~~**Asking prices are the only prices Facebook gives us.**~~ Partly
      answered 2026-08-07, and not the way this item assumed.
      `availability=out of stock` does reach sold listings, so the Seller tab
      now shows a "Recently sold nearby" strip and feeds the sold band to the
      model. But the prices on a sold card are what it was *listed* at, so the
      gap between asking and paid is still invisible — the win is liquidity and
      speed, not a truer price. See **The Seller tab** above.
      What remains: a sold item's own **item page** hasn't been checked. If it
      renders, it may carry something a search card doesn't.
- [ ] **A price with no market behind it still gets shown.** With one or two
      comparables there is no quartile band, and the guide falls back to
      "around CA$X" off a sample of two. It says the count, which is the
      minimum, but a two-listing median is not a price guide and the screen
      should probably decline rather than round down to one.
- [ ] **Bring the writer back, once it can be relied on.** Removed because
      `availability` can't tell "Apple Intelligence is on" from "the model is
      installed" (see **The Seller tab**). Two things would change that: a real
      device to verify against, since the simulator never will, and a check that
      fails *before* the UI promises anything — the cheapest being a tiny
      throwaway generation at tab-appear, cached for the session.
      When it returns, the route not yet tried for the description is giving the
      model *more real material* rather than more licence — the seller's own
      photos via the vision model, or the enriched detail from a comparable the
      user points at. More input beats a looser prompt.

**Known defects**

- [x] **A marked-down card showed both prices as one number.** Fixed
      2026-08-09. Facebook renders the new price and the struck-through old one
      as *inline* spans in the same block, so `innerText` returns them joined —
      "$50$60", "$250$1,000", "$0$25" — and every route that tests a run with
      `hasPrefix("$")` accepted the whole thing as the price. Cards and detail
      screens drew "$50$60" in one bold string, no strikethrough, no was-price.
      `PriceRun.split` takes a run apart only when it is *nothing but* two
      amounts that ascend, so ranges ("$20 - $40"), single prices, "Free" and
      anything with a word in it are left alone rather than relabelled into a
      discount Facebook never showed. A multi-character symbol run
      ("CA$50CA$60") is not split — it stays whole, as before.
      Cached listings keep the old joined string until they're re-fetched;
      nothing migrates them.
- [ ] **A saved listing's thumbnail dies after ~4.5 days.** fbcdn URLs are
      signed and time-limited: `oh` is a signature and `oe` is a hex unix
      expiry. Measured across three cached listings on 2026-08-04, the window is
      **106.9–107.5 hours** from fetch — call it 4.5 days. Saved items are meant
      to persist indefinitely, so a saved card older than that will render its
      price, title and city from the local store with a dead image. Fix is to
      cache the image bytes for saved listings rather than the URL.
      **Partly mitigated:** `ImageLoader`'s `URLSession` has a 256 MB disk
      cache and fbcdn sends a long `max-age`, so bytes already fetched keep
      rendering after the URL that fetched them expires. An evicted entry is
      still a dead card, so this stays open.
      A dead one now says so, rather than sitting grey — `MissingPhoto`.
      **Not fixable by asking for a smaller image.** The `stp` resize directive
      is inside the `oh` signature: measured 2026-08-09, mutating it to
      `p280x280`/`s280x280`, removing it, or corrupting it all return 403 where
      the untouched URL returns 200. Size is chosen by whatever rendered the
      page, so the only lever is the capture surface's viewport (or a `srcset`,
      if the grid carries one — unverified).
- [x] **`AsyncImage` never retries, so cards lose their image under load.**
      Fixed 2026-08-09 by `ImageLoader` + `RemoteImage`, which replace
      `AsyncImage` at all five call sites. The trigger was contention — the grid
      asks for ~26 thumbnails at once (measured: avg 95 KB each, **2.4 MB in one
      burst**) while three `WKWebView`s render full pages; requests that lost
      reported `.failure` and nothing retried, and `LazyVStack` keeps the view
      alive so scrolling away and back didn't rebuild it either. Now: six
      concurrent requests at most, one in-flight request per URL however many
      views want it, a shared decode cache, and up to three attempts backing off
      *outside* the gate. 403/404 is treated as permanent and never retried,
      since an expired signature never recovers.
      **Unexercised in the verification run:** live browsing produced zero
      transient failures, so the retry-and-recover path is reviewed but has not
      been observed firing. The permanent path was forced end-to-end and
      behaves (one 403 per URL, no retry storm, `MissingPhoto` rendered).

---

## Docs

| File | What's in it |
|---|---|
| **`docs/parsing-conventions.md`** | **Rules every extractor follows.** An unknown value is logged, never silently dropped; absent ≠ empty; a value found near the right place is not the right value |
| `docs/probe-checklist.md` | How to measure this site without recording false negatives |
| `docs/data-model.md` | Proposed schema for storing listings across devices |
| `docs/status.md` | What's built and verified, and the open gaps |
| `docs/surface-strategy.md` | Mobile vs. web trade-off, options, and recommendation |
| `docs/mobile-location-radius-notes.md` | Why mobile's location and radius don't behave as the URL implies |
| `docs/filter-parameters.md` | Every sort/filter parameter, which surface honours it, and what's measured |
| `docs/embedded-payload.md` | The GraphQL response Facebook ships inside desktop pages, and why the API isnt worth calling |
| `docs/logged-in-findings.md` | What a signed-in session changes: seller identity yes, structured depth no — and §7, the *rendered* page differences that broke four things built logged out |
| `docs/discover.md` | The home screen feed — Facebook's own, scrolled, when signed in; the user's own searches when not. Why that split, how the paging works, its open issues, and what breaks if it ever holds older cards |
| `docs/onboarding.md` | The two things the app requires before it will show a home screen, why neither can be skipped, and how the gate is written |
| **`docs/location.md`** | **Everything about location, both surfaces — start here.** What Facebook accepts, why a refusal is silent, the coordinate route, the verification protocol, the fuzz lattice, and where distances are measured from |
| `docs/location-targeting.md` | The raw desktop session record: slugs vs place ids, and the §5a/§5b correction that found the coordinate route |
| `docs/feasibility-2026-07-31.md` | The original §9 feasibility answers and how the architecture got here |
