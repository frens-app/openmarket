# App Store listing — copy, ready to paste

**Date:** 2026-08-13
**Language source:** `docs/messaging.md` — the three pillars (filters that
work, actually local listings, price comparisons), the observation-then-
improvement pattern for anything about Marketplace, and the taglines.

A caution that shapes everything here: App Store review looks harder at apps
that market themselves as wrappers of another service
(`docs/website-strategy.md` §1). So this copy describes Openmarket as what it
is — an independent local-listings browser with its own tools. By explicit
decision (Brian, 2026-08-13) the description carries no "how it works"
disclosure and no Meta trademark line — Facebook appears nowhere in the
listing except the keyword field. The website keeps the disclaimer; the
app's own screens tell a reviewer the rest.

## Name — 30 character limit

> Openmarket: Local Listings

(27 characters. The brand plus the category keyword; "marketplace" itself is
likely to be rejected as another company's product name in an app title, and
"listings" carries the search intent without the risk.)

## Subtitle — 30 character limit

> A better way to marketplace

(27 characters.)

## Promotional text — 170 character limit, editable without review

> Filters that work. Actually local listings, with travel time on every
> card. And price comparisons that tell sellers what things really sell for
> nearby.

(151 characters. This field can be swapped anytime — use it for launch notes
or seasonal angles later.)

## Description — 4000 character limit

> Openmarket is a better way to find local listings on marketplace!
>
> FILTERS THAT WORK
> Pick a place and a radius, and results respect it. Local marketplaces
> frequently show listings that are in different cities; Openmarket filters
> them down to the ones you can actually reach. Sort by newest, nearest, or
> price. And flip on "Only new listings" to hide everything you've already
> opened — check back twice a day and only ever read what's new.
>
> ACTUALLY LOCAL LISTINGS
> Every card shows its city and real distance from you. Open a listing and
> see walking, driving, and transit time from where you are — so "is it
> worth the trip" has an answer before you message anyone.
>
> PRICE COMPARISONS
> Selling something? Describe it — or just snap a photo — and Price Check
> compares similar listings near you, including ones that recently sold, and
> recommends the asking price your local market supports. It shows its work,
> and it writes a title and description you can paste straight into your
> listing.
>
> AND THE REST
> • Save from any listing and keep a shortlist of everything you're
>   deciding between
> • Recently viewed brings back "that desk from yesterday" in one tap
>
(~1,300 characters — room to grow. The pillars are ALL-CAPS section headers
because the App Store renders no markdown.)

## Keywords — 100 character limit, comma-separated, no spaces

> facebook,marketplace,offerup,letgo,vinted,depop,local,listings,buy,sell,used,secondhand,deals

(93 characters. Competitor brand names lead — Brian's call, 2026-08-13: they
are a known rejection risk under guideline 2.3.7 (metadata mentioning other
apps), and we ship them anyway and deal with a rejection if it comes. If a
reviewer flags it, the cheap fallback is resubmitting with this generic set:
`local,listings,buy,sell,secondhand,used,furniture,deals,thrift,flea,price,resale,nearby`.
Don't repeat words already in the name or subtitle — they're indexed for
free.)

## The rest of the sheet

- **Category:** Shopping (primary). Lifestyle (secondary).
- **Price:** Free, no in-app purchases at launch.
- **Age rating:** the questionnaire yields 4+ (user-generated content is
  browsed, not hosted — answer the UGC questions as a browser, not a host).
- **Support URL:** https://openmarket.io · **Marketing URL:**
  https://openmarket.io · **Privacy policy:** https://openmarket.io/privacy
- **What's New (1.0):** "Filters that work, actually local listings, and
  price comparisons for sellers. This is 1.0 — tell us what to build next at
  support@frens.lol."
- **Screenshots:** reuse the site's staged set (`apps/web/public/screens/`),
  but see `docs/website-strategy.md` §5 first — the real-third-party-listings
  decision applies doubly here. Caption each shot with a pillar phrase.

## Review-risk notes

- The description intentionally omits any Facebook disclosure (decision
  above). Reviewers run the app and will see the Facebook relationship
  themselves; if review asks, answer in the Review Notes field rather than
  the public description.
- Guideline 4.2.2 (minimum functionality) and 5.2.2 (third-party content)
  are the ones a reviewer would reach for. The defense is the original work:
  Price Check, travel times, the only-new filter, on-device saves — which is
  exactly why the copy leads with them.
- If rejected under 5.2.2, the response path is: independent browser, user's
  own session, no scraping into our servers, listings viewed not
  redistributed — and the messaging above already matches that story.
- The keyword field carries competitor brand names by explicit decision (see
  Keywords above). If rejected under 2.3.7, swap in the generic fallback set
  and resubmit — keywords-only changes don't need a new binary.

## Rejection: 5.1.1(v), and the build that answers it

**Date:** 2026-09-01. Review rejected the submitted build under guideline
5.1.1(v) — *"the app still requires users to register before browsing
products. Registration can only be required for account-based features."*

The finding was correct. `RootView` opened onboarding on `state == .signedOut`,
which put phone verification in front of an app that did not need it: only
`PricingService` — Price Check — ever called our authenticated API. Search,
Discover, filters, distance, travel time, saves, viewing history and the
buyer-side "is this a good price?" all run on the device against the user's own
Facebook session.

The current onboarding flow (`onboarding.md`):

- Optionally verify a phone number, or tap "Not now — browse without an account".
- Choose a supported city, using device location or manual city/ZIP search.
- Optionally connect Facebook. The primary button is "Connect Facebook" and
  the visible secondary action is "Browse without Facebook". Closing Facebook
  login returns to that choice.
- Verified accounts may enable notifications or tap "Not now". Guests skip
  notification setup. Enter Browse; being signed out does not reopen onboarding.
- Seller Price Check asks for phone verification and a Facebook connection at
  submission. It stores checks against the Openmarket account. The gate is
  dismissible and retains the draft. Phone verification comes first, followed by
  Facebook login; existing sessions skip their step. No notification prompt
  appears in this flow.

**Release validation:** test the exact submitted build with empty Facebook
cookies, no Openmarket credentials, and no cached listings. Verify manual city
selection, skipping Facebook, real listing results, details, search, filters,
and local saves. Confirm that a guest relaunch does not reopen onboarding.
Facebook can restrict anonymous results; a skip button alone is not proof that
guest browsing works. Match the rejected version/build to its source revision
before assuming this flow was present in the rejected submission.

**For the Review Notes field, after the release validation passes:**

> Openmarket can be used without registration. Tap "Not now — browse without
> an account" on the phone screen, choose a city, then tap "Browse without
> Facebook" on the optional connection screen.
> You can browse, search, filter, open listings, and save them without phone
> verification or a Facebook login. Seller Price Check (Tools tab) requests an
> Openmarket account at the point of use and stores checks in that account's
> history; it also uses a connected Facebook session for comparable searches.
> Its sign-in screen can be dismissed to return to browsing.
