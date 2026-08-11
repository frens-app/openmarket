# Onboarding: the four things the app asks for

**Date:** 2026-08-07 (account step added 2026-08-09; interests unwired from
Discover and the flow rebuilt around phone login, both 2026-08-10)
**Code:** `apps/ios/Sources/UI/OnboardingView.swift`,
`apps/ios/Sources/UI/PhoneLoginView.swift`,
`apps/ios/Sources/Account/PushRegistrar.swift`,
`apps/ios/Sources/Store/PlaceChooser.swift`,
`apps/ios/Sources/UI/SignInView.swift`
**Related:** `phone-login.md`, `backend.md` §3, `discover.md` §0, §4.7 and §6,
`location.md`, `location-targeting.md`, `filter-parameters.md` §3,
`logged-in-findings.md`

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

## 2. The order, and why it is fixed

| Step | Required | Why here |
|---|---|---|
| Phone | **Yes** | The account is the app; there is no signed-out version of a product whose listings belong to accounts |
| Facebook | No | Measurably the better app (§5), but the reduced one genuinely works |
| Location | **Yes** | Distance is the organising idea and it is applied **on this device** — no Marketplace surface honours `radius` (`filter-parameters.md` §3). Without a place the app measures from a hardcoded city and presents it as the user's |
| Notifications | No | Price alerts (§6). iOS shows the system prompt once, ever |

`OnboardingView.current` is a cursor. Every step advances it by being completed,
and nothing else moves it:

```swift
@State private var current: Step = .phone
private func advance() { current = current.next }
```

**It used to be derived, and that is what kept breaking.** The old version asked
which step was still outstanding — reading the session, two stored "asked" flags
and the resolved place, recomputed on every change — so any answer that arrived
early moved the flow:

- a place resolving in the background dismissed the rest of the run, so
  Continue was never pressed and the notifications step was never seen;
- a second account on the same install inherited the first one's flags and
  opened on the last screen, browsing the first one's city;
- a returning account's server-side `onboardingCompleted` dismissed the flow
  mid-step.

Each was a real bug, each was fixed by pinning one more input down, and the
third one settled the argument: a flow whose position is computed from state has
as many ways to jump as it has inputs. `hasAskedFacebook`, `hasChosenLocation`
and `hasAskedNotifications` were deleted with it — nothing else ever read them.

**The one thing still read is whether a session exists, and it is read once.**
You cannot ask somebody for their phone number when they already have one
verified, so a run that opened because the *place* went missing starts at step 2.
That happens in `onAppear`, not in `current`, so signing in later in the same run
cannot retroactively move anything.

**The one backwards move is explicit.** If `chooser.settle()` finishes with no
place, `finish` sets `current = .location` rather than letting the user through
to a home screen with nowhere to search — the step it returns to is already
showing the error.

**What this costs is resumability.** Quitting halfway now restarts the four
screens instead of resuming on the outstanding one. Two of them are a single tap
to pass, and a flow that always does the same thing is worth more than one that
saves a returning user two taps.

## 3. The gate

`Preferences.needsOnboarding` is what `RootView` reads:

```swift
!hasCompletedOnboarding || resolvedPlace == nil
```

**The place is re-checked, not latched.** It is the one answer the app cannot
work without, so an install that somehow ends up without one is asked again
rather than landing on a home screen with nowhere to search. `finish` settles
the pending resolution before letting go and sends the cursor back to the
location step if it never landed — where the error is already on screen.

**The skippable steps are deliberately absent from this expression.** Including
them would make "no" read as unfinished business and put the whole flow back on
screen at every launch.

**The server is the authority on whether the account was ever onboarded.**
`RootView` copies `viewer.onboardingCompleted` into `hasCompletedOnboarding` on
sign-in, so a reinstall or a second device doesn't repeat the account-shaped
part. The install-shaped parts — a place, a cookie jar, a notification
permission — are asked again, because a new install genuinely has none of them.

**That copy goes both ways, and used to only go one.** Writing the flag only
when the server said `true` meant it belonged to whichever account set it last
rather than to the account signing in, so a *new* user on an install that had
already onboarded inherited a `true` nobody had earned. `PhoneLoginView`'s
`isNewUser` used to set the same flag and no longer does — two writers of one
flag, and the near-synonym was the wrong fact anyway, since an account created
and abandoned halfway is a returning user who has never finished.

**Whether the flow is on screen is a latch, not a derivation.** `RootView` used
to recompute `!account.isSignedIn || prefs.needsOnboarding` on every change, and
that is a screen that can dismiss itself out from under the person using it.
Every step here answers its question somewhere other than this view, and two of
those answers arrive *early*: a session lands the moment the code is accepted,
and the location step resolves a place in the background while the user is still
looking at the map. Either one could drop `needsOnboarding` to false mid-flight
and cut straight to the home screen — the reported symptom was tapping "Use my
current location" and never seeing Continue, let alone the notifications step.

So `RootView.openIfNeeded` can only *open* the flow; only `finish` closes it.
The first decision after `restore()` settles it either way, a sign-out reopens
it at the phone step, and after that nothing outside `OnboardingView` can take
the screen away. This is what keeps the two derivations from fighting: `RootView`
asks whether anything is outstanding, `OnboardingView` asks which step is next,
and letting both decide when to *dismiss* means whichever goes false first wins,
at whatever moment it happens to change.

**A change of account clears the install-shaped answers**
(`Preferences.resetOnboarding`). They belong to whoever is holding the phone, not
to the device: sign out and sign in as somebody else and the flow used to open on
notifications, because "Facebook was offered" and "a place was chosen" were both
still true from the last person — who was also the person whose city the new one
would have been browsing.

`Preferences.lastAccountID` is what makes that detectable. Nothing else in the
app can tell "signed back in" from "somebody else signed in", and the difference
decides the behaviour: signing back into the **same** account deliberately keeps
everything, because that is routine and making that person pick their city again
would be a punishment for signing out. Deleting an account resets on its own
account, since there may not be a next sign-in to notice.

**Debug builds carry a "Restart onboarding" button** under Settings → Build.
Four screens that an install sees exactly once are otherwise checked by deleting
the app or deleting the account. It signs out as part of the reset, because the
phone screen is the first step — clearing the flags alone reopens the flow on
Facebook.

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
