# Location: everything we know

The canonical reference for how location works on Facebook Marketplace across
both surfaces, and how this app handles it. Everything here was measured
against the live site — mostly logged out, mostly from a San Francisco IP, in a
real `WKWebView` unless noted.

The two older documents are the raw session records and stay as they are:
`location-targeting.md` (desktop, and the correction in §5a/§5b) and
`mobile-location-radius-notes.md` (WebLite). Where they disagree with this
file, this file is newer.

---

## 1. The one-paragraph version

Facebook targets **places** in the URL and **coordinates** underneath it, and
the two are not the same resolution. It will not accept a latitude and
longitude as a URL parameter, and it never asks the browser where it is on its
own — but its location picker has a "use my current location" button that
*does* ask, and it accepts any answer. What comes back in the URL is a city:
every Manhattan neighbourhood reduces to `/marketplace/nyc`. What is *not* in
the URL is the exact point, which Facebook keeps in session state and uses to
rank results — and **logged out, keeps only until the browser closes** (§5), so
there the path is the only durable carrier of location. Radius is decorative
everywhere; distance is ours to enforce.

> ### The thing most likely to be got wrong
>
> **A slug is not a substitute for the coordinate.** It is tempting to read
> "every neighbourhood collapses to the city" as "so a city lookup is
> equivalent, and cheaper". It isn't. The place is city-level, but results are
> ranked by the exact point, invisibly — two ends of Manhattan share **36%** of
> their results from a byte-identical URL, against a noise floor of **zero**
> (§5). And logged out the result set is capped at ~15, so a re-rank is not a
> reordering of what you can see, it is a change to what you can see at all.
>
> Where a city lookup *is* enough: browsing somewhere you aren't. "Show me
> Toronto" has no particular point behind it, so a place id and the centroid
> lose nothing. Where it isn't: "where I actually am", which is the whole
> reason the picker is worth ten seconds.

---

## 2. What each input does

Measured on desktop; mobile agrees everywhere both were tested.

| input | accepted? | notes |
|---|---|---|
| `/marketplace/<slug>/` | **yes, if the slug is real** | see §3 for what "if" costs |
| `/marketplace/<place id>/` | **always** | numeric, ≥8 digits |
| `latitude=`/`longitude=` params | **no** | silently ignored — a San Diego pair against an SF IP returned San Francisco ×15 |
| ZIP as a path segment | **no** | `94110`, `94103`, `m5v` all rejected |
| `navigator.geolocation`, unprompted | **never called** | 0 calls across load and search, both surfaces, recorder proved live |
| coordinate via the picker's arrow | **yes, and it is kept** | §5 — the useful one. The URL reduces to a city, but the point itself is retained in session state and ranks results |
| `radius` / `radius_in_km` | **decorative** | §7 |

### Place ids

Always work, keep their path, and genuinely recentre. Every search payload
carries one per card at `location.reverse_geocode.city_page.id`, so they can be
harvested from ordinary browsing. Toronto is `110941395597405`.

We no longer need them — §5 gives a general resolver — but they remain the
most durable identifier if a slug ever stops working.

---

## 3. The silent refusal — the failure mode that matters

**An unrecognised place does not produce an error.** Facebook rewrites the path
to `/marketplace/category/search/` and serves the **IP-inferred city** with a
full, healthy-looking result set. Nothing about the response says "wrong city".

This is the single most important fact in this document. It means:

* You cannot tell success from failure by "did it load" or "were there
  results". Both are yes in the failure case.
* Any code that sets a location **must verify it afterwards** (§6).
* Guessing slugs is not a cheap approximation, it's a silent-wrong-answer
  generator.

Ambiguity fails the same quiet way: `richmond` resolves to Richmond,
**Virginia**.

### How bad was guessing?

Naive slugification — lowercase, strip spaces and dots — was wrong for **five
of the twelve** cities this app once shipped:

| worked | refused |
|---|---|
| sanfrancisco, oakland, sanjose, la, nyc, seattle, chicago | berkeley, dalycity, paloalto, fremont, marin |

International slugs work where they exist: `toronto`, `vancouver`, `london`.

The app no longer guesses. Every slug it holds was returned by Facebook.

---

## 4. The two surfaces

Keyed entirely off User-Agent (`docs/surface-strategy.md`).

| | desktop | mobile (WebLite) |
|---|---|---|
| location pill | yes, with radius | no |
| location picker dialog | yes | no |
| coordinate per listing | item pages only, embedded JSON | item pages only, inside a static-map URL |
| `latitude`/`longitude` params | ignored | ignored |
| `navigator.geolocation` | not called | not called |

Desktop is the app's primary surface, and it is the only one with a picker — so
§5 is desktop-only. That is not a limitation in practice: the resolved place is
a plain path segment that works on both.

---

## 5. Feeding a coordinate to the picker

The route that makes arbitrary targeting possible.

### 5.0 Getting the dialog open — three bugs, all invisible logged out

**Added 2026-08-09.** Everything below assumes the "Change location" dialog is
open. Opening it broke completely the first time a signed-in account used the
app, in three independent ways, and all three were latent for months because
the logged-out page happened to tolerate them.

> This is the location-specific half. The general pattern — what the signed-in
> page renders differently, and which other selectors in the app carry the same
> untested exposure — is in `logged-in-findings.md` §7. Read that before
> trusting any selector in this file against a session.

**Verified in both auth states**, on 2026-08-09, after the three fixes. Signed
in, on a real session; logged out, on a *fresh install in a second simulator*
with no cookie jar at all — which is the only way to test this honestly, since
signing out to check would destroy the session under test.

| | logged out | signed in |
|---|---|---|
| pill matched | `by label` — "Location: San Francisco, California" | `by label` — "Location: New York, New York, Within 5 mi" |
| pill rect | `344x27` | `344x27` |
| "Use my current location" | `[sanfrancisco]`, confirmed | `[sanfrancisco]`, confirmed |
| city from the list | Denver, CO → `[denver]`, confirmed | Portland, OR → `[portland]`, confirmed |
| round trip | ~15.5 s | ~8.5 s |

Two incidental findings from that run. The pill's label carries the radius only
when signed in — logged out it is the place alone — so **anything parsing that
label must tolerate both forms**. And the radius it reports is the *account's*
(5 mi) against Facebook's logged-out default (40 mi), which is the floor
described in `discover.md` §4.4 showing up in a second place.

The logged-out run also exercised the no-fix path by accident: a fresh simulator
has no simulated location, CoreLocation returned nothing, and the screen said
"Couldn't get a location fix. Try again, or search for a city instead." — the
correct answer, reached without touching Facebook, and worth recording as
observed rather than assumed.

**1. The pill was matched by its text.** The selector took the first
`div[role="button"]` whose text looked like `San Francisco · 40 mi`. Logged out
that matched exactly one element. Signed in, the logged-in chrome puts more
buttons on the page, the first match was **the notifications button**, and the
dialog we then searched for a centring arrow contained `Notification Actions |
Notifications filters | 3 days ago`.

Match the label instead:

```
div[role="button"][aria-label^="Location"]      // "Location: San Francisco, California"
```

Written for a screen reader, so it spells the place out in full regardless of
how the visible chip is abbreviated, and it carries no distance formatting to
disagree about. `role="button"` is load-bearing — the dialog's own search field
is an `input[role="combobox"]` whose label is also `Location`.
`DesktopScripts.extractLocationPill` had already reached this conclusion for the
same reason; `GeoPickerScripts` never got the benefit of it.

**2. The pill was clicked before it had a box.** "Present" was tested as
"exists in the DOM". Measured across consecutive runs, the same element reported
`344x27 @8,569` on one attempt and `0x0 @0,0` on the next — the element is
inserted before layout, and clicking it in that state does nothing. This is why
the failure was intermittent rather than constant. Wait for a non-zero
`getBoundingClientRect`.

**3. `element.click()` is not enough.** Facebook's pill opens on the pointer
sequence, so the click is now `pointerover → pointerenter → pointermove →
pointerdown → mousedown → pointerup → mouseup → click`, dispatched at the
element's own centre with `composed: true`, and aimed via `elementFromPoint` so
it lands on the descendant that actually carries the handler. Same family as the
WebLite tap problem in `feasibility-2026-07-31.md`: a synthesized event that
satisfies the DOM and not the framework.

Note the ordering trap in 2 and 3 together — with a zero box,
`elementFromPoint(0, 0)` returns whatever is in the top-left corner, so the
hit-test *introduces* a wrong-element click unless the layout wait is in place
first.

After all three: dialog at +4.1 s, arrow clicked immediately, applied at
+4.8 s, confirmed at +8.5 s.

**Diagnosis was slow because every failure reported the same thing.** "No
centring arrow" was returned when the dialog held notifications, when no dialog
existed at all, and when the arrow was genuinely missing. `openDialog` now logs
what it clicked and by which route, and the `.noArrow` path dumps every
`[role="dialog"]` with its visibility, plus whether any geolocation or `Apply`
control exists anywhere on the page. That last field is what settled it: `Apply`
was absent document-wide, so the dialog was not open in any form, which no
amount of staring at the arrow selector would have shown.

One red herring worth recording: a `[role="dialog"]` labelled `Notifications` is
mounted on the signed-in page permanently, `visible: false`. It is not open and
it is not a symptom. Check visibility before drawing conclusions from a dialog's
presence.

### 5.1 The centring arrow

In the "Change location" dialog, at the top-right of the map:

```
div[role="button"][aria-label="Marketplace geolocation picker"]
```

Present **logged out as well as logged in**. Clicking it calls
`navigator.geolocation.getCurrentPosition` once, synchronously, and *waits* —
left unresolved, it sits there as a spinner.

Facebook consumes the coordinate, reverse-geocodes it, and **discards it**.
What persists is a place. So this is a *resolver*, not a coordinate mode, and
that is exactly what makes it useful: Facebook picks the slug, so the slug is
valid by construction and §3 stops applying.

### In `WKWebView`

WKWebView's own Geolocation support has never been dependable, so the app
doesn't use it. `GeoPickerScripts.feeder` **replaces** `navigator.geolocation`
at `atDocumentStart` with an implementation that answers from
`window.__geoFeed`.

Two consequences worth stating plainly:

* The web view needs **no location permission of its own**.
* `__geoFeed` starts `null` and every call errors until the app sets it, so
  Facebook cannot obtain a position at a moment of its choosing — only the one
  the app hands over, at the moment it hands it over.

Measured end to end: fed London (51.5074, −0.1278) from a session sitting on
**Toronto** behind a **San Francisco** IP → `/marketplace/london`, pill
"London · 8 km", British listings. Neither leftover state nor IP could produce
that.

### How fine-grained is the answer? Two answers, and they differ. (2026-08-07)

**The URL is city-level. The ranking is not.** Read either half alone and you
will draw the wrong conclusion, so both are below: first what the URL does, then
what it hides.

#### The URL: neighbourhoods collapse to the city

Nine coordinates fed through the picker, each trial reset to London first so a
no-op couldn't be mistaken for a result:

| fed | path returned | pill |
|---|---|---|
| SF / Inner Sunset | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| SF / Mission | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| SF / SoMa | `/marketplace/sanfrancisco` | San Francisco · 5 mi |
| NYC / Midtown East | `/marketplace/nyc` | New York · 5 mi |
| NYC / Williamsburg | `/marketplace/nyc` | *(stale — see below)* |
| Oakland | `/marketplace/oakland` | Oakland · 5 mi |
| Berkeley | `/marketplace/113857331958379` | Berkeley · 5 mi |
| Daly City | `/marketplace/109415672417245` | Daly City · 5 mi |
| Palo Alto | `/marketplace/104022926303756` | Palo Alto · 5 mi |

Three separate San Francisco neighbourhoods collapse to one place, and both New
York neighbourhoods collapse to `nyc`. **Neighbourhoods do not survive.**

The radius doesn't carry them either: every result came back at 5 mi, whether
the coordinate was a neighbourhood or a city centre, so there is no sense in
which "Midtown East" persists as a tighter circle around New York.

**But the city set is much finer than "major metros",** and this is the part
that matters for any lookup table. Berkeley, Daly City and Palo Alto each
resolved to their *own* distinct place rather than folding into San Francisco
or Oakland — and each came back as a **numeric place id, not a slug**. Those
are exactly three of the five cities whose guessed slugs failed in §3. So:

* granularity is roughly "incorporated city", not "metro area"
* only a minority of cities have a slug; the rest are ids
* a table for the fast path must therefore store **place ids**, and the picker
  is still needed to discover ids for anything not in it

#### The ranking: the exact coordinate is kept, and used

The city-level URL is not the whole story, and this is the half that gets
missed. Facebook **retains the exact coordinate in session state** and ranks
results by proximity to it, even though nothing in the URL says so. Two
requests that are identical on the wire return substantially different result
sets depending only on the point fed to the picker beforehand.

Same URL every time — `/marketplace/sanfrancisco/search/?query=desk` — varying
only the coordinate fed to the picker beforehand:

| comparison | overlap |
|---|---|
| A vs A′ — same point, back to back | **100%** (7 of 7) |
| A vs A″ — same point, **after B intervened** | **100%** (7 of 7) |
| A vs B — different point, same URL | 62% |
| B vs A″ | 62% |

A is Inner Sunset, B is Bayview: ~8 km apart, opposite sides of the city.

The noise floor is **zero** — the same coordinate returns byte-identical result
sets — so the 62% is not ranking churn. And A″ matters more than A′: repeating
the first coordinate *after a different one had been applied* reproduced its
result set exactly, which rules out the back-to-back match being a cached
response. The only thing that varied is the coordinate, and the results vary
with it.

So there are two granularities, and they disagree:

* **the place** — city-level, in the URL, shareable, and what a lookup table
  could replace
* **the centring** — the exact point, held in session state, invisible in the
  URL, and *not* reproducible from a slug or a place id

#### Logged out, none of it survives the session (2026-08-09)

**The coordinate is kept for exactly as long as the browser is open.** Change
location logged out, close the browser, come back: you are on the IP-inferred
city again. Nothing above is wrong — the re-ranking was measured inside one
live session and holds there — but its *durability* is bounded, and the bound
is much tighter than "until the user changes it".

The consequence is the important part:

> **Logged out, the URL path is the only durable carrier of location.** The
> place segment survives because it is in the address. The point behind it
> does not survive anything.

So a resolution buys two different things depending on auth state:

| | what the ten seconds buy |
|---|---|
| logged out | the **segment**, and a ranking point good until the browser closes |
| signed in | the segment, and a point that sticks to the account |

For this app that has teeth, because the app is *made of* short-lived browsers.
Every engine is its own `WKWebView`, Discover runs one per seed search, and all
of them are rebuilt on the next launch. A shared cookie jar carries the
session; it does not carry this. So logged out, any request that does not name
the place in its own path is a request for the IP-inferred city — whatever was
resolved ten seconds earlier in a different webview.

Both path shapes were then confirmed logged out, from a San Francisco IP, in a
**cold browser with no session state at all** — no prior location change, no
`c_user`, one `wd` cookie, login links on the page. That is the strongest form
of the test: nothing but the path was carrying the location.

| URL | result |
|---|---|
| `/marketplace/toronto/?radius_in_km=8` | Toronto |
| `/marketplace/toronto/search/?query=desk` | 15 cards, every one `Toronto, ON`, prices in `CA$`; path not rewritten |

So the place segment does its job unaided on **both** the browse and the search
path, across a national border, with no session behind it. A logged-out request
that names the place gets that place.

Which sharpens what the loss actually is. Logged out you keep the *city* for
free and lose only the *centring* — §5's 62%-overlap re-ranking — because that
is the half that lived in session state. For "browse somewhere I'm not" that
costs nothing (§1 already said a centroid loses nothing there). For "where I
actually am" it costs the thing the ten seconds were for.

#### How much does it move, within one city? (New York, 2026-08-07)

Five coordinates across New York, same URL every time
(`/marketplace/nyc/search/?query=desk`), all returning the logged-out cap of
~15 cards:

| vs | overlap | apart |
|---|---|---|
| Downtown vs **Downtown again** (after all four others intervened) | **100%** (15/15) | 0 km |
| Downtown vs Brooklyn/Williamsburg | 93% | ~5 km |
| Downtown vs Midtown | 76% | ~5 km |
| Midtown vs Uptown/Harlem | 42% | ~7 km |
| Downtown vs Uptown/Harlem | **36%** | ~11 km |

The effect **scales with distance**, which is what makes it convincing:
identical at zero separation, mostly-shared at 5 km, barely-a-third-shared at
11 km. Random churn would not produce a gradient, and the 100% repeat rules out
drift over the run.

Two things worth noticing:

* **It is distance, not administrative geography.** Williamsburg is *in
  Brooklyn* but ~5 km from the Financial District, and it behaved like the
  other 5 km pair — 93% overlap with Downtown — not like a different borough.
* **The place never changes.** All five returned `/marketplace/nyc`, pill "New
  York · 5 mi", and the borough mix of the results barely moved (11–13 "New
  York, NY", 1–3 "Brooklyn, NY" throughout). This is re-ranking *within* the
  city's inventory, not a different catchment.

**The 1 mi question is unanswered.** Pulling the radius down would have made
this unmissable at these separations, but the picker's radius is not a native
`<select>` — it renders as a div reading "Radius 5 miles" — so the script
couldn't set it and every run above used Facebook's default 5 mi. Driving that
dropdown is the next probe, and it doubles as the first real test of whether
the picker's radius does anything at all (§7).

**This has a direct consequence for the app, currently unfixed.**
`MarketplacePlaceResolver` runs on the `.unauthed` store, which is a *fresh
non-persistent* store per instance, while `DesktopFeedEngine` searches on
`.authed`. The session state carrying the coordinate is therefore discarded the
moment the resolution finishes, and never reaches a search. The app gets the
city and drops the precision it just paid ten seconds for.

Fixing it means running the picker in the same store the searches use. That is
a design decision rather than a bug fix: it would associate the coordinate with
the signed-in session, where today the resolution is anonymous and touches
nothing.

One read is unreliable and is left in rather than quietly dropped: the
Williamsburg row's pill still said "London", the place the trial reset from.
The path had already changed to `/marketplace/nyc`, so the resolution worked
and the pill simply hadn't re-rendered when it was read. It is the same lag the
app's `confirm` step polls for (§6), showing up here because this probe reads
once on a fixed delay.

### The near-miss worth remembering

The first run of that probe fed *Toronto* into a session already showing
Toronto. It failed for an unrelated reason — the pill reads "Toronto · 8 km"
and the selector only matched `mi` — but had the click worked, a pass would
have been **indistinguishable from doing nothing**. Feed a place that is
neither the IP city nor the current state.

Units follow the *place*, not the viewer: a Canadian location renders `km`.

---

## 6. Verification: "applied" is not "worked"

Because of §3, setting a location and believing it are different acts.
`MarketplacePlaceResolver.confirm` runs after every resolution:

1. **Load the resulting URL from scratch.** Not the page still on screen — that
   one was mutated client-side by React and reports what the *picker* believes.
   What matters is what the server does with this URL on a cold request, which
   is the request every later search will make.
2. **Read the URL's place and the rendered pill together**, via
   `MarketplaceURLPlace` and `DesktopLocationPill`, so a disagreement between
   them is visible rather than averaged away.
3. **Poll for the pill** — it renders *after* the payload, up to ~2.5 s later.
   A single read reports "no pill" for a page that has one.
4. **Fail on refusal, and on a pill naming a different place.** A *missing*
   pill is not a failure (the page may not have drawn one); a pill naming
   somewhere else is.

Only a confirmed place is stored. The UI says so — "Confirmed on Facebook —
San Francisco · 40 mi" — because a place that resolved and then quietly served
somewhere else must never look identical to one that worked.

### What gets kept

`ResolvedPlace` holds the whole answer, not just the name:

| field | why |
|---|---|
| `name` | Facebook's own display name, for the UI |
| `segment` | the path component every later search uses |
| `latitude`/`longitude` | what was *asked for* — explains a surprising answer, and lets a stale resolution be repeated without asking the user again |
| `browseURL` | the URL Facebook landed on, verbatim, e.g. `/marketplace/toronto/?radius_in_km=65` — reused rather than re-derived, and the thing to re-check against |
| `verifiedPill` / `verifiedAt` | proof, and when |
| `origin` | `.deviceFix` (can go stale as the user moves) or `.searchedCity` (stays true until changed) |

The URL is stored verbatim deliberately: Facebook chose that form, and
rebuilding it from parts is a chance to get it subtly wrong.

---

## 7. Radius is decorative

The `radius` parameter is ignored on both surfaces, and WebLite's own
"Distance" chip is an opaque action with no href. The picker's own
`radius_in_km=65` has **not** been shown to do anything either — that is an
open question, not a claim.

So distance filtering is the app's job, client-side, and it is enforced against
the best coordinate available per listing (§8).

---

## 8. What Facebook publishes about a listing's location

Only ever a **city name** on feed cards. Item pages — and only item pages —
carry an approximate coordinate, identical across both surfaces, so it's the
listing's published point rather than anything client-derived.

### The fuzz is quantised, and the lattice is measurable

Facebook publishes no number for how approximate "approximate" is. Every range
on an item page ("Within 40 mi", "San Francisco · 40 mi") is the *viewer's own
search radius*. But the coordinates are snapped to a grid — recovered from 56
cached item pages, 46 distinct points:

| axis | step | on the ground at 37.8°N |
|---|---|---|
| latitude | `360/2^16` = 0.0054931640625° | 611 m |
| longitude | `360/2^15` = 0.010986328125° | 966 m |

Worst residual `4.6e-10°` — exact snapping, not rounding noise — and five
listings shared a single point. So a published point means "somewhere in this
cell", the cell is wider than it is tall, and the true location is at most
~572 m away (half-diagonal). `FacebookCoordinateGrid` holds the constants.

The lattice is a **lower bound**: Facebook may also jitter before snapping, and
nothing observable from outside can rule that out.

### Can we name the neighbourhood? Apple can; our coordinate can't. (2026-08-07)

`CLPlacemark.subLocality` returns real neighbourhood names, and it is populated
reliably — six of six cached San Francisco listings, each a name a local would
use, and adjacent lattice cells return genuinely different ones:

| listing point | subLocality |
|---|---|
| 37.729797, −122.492065 | Merced Manor |
| 37.735291, −122.492065 | Parkside |
| 37.735291, −122.393188 | Mendell Hill |
| 37.751770, −122.492065 | Central Sunset |
| 37.751770, −122.426147 | Upper Noe |
| 37.751770, −122.415161 | Mission District |

So the capability is there. The problem is upstream: **one lattice cell spans
several neighbourhoods.** Geocoding the four corners of a single cell —
the actual region a published point stands for — against its centre:

| cell centre | centre | NW | NE | SW | SE |
|---|---|---|---|---|---|
| 37.751770, −122.426147 | Upper Noe | Central Noe Valley | Mission District | Upper Noe | Juri Commons |
| 37.735291, −122.492065 | Parkside | Parkside | Parkside | Lakeshore | Merced Manor |

Four distinct neighbourhoods in the first cell, three in the second. The
centre's name is one sample among several equally likely ones, so "Upper Noe"
would be a guess dressed as a fact — the same overclaim the map's circle exists
to avoid.

**If it is ever built, the check is cheap and decisive:** geocode the cell's
corners and show a neighbourhood only when they all agree. Cache by cell rather
than by listing, since points are on a lattice and listings share cells. In San
Francisco that check would almost always decline; in suburbs, where
neighbourhoods are larger than ~600 × 950 m, it would usually pass. That is the
right split — the label appears exactly where it is true.

Note for whenever this is picked up: `CLGeocoder` is deprecated as of iOS 26 in
favour of MapKit's reverse-geocoding request. The app still uses it in
`DistanceResolver` and `LocationProvider`.

---

## 9. The user's own location, in the app

* One-shot `CLLocationManager` fix, when-in-use, `kCLLocationAccuracyHundredMeters`.
  Never continuous tracking.
* It goes to Facebook **exactly once**, as the coordinate fed to the picker, and
  what comes back is a place name. Searches after that carry the place, not the
  position.
* The reverse-geocode writes a **display name only**. It used to write
  `city.lowercased()` into the slug on every fix, which was §3's failure by
  another route *and* silently overwrote whichever city the user had chosen.
  `MarketplacePlaceResolver` is the only writer of a slug in the app.

### Where distances are measured from

Browsing somewhere you are not breaks the assumption that "the user" and "the
search" share a location. The rules:

| number | origin | why |
|---|---|---|
| card/detail distance, radius filter | the **saved** `ResolvedPlace.coordinate`, whichever kind it is | browsing elsewhere, a live fix makes every Toronto listing read "~2273 mi" and empties the radius filter; browsing *here*, it makes distances drift as the user walks, so cards slide in and out of the radius with no search having happened. Distances belong to the search that produced them. |
| travel time | a **fresh** device fix, taken when the listing is opened | it answers "how long would it take *me* to go and get this", which is a question about where they are standing now — the one place a stale position gives a confidently wrong answer |

Travel time is also gated twice: it draws only while the saved location came
from the device (`ResolvedPlace.isUserLocation`), and only for listings within
100 miles. Those catch different things — browsing a city you are not in, and
the individual listing 90 miles out of a search you ran from home.

Known wart: the Saved shelf shows listings saved elsewhere at their distance
from the *browsed* city, which reads oddly. Splitting the rule per surface
would fix it at the cost of two meanings for one number.

---

## 10. Where the code lives

| type | job |
|---|---|
| `GeoPickerScripts` | the document-start shim and the picker-driving JS |
| `MarketplacePlaceResolver` | coordinate → confirmed `ResolvedPlace`, in a throwaway unauthed webview |
| `ResolvedPlace` | the stored answer (§6) |
| `AppleMapsCitySearch` | `MKLocalSearchCompleter` → coordinate, for "browse another city" |
| `MarketplaceURLPlace` | what place, if any, is in a URL — and whether it was refused |
| `DesktopLocationPill` / `DesktopPageLocation` | the rendered pill, its radius, and whether it agrees with the URL |
| `FacebookCoordinateGrid` | the measured fuzz lattice (§8) |
| `LocationPickerSheet` | both user journeys |

Apple and Facebook each do the half they are good at: Apple knows *where* a
typed place is and can tell Toronto ON from NSW from OH; Facebook knows *what
it calls* the place containing that point.

### Two rules for anyone changing this

1. **Never substitute a slug for a coordinate on the user's own location.**
   Caching city → place id is a fine optimisation for "browse somewhere else",
   where no particular point was meant. It is a downgrade for "where I am",
   because the slug cannot carry the ranking (§5) and the user will silently
   get a different, worse set of results with nothing on screen to explain it.
2. **The coordinate only survives inside the session that set it.** It lives in
   session state, not the URL, so any webview that searches without having run
   the picker gets city-level ranking regardless of what `ResolvedPlace` says.
   See the open item in §11 — the app has this wrong today.

---

## 11. Open questions

* ~~The app throws the coordinate away.~~ **Fixed 2026-08-07.** The resolver
  used to run on a throwaway non-persistent store while searches ran on the
  persistent one, so the session state holding the point was discarded seconds
  after it was established. There is now a single store (`BrowserSession` is a
  cache label, not a sandbox), so the resolution and the searches share it.
  The trade was made knowingly: for a signed-in user the coordinate is now
  associated with their Facebook session rather than an anonymous one.
  **Not yet measured end to end** — the ranking effect was proven in the probe
  and the store change makes it reachable, but no A/B has been run through the
  app itself.
* Does the radius do anything? Unknown, and untested because the control is not
  a native `<select>` — it renders as a div reading "Radius 5 miles", so the
  probe couldn't set it and every run used the default 5 mi. A 1 mi radius
  would turn §5's re-ranking into outright filtering, which would be a much
  stronger claim than anything measured so far. (§7)
* ~~Does `/marketplace/<place>/search/` honour the place logged out at national
  distance?~~ **Answered 2026-08-09: yes**, from a cold browser with no session
  state (§5). Recorded because it was nearly the basis of a product decision —
  a logged-out Discover rebuilt on browse or category paths, or location
  switching gated behind a Facebook login. None of it was necessary; the URL
  already carries the place.
* Does any of §5 hold for a **signed-in** session? It was all measured logged
  out, where the ~15 result cap is what makes re-ranking decisive. Signed in
  the feed scrolls indefinitely, so distant listings stay reachable and the
  coordinate may matter considerably less.
* Should a `.deviceFix` place re-resolve when the user has moved a long way
  from where it was resolved? `ResolvedPlace.metres(from:)` exists for this and
  nothing calls it yet.
