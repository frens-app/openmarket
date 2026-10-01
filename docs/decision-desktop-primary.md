# Decision: desktop becomes the primary surface, behind a signed-in session

**Date:** 2026-08-05
**Status:** accepted, not yet implemented
**2026-09-30 addendum:** Search and Browse now use structured GraphQL pages
in both session states. Guests use cookie-free native HTTP; signed-in users use
same-origin requests inside their existing persistent WebView session. The
browser still supplies item detail and fallback for unsupported feed queries.
See [the direct-query investigation](anonymous-graphql-2026-09-30.md).
The session-isolation design below is historical; current `BrowserSession`
cases share one persistent store, while the anonymous HTTP client rejects cookies.
**Supersedes:** the "mobile feed, desktop resolve as fallback" arrangement in
`surface-strategy.md` §5 (option B)
**Evidence:** `filter-parameters.md`, `embedded-payload.md`,
`logged-in-findings.md`

---

## What changes

Search and item detail both move to the desktop surface, driven by a signed-in
session. The mobile WebLite stack is **kept and demoted**, not deleted.

## Why

Three measured facts, in order of weight:

1. **Filters and sorting exist only on desktop.** `sortBy`, `deliveryMethod`,
   `daysSinceListed`, `itemCondition` and `minPrice`/`maxPrice` all work there
   and are all stripped on mobile. These are the product's actual selection
   criteria, and mobile cannot express any of them.
2. **They are applied server-side**, so desktop's 15 structured results are
   drawn from the whole filtered corpus rather than being the first 15 of an
   unfiltered list. Fifteen correctly selected listings is a different product
   from fifteen arbitrary ones.
3. **Signing in unlocks seller identity** — name, join date, rating, star
   score, and a stable `/marketplace/profile/<id>`. The profile id is what makes
   grouping listings by seller possible, and no other configuration provides it.

Item detail follows search onto desktop because it is at least as good there:
coordinates arrive as clean embedded JSON rather than parsed out of a static-map
image URL, `creation_time` is exact, and the listing id is already known so
opening costs one page load with no resolve step.

## What it costs, accepted knowingly

- **Structured data is capped at ~15 per query**, signed in or out. Infinite
  scroll works when authenticated but everything past the first page is markup
  only. Client-side sorting on `creation_time` therefore applies to the first 15;
  beyond that, rely on the server-side `sortBy` having ordered the whole set.
- **The anonymous tier gets shallower** — 15 results and no seller fields,
  against the 99-and-seller-names the mobile stack currently gives for free.
- **Radius still works nowhere.** Unchanged by this decision; distance remains a
  client-side filter against per-listing coordinates.

## Two browsers, never one

The app will run **two separate web contexts that never share state**:

| | store | user agent | purpose |
|---|---|---|---|
| **authed** | `.default()` — persistent | desktop | signed-in search and detail |
| **unauthed** | `.nonPersistent()` | desktop or mobile | anonymous browsing, probes, anything that must not carry identity |

Keeping them apart is the point, not an implementation detail. A single store
would leak the signed-in identity into every anonymous request and make
"unauthenticated" untestable in the running app. It also leaves room for the
likely future split — anonymous users served from the mobile stack, signed-in
users from desktop — without further surgery.

This reverses `§7.1 — never share Safari's or the FB app's session` only for the
authed context. The unauthed context keeps `.nonPersistent()` and its original
guarantee. Note the consequence: a persistent store gives Facebook a stable
identity across launches for signed-in users. That is inherent to having a
session at all.

## No optimistic prefetching

The current feed prefetches `prefetchDepth = 8` listings by opening them ahead
of the user. That goes away.

It existed to hide mobile's ~5 s resolve plus ~1.9 s tap. On desktop the item
URL is already in the card's `href`, and the payload is readable **~0.9 s** into
the load against a ~1.85 s `didFinish` — so extracting early and abandoning the
rest lands a user-initiated open about where the prefetch was getting us anyway.

Opening eight listings nobody asked for is also the most automation-shaped thing
the app does, and the login wall risk is the largest remaining unknown. Removing
it is close to free and removes the biggest reason to be flagged. **Listings are
opened only when a user taps them.**

## Auth state is part of the data, not a UI mode

Records must carry the authentication state they were captured under, because
the available field set differs:

- Captured unauthenticated, a missing seller rating means **unknown**, not
  absent. Without the flag those are indistinguishable, and since ratings are a
  primary signal for the business/drop-shipper filter, conflating them would
  quietly corrupt it.
- The **result set** differs too, not merely the fields: signed in, a San
  Francisco query returned 15 San Francisco listings where the same query
  logged out spread to Martinez, Vallejo and Oakland. So auth state belongs in
  the **cache key** for stored result sets, not only as a column on the profile.

A record captured unauthenticated should be upgradeable — re-fetched to fill in
seller fields once a session exists.

## The mobile stack is demoted, not deleted

Kept behind a flag, for three reasons:

1. It is the only fallback if the desktop login wall fires. Going desktop-only
   would leave the app with nothing to fall back to, and **wall frequency under
   sustained use is still unmeasured** — the largest open risk in this plan.
2. It is the only surface that paginates indefinitely, which anonymous users may
   still need.
3. The likely future shape is anonymous → mobile, signed-in → desktop, which
   needs the stack intact.

Delete only after real-world wall frequency is known.

## Follow-ups this creates

- Measure login-wall frequency under sustained signed-in use.
- Decide the anonymous experience: 15 filtered desktop results, or the mobile
  feed's depth without filters.
- Confirm whether the account's saved location is what tightened results when
  signed in. If so it is a locality gain that costs no filtering work.
- Prefer the **click/modal route** for extraction where practical: it omits the
  "Today's picks" rail entirely, which is the source of every neighbour
  contamination trap in this project.
