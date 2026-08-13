# Analytics

The tracking plan: every event the iOS app sends to PostHog, what it carries, and
the rules about what it may never carry. `apps/ios/Sources/Support/Analytics.swift`
is the code; this is the plain-English version, and the two are meant to be read
together — the enum is the list, this file is why each entry is on it.

## §1 What this is not

Two things measure this app and they answer different questions.

**`Metrics`** (`Sources/Support/Metrics.swift`) is the health of the scraping:
parse coverage per field, detail latency, cards per page. It fires on every page
of every search, it is about somebody else's HTML, and it stays on the device as
`os_log`. Sending it would be paying a third party to store a debug log.

**`Analytics`** is what people do. It fires on decisions, not on pages, and it
leaves the device.

Two of the five `MetricsReporter` methods cross the line — `loginWallHit` and
`handoff` — because both are product facts wearing engine clothes. A login wall
is the failure that stops this being a product, and a handoff to Facebook is the
last thing the app can observe about somebody who went on to buy something. The
other three stay local.

## §2 Content, and what still stays behind

**Search terms and listing content go up.** §8 of the original spec says they
never leave the device; that rule still describes `Metrics`, and it does not
govern this. It was written when the only thing on the other end was an unbuilt
telemetry endpoint, and keeping it here would cost more than it protects:
*which searches come back empty* and *what do people actually click* are the two
questions this app turns on, and neither survives being reduced to a string
length.

So the events carry the words:

| Event | Carries |
| --- | --- |
| `search_submitted`, `search_completed` | `term`, lowercased — the same casing on both, so they group together |
| `listing_opened`, `listing_saved`, `listing_unsaved` | `title`, `place`, `price_text` and a parsed numeric `price` |
| `price_check_started`, `_completed`, `_failed` | `description` as typed, plus `identified_name` and `search_term` — the chain from "grill, needs cleaning" to "Weber Genesis II" to whatever got searched, which is where a wrong price went wrong |
| `price_check_price_copied`, `_listing_copied`, `_history_opened` | `identified_name`, so a conversion event reads without a join |

Everything free-text goes through `Analytics.text(_:)`, which trims and caps at
200 characters. That is a size measure, not a privacy one — a price-check
description is an unbounded `3...8` line field, and one pasted essay would
otherwise mint a single event tens of kilobytes wide, queued on disk and retried
on every flush.

Numeric price comes from `PriceGuide.parse`, the app's own reader, reused rather
than reimplemented so a price in a chart is the same number Price Check would
have compared against. `price_text` is kept beside it because "Free", "C$40" and
"$20 - $40" are all real and all lose something in the parse.

### Still not sent

* **Phone numbers.** The login identity, never shown to other users
  (`docs/backend.md` §6). `distinct_id` answers every question it could.
* **Tokens and cookies.**
* **Raw coordinates.** A city and a rounded `distance_km` are facts about a
  search; a latitude and longitude to six places is a fact about where somebody
  sleeps. `city_slug` is a super property; the coordinate is not sent.
* **Photos.** Megabytes, already stored against the price-check row.
* **The listing copy that got pasted.** `field` and `was_edited` go up; the text
  does not. The comparison that matters is *what the model wrote versus what got
  pasted*, and only our own server holds both halves — duplicating one of them
  into a second system answers nothing.

Where a signal exists in both places — feedback, copies — the duplication is
deliberate: our row can be joined to the run, and the event can be joined to
everything else that person did that week. Neither answers the other's question.

## §3 Configuration

Two build settings, same route as the API endpoint: xcconfig → Info.plist →
read at launch.

| Setting | Debug | Release |
| --- | --- | --- |
| `POSTHOG_API_KEY` | the **dev** project's `phc_…` key | the **production** project's key |
| `POSTHOG_HOSTNAME` | `us.i.posthog.com` | `us.i.posthog.com` |

Two projects, and they must stay two. Debug builds send real events — a
simulator running onboarding for the ninth time in an afternoon is a signup as
far as PostHog is concerned, and the only thing keeping it out of the numbers
everybody reads is that it lands somewhere else. A test run counts too: the host
app launches, so `$application_opened` reaches the dev project on every
`xcodebuild test`.

**An empty key means off.** No `setup` call, no queue, no disk, no network. Set
`POSTHOG_API_KEY =` in `Debug.local.xcconfig` (gitignored) to silence your own
builds without touching the committed file.

The keys are committed rather than injected at build time. A `phc_…` project key
is write-only ingestion and ships inside the binary either way, so treating it as
a secret would buy a build step and no security.

The hostname carries no scheme because xcconfig treats `//` as a comment — the
same trap `API_HOSTNAME` documents. The region must match the project: a US key
posted to `eu.i.posthog.com` is rejected, not forwarded.

Unlike `API_HOSTNAME`, a missing key does not fail the launch. Nobody's search
breaks because an event wasn't counted.

## §4 Identity

`distinct_id` is the **server's user id**, set at `AccountSession.verify` and at
every successful `restore`. Not the install id: `InstallIdentity` is wiped by a
reinstall and does not travel to a second phone, which is the property that
makes it right for a cookie jar and wrong for a person.

Person properties are `onboarding_completed` and `account_created_at` (the
second `setOnce`, so a later sign-in can't rewrite somebody's cohort). The phone
number is not among them.

`personProfiles` is `.identifiedOnly`, so everything before the phone screen
stays anonymous and no profile exists until there is a person to attach one to.
PostHog merges the anonymous history at `identify`, which is what keeps the
onboarding funnel intact across the step that creates the account.

`reset()` on sign-out and delete, so the next person on a shared phone starts a
new anonymous id rather than inheriting the last one's profile.

### Super properties

Stamped on every event, because almost every question wants to break down by
them:

| Property | Set by |
| --- | --- |
| `facebook_connected` | `AccountSession.reportFacebookConnection`, on every report including the deduped ones |
| `city_slug` | `Preferences.setResolvedPlace`, the app's only writer of a slug |

## §5 The events

`object_action`, snake_case, past tense — PostHog's own convention, followed
exactly because their insight builder groups on the prefix. `AnalyticsTests`
enforces the casing so a hurried addition can't quietly split a funnel in two.

### Account

| Event | Fired at | Properties |
| --- | --- | --- |
| `account_created` | `verify`, `isNewUser` true | — |
| `account_signed_in` | `verify`, `isNewUser` false | — |
| `account_signed_out` | before `reset`, so it lands on the profile that left | — |
| `account_deleted` | same | — |
| `onboarding_step_completed` | each step as it is passed | `step`, `step_index` |
| `onboarding_completed` | `RootView.finish`, the one-way door | — |
| `facebook_session_connected` | cookies appear while the sheet is open | `surface` |
| `facebook_connect_declined` | "Not now" on the onboarding step | `surface` |
| `notification_permission_answered` | `PushRegistrar`, which is the only thing that knows what the *system* said | `granted` |

A launch that restores an existing session identifies but sends no event —
nobody signed in, a session was confirmed. And opening the sign-in sheet on a
session that already exists is not a connection: `openedWithSession` is what
keeps every visit to Settings out of the conversion numerator.

### Browsing

| Event | Fired at | Properties |
| --- | --- | --- |
| `search_submitted` | `ResultsView.search`, before `recordSearch` | `term`, `source`, `term_length`, `word_count`, `has_active_filters`, `sort`, `radius_km` |
| `search_completed` | `ListingStore.run`, once the engine is done — **every** run, not only submitted ones | `term`, `kind`, `trigger`, `outcome` (`ok`/`empty`/`login_wall`/`failed`), `result_count`, `duration_ms`, `from_cache`, `sort`, `radius_km` |
| `discover_loaded` | `DiscoverFeed.loadIfNeeded` | `count`, `duration_ms`, `is_anonymous`, `reached_end`, `is_refresh`, `radius_km` |
| `listing_opened` | every route in — `ResultsView.open`, plus the comparables under a price check | `surface`, `position`, `listing_id`, `title`, `price`, `price_text`, `place`, `has_price`, `is_saved`, `is_seen`, `distance_km`; `is_sold` and `search_term` on a comparable |
| `listing_saved` / `listing_unsaved` | the detail screen's bookmark | `surface`, `listing_id`, `title`, `price`, `place`, `has_price`, `is_enriched` |
| `listing_opened_on_facebook` | `Handoff`, via `Metrics` | `kind` |
| `login_wall_hit` | `Metrics.loginWallHit` | `surface`, `session_count` |

`source` on a search is a guess and says so: `.searchCompletion` puts the term in
the field and submits it, so by `onSubmit` a tapped suggestion and a typed word
are the same string. Matching against the recents and the interests errs towards
crediting the suggestions, which is the right direction for the question being
asked — whether that list earns its place.

**The two search events do not pair one-to-one.** `search_submitted` fires when
a person searches; `search_completed` fires on every execution of
`ListingStore.run`, which is reached from seven places. Adjusting three filters
after one search produces one submission and four completions, so a naive funnel
between them reports a conversion above 100%. `trigger` is what makes that
legible — filter on `new_search` for the population that matches a submission:

| `trigger` | What it was |
| --- | --- |
| `new_search` | a term the user submitted; the only one paired with `search_submitted` |
| `filters` | the filter sheet closed on a change that needs different listings |
| `location` | the city changed underneath the results |
| `refresh` | pull to refresh |
| `rerun` | the "search here" control on the pinned filter bar |
| `retry` | after a failure or a wall |
| `sign_in` | a Facebook session appeared, and the result set differs by authentication |

The other six are worth having on their own rather than being noise to filter
out: a `refresh` rate is somebody distrusting the results, and a `retry` rate is
the login wall measured from the user's side.

The term is on **both** events rather than only the first. "Which searches come
back with nothing" is the question `search_completed` exists for, and it should
be one breakdown rather than a funnel with a property lookup hanging off its
first step. Same lowercasing on both, so they group together. A `browse` query
sends `kind` and no term — there is no query, and an empty string would be a row
in the top-searches list that nobody typed.

`search_completed.result_count` is what the **engine** returned, not what the
screen shows. Radius and "only new" run in the view, above it, and can empty a
grid this event reports as fifteen. That split is deliberate and it is the
interesting one: the gap between the two is a client-side filter doing something
nobody asked for.

The four browse surfaces on `listing_opened` — `discover`, `search`,
`recently_viewed`, `saved` — are the question the home screen was built to
answer. Two personal rails cost two rows above the fold on every launch, and
nothing said whether they were worth it. `price_check_evidence` is the fifth,
and the only one where a *sold* listing can be opened.

### Filters

| Event | Fired at | Properties |
| --- | --- | --- |
| `filters_applied` | filter-sheet dismissal, with a diff | `source`, `changed[]`, `sort`, `delivery`, `radius_km`, `has_min_price`, `has_max_price`, `condition_count`, `hide_viewed` |
| `filters_reset` | the Reset button | — |
| `distance_changed` | each distance pill | `radius_km`, `previous_radius_km`, `is_unlimited` |
| `location_changed` | `Preferences.setResolvedPlace` | `source`, `segment_kind`, `is_verified`, `is_first`, `radius_km` |

On dismissal rather than per control, for the same reason the search re-runs
there: somebody setting up one query touches three or four toggles, and counting
each would report four filter changes for one act of filtering.

`hide_viewed` is in the diff even though it is deliberately *not* in the re-run
trigger — a filter that costs no network is still a filter somebody chose. Its
one out-of-sheet instance is the "Show viewed" undo under an emptied grid, which
sends `filters_applied` with `source: results_notice`; that is the most
interesting instance of the event, because it is somebody reversing a filter that
just took their screen away.

Distance is the exception to the batching rule: each pill is a complete decision
applied immediately, and the sequence is the point — widening twice in a row is
somebody finding nothing nearby. `is_unlimited` exists so "Any" cannot be
averaged in as zero miles, the exact opposite of what it means.

### Price Check

| Event | Fired at | Properties |
| --- | --- | --- |
| `price_check_started` | `SellerToolsModel.run` | `description`, `photo_count`, `has_description`, `description_length` |
| `price_check_completed` | a run that reached an answer, including one with no price | `description`, `identified_name`, `search_term`, `duration_ms`, `photo_count`, `comps_found`, `sold_count`, `has_price`, `recommended_price`, `has_listing_copy` |
| `price_check_failed` | each of the run's exits | `step`, `reason`, `description`, `identified_name`, `search_term`, `photo_count`, `duration_ms` |
| `price_check_price_copied` | the number, tapped | `source`, `identified_name`, `search_term`, `recommended_price`, `asking_price`, `was_adjusted`, `adjustment_pct`, `comps_found`, `sold_count` |
| `price_check_listing_copied` | title or description, copied | `source`, `identified_name`, `field`, `was_edited` |
| `price_check_feedback_submitted` | the helpful prompt | `helpful`, `comps_found`, `was_adjusted` |
| `price_check_evidence_opened` | "What this is based on" | `comps_found`, `sold_count` |
| `price_check_history_opened` | a recent row | `identified_name`, `position`, `has_price`, `has_listing_copy` |

The three strings on a run — what was typed, what the model decided it was, what
got searched — are one chain, and they are on the failure event as well as the
success one for that reason. A `nothing_found` on the search step is the
interesting failure and it is unreadable from the step name alone: "no market for
this" and "we searched for the wrong thing" look identical without the query.

`price_check_price_copied` is the closest thing this app has to a conversion:
copying the number is what somebody does immediately before pasting it into
Facebook's price box, and it arrives from everybody rather than from the few who
answer a question. It carries both prices and the percentage between them,
because "sellers move our price up 20% on average" is the finding that would say
the median is the wrong statistic — and that finding needs the two numbers side
by side rather than reconstructed from six saved insights later.

A run that found comparables with no readable price is `completed` with
`has_price: false`, not `failed`. The app agrees: `phase` is `.done`. It is a
fact about the listings rather than a fault.

`recommended_price` is omitted rather than zeroed when there is none. A run that
found no market did not recommend $0.

Individual stepper taps are **not** an event. They would be one per press for a
control designed to be pressed repeatedly, and the number they arrive at is
already captured — as `asking_price` at the moment it is copied, which is the
only moment it means anything.

## §6 Adding one

1. Add the case to `Analytics.Event`, `object_action`, past tense.
2. Fire it from the single place that owns the fact. Every event here has one
   call site — `listing_opened` covers four surfaces from one function, because
   the alternative is the fifth route being added without it.
3. Free text goes through `Analytics.text(_:)`. Nothing on the "still not sent"
   list in §2 goes at all.
4. Add the row to §5. A tracking plan nobody updates becomes a list of events
   somebody has to reverse-engineer from a dashboard.
