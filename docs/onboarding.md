# Onboarding: the three things the app asks for

**Date:** 2026-08-07 (account step added 2026-08-09)
**Code:** `apps/ios/Sources/UI/OnboardingView.swift`,
`apps/ios/Sources/UI/InterestPicker.swift`,
`apps/ios/Sources/Support/Interest.swift`,
`apps/ios/Sources/Store/PlaceChooser.swift`,
`apps/ios/Sources/UI/SignInView.swift`
**Related:** `discover.md` §1 and §6, `location.md`, `location-targeting.md`,
`filter-parameters.md` §3, `logged-in-findings.md`

Four screens — what this is, where you're shopping, what you shop for, and your
Facebook account. The middle two are required; the account is asked for
first-class and can be passed.

---

## 1. Why it stopped being a greeting

The first run was three swipeable cards: local listings, no login ever,
messaging opens Facebook. All true, all worth saying, and completely inert. The
app came out of them knowing nothing about the person using it, so the first
real screen was Discover seeded with a shuffled default category list, searched
against `sanfrancisco` — the slug every query falls back to when nothing is set.

That is a home screen that works for exactly one user: someone in San Francisco
who wants furniture.

The two facts it was missing are both cheap to ask for and impossible to infer:

| Asked | Why it can't be skipped |
|---|---|
| A place | Distance is the app's organising idea and it is applied **on this device** — no Marketplace surface honours `radius` (`filter-parameters.md` §3). Without a place there is nothing to measure from, and the app silently measures from a hardcoded city instead |
| Three interests | Discover is built from recent searches, and a new install has none (`discover.md` §1). Interests are what stands in until searches exist |

One of those cards has since been retired outright rather than reworded. "No
login ever" was accurate about this app's own login form and badly wrong as a
pitch: it sold the signed-out build as the product when the signed-out build is
the fallback (§5). A first run that talks a user out of the account is a first
run arguing against the better version of the app.

**No skip link on either.** A skip buys thirty seconds and costs the app any
idea of what to show — and the screen it skips to is the one that then can't do
its job, which is the failure that started all this. The explaining moved into
the first screen, where three sentences cost one tap instead of three.

## 2. The gate

`Preferences.needsOnboarding` is the whole mechanism:

```swift
!hasCompletedOnboarding
    || resolvedPlace == nil
    || Interest.resolve(interests).count < Interest.minimum
```

Three things worth noting about that expression.

**It is re-checked, not latched.** An install that ends up without a place, or
with its interests emptied, is asked again rather than landing on a home screen
with nothing behind it.

**The stored flag is still needed.** Without `!hasCompletedOnboarding`, the
derived condition goes false the instant the third interest is tapped and the
cover would tear itself away before the user could press Continue. The flag
keeps the flow on screen while it's being filled in; the other two clauses are
the enforcement afterwards.

**It reads a new key.** `hasSeenFirstRun` is deliberately not consulted:
an install that has "seen" the old cards has still never chosen a place or an
interest, so reading it would let exactly the installs that need this through.
Existing users are asked once, like everyone else.

The consequence Settings has to respect: deselecting below three would satisfy
`needsOnboarding` and throw the full-screen flow back over the app while
somebody is editing a list. So `InterestPicker(enforcesMinimum: true)` blocks
the last three from being removed there. Onboarding itself doesn't enforce it —
the button is the thing that says "not yet", and free deselection is how anyone
corrects a mis-tap.

## 3. The place step

Both routes end in the same three steps — get a coordinate, hand it to
Facebook's own picker, store what Facebook calls the result — which now live in
`PlaceChooser` rather than being written twice. Apple answers "where is that",
Facebook answers "what do you call it", and the slug is valid because Facebook
produced it (`location-targeting.md` §2).

- **Use my current location** is the primary action: one tap, exact, and the map
  above it is already showing what "here" would mean.
- **Search for a city or ZIP** is a full alternative, not a fallback. Plenty of
  people want to browse somewhere they aren't.

The sheet behind the second button is deliberately not `LocationPickerSheet`.
That screen is the settings version of the same choice and also carries the
distance ladder and a "Browsing" summary — answers to questions nobody has on
their first run.

**The risk this creates:** the step cannot be completed while Facebook's picker
is unreachable, and there is no local fallback by design — the app never invents
a slug, because five of the twelve it once guessed were not places Facebook
recognises and a rejected slug doesn't fail, it silently serves the IP-inferred
city. A `.paced` failure is transient and says so; the rest are reported by name
so a report is useful. If the picker is genuinely down, the app is equally stuck
in Settings, so this doesn't add a failure mode so much as move it earlier.

## 4. The interests step

Eighteen categories, sized in three tiers by `Interest.prominence`. The sizing
is the only reason they fit on one screen without becoming a list: the broad
five carry the layout and the specific ones sit in the gaps. It is an editorial
judgement about how many people shop for a category, not a measurement, and
ranking one wrong costs a few points of type size.

**Three minimum**, matching `DiscoverFeed.searchCount` — the feed runs one
search per seed, so three is exactly what fills it without repeating a category.
The count lives in the button ("Pick 2 more" → "Start browsing") rather than in
a separate counter, so the disabled state explains itself instead of refusing.

**Stored as ids**, in the order they were tapped. Not labels and not search
terms: both are presentation decisions that should stay changeable, and Discover
reads the order as a ranking when it takes a subset.

What each interest actually searches for is the searchable half of its category
— `home decor` for "Home & garden", `jewelry` for "Jewellery" — because
Marketplace search is a fuzzy match over listing text rather than a category
filter. Those terms are unmeasured guesses, tracked as `discover.md` §4.8.

## 5. The account step

The last screen asks for a Facebook sign-in, and it is the only step that can be
passed. It is also the only step whose value is measured rather than argued:
`logged-in-findings.md` is what the three lines on it are drawn from.

| Named on the screen | What it rests on |
|---|---|
| Seller name, rating, and join date | Desktop item pages carry no seller fields logged out; signed in they carry the seller block *and* a `/marketplace/profile/<id>` link — a stable seller id no surface gives logged out |
| Results that keep going | Desktop browse caps at ~24 logged out and is unbounded signed in; the login overlay's one free dismissal is what ends a signed-out search |
| Discover from Facebook's own picks | Signed in, Discover scrolls Marketplace's real feed; signed out it stands in with three interest searches (`discover.md`) |

**Why it isn't a gate.** The other two steps are gates because the screen behind
them cannot function without an answer. This one can: search, distance, filters,
saved listings and an interest-seeded Discover all work signed out. Gating on an
account would be a lie about the app's own capability.

**Why it isn't buried either.** "Not now" is a text button under a full-width
primary, with one caption saying what the signed-out app still does. The earlier
flow inverted this — it promised no login at all — which meant every user
started in the reduced build and only discovered the full one by hitting a
missing seller name or a search that stopped.

**One wiring detail.** Signing in here calls `store.setSession` directly. The
usual notice-a-session path is the `scenePhase == .active` re-check in
`OpenMarketApp`, and an app that has been foregrounded since launch never fires
it — so without this, the first search after onboarding would run under the
anonymous cache key.

## 6. What onboarding changed elsewhere

- **Discover doesn't load while the cover is up.** `ResultsView` exists behind
  it from launch, so without the guard the feed would spend three page loads on
  a fallback city and a default category list — and mark itself filled, so the
  answers being typed in wouldn't reach it until the next launch. It fills on
  the transition out instead.
- **Editing interests refills Discover** when the Settings sheet closes
  (`DiscoverFeed.markStale`).
- **The search field's "Try" list is the user's interests**, not a fixed five.
  Same list Discover seeds from, which is the point.
- **`Preferences.suggestedCategories` is gone.** `Interest.defaults` — the broad
  row of the catalogue — is the one place categories are named now.
