# Onboarding: the four things the app asks for

**Date:** 2026-08-07 (account step added 2026-08-09; interests unwired from
Discover and the flow rebuilt around phone login, both 2026-08-10)
**Code:** `apps/ios/Sources/UI/OnboardingView.swift`,
`apps/ios/Sources/UI/PhoneLoginView.swift`,
`apps/ios/Sources/Account/PushRegistrar.swift`,
`apps/ios/Sources/Store/PlaceChooser.swift`,
`apps/ios/Sources/UI/SignInView.swift`
**Related:** `backend.md` §3, `discover.md` §0, §4.7 and §6, `location.md`,
`location-targeting.md`, `filter-parameters.md` §3, `logged-in-findings.md`

Four steps: **phone**, **Facebook**, **location**, **notifications**. The first
and third are required; the second and fourth are asked properly and can be
passed.

---

## 1. What changed, and why the shape moved

Two rewrites are worth recording, because the current flow is a reaction to
both.

**The first run used to be three swipeable cards** — local listings, no login
ever, messaging opens Facebook. All true, all inert. The app came out of them
knowing nothing about the person, so the first real screen was Discover seeded
with a shuffled default category list against `sanfrancisco`, the slug every
query falls back to. A home screen that works for exactly one user: someone in
San Francisco who wants furniture. One of those cards was retired outright
rather than reworded — "no login ever" was accurate about this app's own login
form and badly wrong as a pitch, since it sold the signed-out build as the
product when it is the fallback (§5).

**Then the account arrived and split the first run in two.** Phone login was a
gate *in front of* onboarding, so a new user met a login screen, verified a
code, and was then greeted by a welcome carousel that started over. Two
beginnings for one arrival.

Signing in is now the first step of one flow, and the welcome carousel is gone
with it. Each step carries its own reason at the moment its question is asked,
which is where an explanation is worth reading — rather than three screens of
argument before anything is asked at all.

**Interests were dropped, and the reason changed underneath them.** They were
always the weakest question — a required statement about taste, asked before the
person had seen a single listing, with a minimum of three that came from
`DiscoverFeed` running one search per interest. Then Discover stopped reading
them at all: it loads Facebook's own browse page for everyone now
(`discover.md` §0), which left the minimum enforcing an answer the home screen
never consults.

What interests still do is fill the search field's "Try" list. That is a real
thing, and nowhere near enough to stop a first run over. They moved to Settings,
where somebody who wants to aim those suggestions can, and nobody else has to;
`Interest.defaults` fills the row for everyone who doesn't.

## 2. The order, and why it is derived

| Step | Required | Why here |
|---|---|---|
| Phone | **Yes** | The account is the app; there is no signed-out version of a product whose listings belong to accounts |
| Facebook | No | Measurably the better app (§5), but the reduced one genuinely works |
| Location | **Yes** | Distance is the organising idea and it is applied **on this device** — no Marketplace surface honours `radius` (`filter-parameters.md` §3). Without a place the app measures from a hardcoded city and presents it as the user's |
| Notifications | No | Price alerts (§6). iOS shows the system prompt once, ever |

`OnboardingView.current` computes which step is outstanding rather than
advancing a cursor:

```swift
if !account.isSignedIn        { return .phone }
if !prefs.hasAskedFacebook    { return .facebook }
if !prefs.hasChosenLocation   { return .location }
return .notifications
```

A stored cursor would have to be kept in step with four independent sources of
truth — a session, a cookie jar, a resolved place, a system permission — every
one of which can change from outside this view. Deriving it also makes the flow
resumable for free: quit halfway and the next launch reopens on the step still
outstanding.

**The two skippable steps store "asked", not "answered".** A declined Facebook
connection and an unasked one look identical from outside, so the outcome cannot
drive the flow — and re-asking every launch is how an optional step becomes a
nag. The answers live where they belong: the cookie jar, and the system.

**`hasChosenLocation` is stored rather than derived from `resolvedPlace`, and
that is a bug fix.** The step is deliberately optimistic — Continue opens on the
*choice*, so Facebook's ten-second round trip to name the place runs while the
user reads the next screen. The first version expressed that as
`resolvedPlace == nil && chooser.switching == nil`, which meant the flow
advanced itself the instant the button was tapped: the location screen slid away
while the system's location alert was still on top of it. The optimistic
condition belongs to the *button*, not to the step.

## 3. The gate

`Preferences.needsOnboarding` is what `RootView` reads:

```swift
!hasCompletedOnboarding || resolvedPlace == nil
```

**The place is re-checked, not latched.** It is the one answer the app cannot
work without, so an install that somehow ends up without one is asked again
rather than landing on a home screen with nowhere to search. `finish` settles
the pending resolution before letting go and clears `hasChosenLocation` if it
never landed, so a failure returns to the step that asks — where the error is
already on screen.

**The skippable steps are deliberately absent from this expression.** Including
them would make "no" read as unfinished business and put the whole flow back on
screen at every launch.

**The server is the authority on whether the account was ever onboarded.**
`RootView` copies `viewer.onboardingCompleted` into `hasCompletedOnboarding` on
sign-in, so a reinstall or a second device doesn't repeat the account-shaped
part. The install-shaped parts — a place, a cookie jar, a notification
permission — are asked again, because a new install genuinely has none of them.

## 4. The location step

Both routes end in the same three steps — get a coordinate, hand it to
Facebook's own picker, store what Facebook calls the result — which live in
`PlaceChooser`. Apple answers "where is that", Facebook answers "what do you
call it", and the slug is valid because Facebook produced it
(`location-targeting.md` §2).

- **Use my current location** is the primary action: one tap, exact, and the map
  above it already shows what "here" would mean.
- **Search for a city or ZIP** is a full alternative, not a fallback. Plenty of
  people want to browse somewhere they aren't.

The sheet behind the second button is deliberately not `LocationPickerSheet`.
That is the settings version of the same choice and also carries the distance
ladder and a "Browsing" summary — answers to questions nobody has on a first run.

**The risk this creates:** the step cannot be completed while Facebook's picker
is unreachable, and there is no local fallback by design — the app never invents
a slug, because five of the twelve it once guessed were not places Facebook
recognises, and a rejected slug doesn't fail, it silently serves the IP-inferred
city. If the picker is genuinely down the app is equally stuck in Settings, so
this moves a failure mode earlier rather than adding one.

## 5. The Facebook step

Skippable, and the only step whose value is measured rather than argued:
`logged-in-findings.md` is what the three lines on it are drawn from.

| Named on the screen | What it rests on |
|---|---|
| Seller name, rating, and join date | Desktop item pages carry no seller fields logged out; signed in they carry the seller block *and* a `/marketplace/profile/<id>` link — a stable seller id no surface gives logged out |
| Results that keep going | Desktop browse caps at ~24 logged out and is unbounded signed in; the login overlay's one free dismissal is what ends a signed-out search |
| Personalized results | Discover is Facebook's own feed either way, but anonymous it is a rotating popularity pool with no user in it; signed in it is ranked against the account's own history (`discover.md` §0.0) |

**Why it isn't a gate.** Phone and location are gates because the screen behind
them cannot function without an answer. This one can: search, distance, filters,
saved listings and a one-page Discover all work without it. Gating on a Facebook
account would be a lie about the app's own capability.

**Why it isn't buried either.** "Not now" is a text button under a full-width
primary, and the three lines above them are the whole argument. A caption under
the decline used to list what still works without an account; it went because it
answered a question nobody has yet at the moment they are being asked to say
yes, which made the cheaper option look like the considered one. The earliest
flow inverted this more severely — it promised no login at all — so every user
started in the reduced build and discovered the full one by hitting a missing
seller name or a search that stopped.

**One wiring detail.** Signing in here calls `store.setSession` and
`account.reportFacebookConnection` directly. The usual notice-a-session path is
the `scenePhase == .active` re-check in `OpenMarketApp`, and an app foregrounded
since launch never fires it — so without this the first search would run under
the anonymous cache key and the server's picture of the connection would wait
for the next foreground.

## 6. The notifications step

Skippable, and asked for **price drops on saved listings** specifically.

The reason this is a screen of our own rather than the system prompt fired
straight at a cold audience is that **iOS shows that prompt exactly once**. A
"don't allow" is close to permanent, recoverable only through a trip to Settings
almost nobody makes, so an unexplained prompt spends the single ask on a reflex.
Naming the payoff first is what turns it into a decision.

Price alerts and not "news and updates", because that is the notification this
app can send well: it already tracks saved listings and already parses price runs
(`PriceRun`), so a drop is a fact it can notice without asking anyone anything.
The third line on the screen promises nothing else will be sent, which is a
promise the code should be held to.

**A refusal is still reported.** `AccountSession.registerPushToken(nil,
granted: false)` records it, because the server needs to tell an install that
said no from one that was never asked — that is what decides whether an alert has
any way to reach the person. The token is stored as NULL rather than `""`; the
unique index on the column would otherwise collide the second time any device
declined.

**APNs failure reports too.** Registration is asynchronous and can fail with the
permission granted — no network, or a simulator with no APNs connection. Staying
quiet would leave the server unable to distinguish that from a refusal, so
`PushRegistrar.didFailToRegister` reports the permission with no token and the
next launch fills the address in.

## 7. What onboarding changed elsewhere

- **Discover doesn't load while onboarding is up.** `ResultsView` exists behind
  it from launch, so without the guard the feed would spend three page loads on
  a fallback city — and mark itself filled, so the answers being typed in
  wouldn't reach it until the next launch. It fills on the transition out.
- **Editing interests refills Discover** when the Settings sheet closes
  (`DiscoverFeed.markStale`).
- **The search field's "Try" list is the user's interests**, falling back to
  `Interest.defaults` when none are set.
- **`InterestPicker` no longer enforces a minimum.** The minimum existed only to
  stop Settings from satisfying `needsOnboarding` and throwing the flow back over
  the app mid-edit. With interests out of that expression there is nothing to
  defend, and emptying the list falls back to `Interest.defaults`.
