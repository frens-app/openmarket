# Ingest: visibility, labelling, rejection, and attribution

**Status:** built, both ends. Migrations 00009–00011, `pkg/ingest`,
`ObservationService.SubmitObservations`, and `apps/ios/Sources/Observation`.
Every measurement in §7 is still open.
**Date:** 2026-08-22, implemented 2026-08-23.
**Related:** `data-model.md` (the row shapes this governs the writing of),
`parsing-conventions.md` (the client-side rules this extends to the server),
`analytics.md` (the other, deliberately separate, measurement path),
`logged-in-findings.md`, `filter-parameters.md` §10, `embedded-payload.md`,
`discover.md`.

`data-model.md` settled *what a listing is* and *how two observations merge*. It
left four questions open that only matter once volume arrives, and all four are
now the blocking ones:

1. **What may we store at all**, given that a signed-in capture can see things a
   signed-out visitor cannot.
2. **How is a submission labelled**, so that a Facebook change produces a
   refusal rather than a wrong answer.
3. **What do we reject**, and what does "aggressively" mean in a rule someone
   can implement.
4. **How do we attribute** a submission well enough to rate-limit it, score it,
   and tell two submitters apart, without the database holding "this person saw
   these listings".

The four are one design because they share one envelope. Sections 2–4 all hang
off the same batch record.

**Out of scope, deliberately.** Counting how many people opened a listing is not
in this version. It is a separate write path with its own privacy shape, and
nothing else here depends on it.

---

## 0. The table set

"A table of listings and a table of observation history" is the right shape, and
the history is two tables rather than one. `data-model.md` §4 owns the first
five; this document owns the rest.

| table | one row per | owner |
|---|---|---|
| `listings` | listing, merged from every observation | `data-model.md` §4 |
| `sellers` | seller | `data-model.md` §4 |
| `listing_media` | photo | `data-model.md` §4 |
| `listing_observations` | listing, as one capture saw it | `data-model.md` §4 |
| `listing_changes` | accepted price or availability transition | `data-model.md` §4 |
| `observation_batches` | ingest call | §2 |
| `observation_quarantine` | refused card | §3.5 |
| `ingest_epoch_keys` | epoch | §4.2 |
| `device_reputation` | install | §4.3 |
| `device_activity` | install, per day | §4.1 |

The history splits in two because the two halves have different lifetimes and
answer different questions. `listing_observations` is raw evidence — what a
device actually sent — and it exists to diagnose a parser regression, so its
retention is bounded (`data-model.md` §7 item 5). `listing_changes` is the
reconciled series of accepted price and availability transitions, and it is kept
indefinitely, so "when did this become sold" survives the raw payloads being
pruned.

`observation_batches` exists so provenance is written once per call rather than
once per listing. It is also where every drift signal in §3 is measured, and
where the submitter pseudonym of §4 lives — which means the pseudonym appears
once per batch instead of on every row.

---

## 1. The public-visibility floor

**Rule.** A field may be stored only if a signed-out visitor to Facebook can
observe the same fact on some Facebook surface. The capture may come from a
signed-in session; the *fact* must be public. Whether we happened to read it
through someone's account is not what makes it storable.

This is one rule with two independent reasons, and it would be worth keeping for
either alone. It bounds the database to a mirror of public information rather
than a derivative of one person's account. And it makes the signed-in and
signed-out corpora the same corpus — a listing observed by an anonymous device
and by a signed-in one produce rows that merge, instead of two tiers where the
richer one can only ever be served back to the person who captured it.

The rule is about facts, not about captures. If any signed-out surface publishes
a field, a signed-in capture of that field is storable. That distinction is what
makes §1.3 below a research question rather than a policy question.

### 1.1 Verdicts, per field group

Four labels. Every field an extractor produces carries exactly one.

| label | meaning | what we do |
|---|---|---|
| `public` | observed signed out on at least one surface, dated | store |
| `identifying` | names a specific Facebook account, and is login-gated | never store the value; a keyed hash may stand in (§1.4) |
| `unverified` | login-gated, or believed public on an uncited measurement | store only if it survives §1.4's second test |
| `observer_derived` | a fact about the person browsing, not about the listing | never leaves the device (§1.5) |

**The floor has two tests, and a field only has to pass one.** Either a
signed-out visitor can see the fact, or the fact names nobody. The first is the
rule the corpus is built on. The second exists because refusing an unverified
field is a cost as well as a protection, and a review count attached to a hash
is not a privacy problem worth paying that cost for (§1.4).

The `public` verdicts, with the measurement each rests on:

| field group | source | verdict | evidence |
|---|---|---|---|
| listing id, `creation_time`, title, price, previous price, cover photo, city, `facebook_place_id`, `delivery_types`, category, `is_sold`/`is_pending`/`is_live` | desktop search, embedded payload | `public` | live signed-out search, 15 cards / 15 feed edges, `data-model.md` §1, 2026-08-12 |
| listing id, rendered title, price, location, cover image URL | desktop search, rendered DOM tail | `public` | same run |
| sold and pending flags on the sold-filtered query | `availability=out of stock` | `public` | San Francisco, **logged out**, desktop, `filter-parameters.md` §10, 2026-08-07 |
| title, price, category, description, condition, photos, coarse listed-age, approximate listing location and coordinate, delivery, status | desktop item page | `public` | signed-out item row, `data-model.md` §1 |
| card identity, title, price, location | anonymous Discover | `public` | `discover.md` §0.0; note a Discover card carries no `creation_time`, no `delivery_types` and no sold state at all (`discover.md` §4.6) |
| seller display name, seller star rating | mobile item page, signed out | `public` | confirmed by hand, 2026-08-22; supersedes the `unverified` reading of `logged-in-findings.md` §1 (see §1.3) |

The price-comparison path is the reassuring one. Both halves of what it fetches
— the live market and the recently-sold set — were measured logged out, so the
whole comparables corpus clears the floor without an exception.

### 1.2 The violations

**One field fails: the stable seller id.** Everything else in the seller block
is stored, and §1.4 says under which of the two tests.

| field | desktop signed out | desktop signed in | mobile signed out | verdict |
|---|---|---|---|---|
| `/marketplace/profile/<id>` (stable seller id) | **0 links** | **3 links** | 0 on 6/6 | `identifying` |
| display name | absent | present | **present** | `public` |
| star rating | absent | present | **present** | `public` |
| rating count, `Highly rated on Marketplace`, join year | absent | present | not separately pinned | `unverified`, stored |

`logged-in-findings.md` §1 calls the stable seller id "the plan's best result",
and it is the one field this rule refuses. That is not an accident of the rule;
it is the rule working. The id is valuable *because* it names an account, and a
value that names an account is the one thing here that cannot be stored.

§1.4 keeps the product function without keeping the identifier.

### 1.3 What the mobile surface publishes, and what is still open

**Resolved 2026-08-22.** Seller display name and seller star rating are visible
to an unauthenticated mobile browser, confirmed by hand. Under the rule in §1,
that makes both storable from *any* capture, including a signed-in desktop item
page — the fact is public, so where we happened to read it does not matter.

This resolves the contradiction that v0.1 of this document flagged.
`logged-in-findings.md` §1 asserted in bold that the seller join date is public
on signed-out mobile, while the table above that sentence is introduced as "Six
listings, both user agents, **all signed in**". The assertion was right about
the surface; its citation was the wrong table.

Three neighbouring fields were not named in the 2026-08-22 check and stay
`unverified`. They are stored anyway, under the second test in §1.4:

- **rating count** — the `(N)` beside the stars.
- **`Highly rated on Marketplace`** — Facebook's own badge against an
  unpublished threshold (`data-model.md` §4). It is never recomputed from the
  score, so it is observed or it is absent; there is no derivation.
- **join year**, with `joined_text` beside it. A year we failed to parse and a
  page that carried none are different facts, and only the raw string tells them
  apart.

Measuring them is still worth doing and is §7 item 1 — a field whose visibility
is known is a field the next decision about it is easy. It no longer blocks
storing them.

### 1.4 The second test: does the field name anyone

A login-gated field is refused when it identifies a Facebook account. It is
stored when it describes how somebody trades and hangs off an identifier that
already names nobody.

That line falls between the profile id and everything beside it. The id *is* the
account: it resolves to a profile page, it can be enumerated, and it is the
whole reason a session is needed to see the block. A join year, a review count
and a badge are aggregate reputation. Attached to a cluster key they say "this
seller has 44 reviews and has been here since 2010" and identify no one, which
is also the only form in which the product wants them.

So the seller block splits three ways.

**Seller identity — store a cluster key, never the id.** The product function is
grouping: "these 14 listings are one seller", which is what the
business-and-drop-shipper filter needs. Grouping needs equality, not the value.

```
seller_cluster_key = HMAC(k_seller, facebook_profile_id)   -- 16 bytes
```

`k_seller` is a single long-lived server key, never rotated (rotation would
shatter every existing cluster) and never shipped to a client. What this buys:
listings group by seller exactly as they would on the raw id; the column cannot
be enumerated, cannot be turned back into a Facebook profile URL, and cannot be
republished as an identifier. What it costs: we cannot link a seller across a
data reset, and we cannot show anyone a link to the seller's profile. Neither is
a feature we have.

The keyspace is small enough to brute-force *with the key* — Facebook profile
ids are numeric — so this is protection against the column leaking, not against
the key leaking. It is still the right trade: the column is in every backup and
every query result, and the key is in one secret.

**Seller name and rating — store them, under the first test.** Both are public
(§1.3), so a signed-in desktop capture of either merges with a mobile one.

**Join year, rating count and the badge — store them, under the second.** None
of the three names an account, and all three are what the
business-and-drop-shipper filter is actually made of: `logged-in-findings.md`
§1a found ten consecutive anthurium listings rated 10 out of 10, against
one-off furniture sellers who mostly are not rated at all. "Has ratings" is
itself the commercial-seller signal, and it is unreadable without the count.

**Seller location — not stored, on any surface, under either test.** The item
page's city and coordinate belong to the *listing*, and they are already on
`listings` as `listing_location_text` and `listing_approx_lat`/`lon`. A
`seller_location` column could only ever be filled from those, which is the
inference `data-model.md` §1 exists to forbid. The `listing_` prefix on those
columns is what makes that a naming error rather than a judgement call
(`data-model.md` §8).

**The seller section's existence — keep the status, drop the contents.**
`FacebookMarketplaceSellerSectionStatus` in `protos/openmarket/api/v1/listing.proto`
already separates `UNAVAILABLE` (this capture could not see a seller section)
from `NOT_OBSERVED` (it could and did not). That distinction is extraction
health, not seller data, and it stays.

### 1.5 `observer_derived`: what must not cross the process boundary

These are facts about the person browsing. They are not covered by the
public-visibility rule at all, because the question "could an anonymous visitor
see this" has the wrong shape — an anonymous visitor sees *their own* version of
it.

- **The account's own location.** `logged-in-findings.md` §7.3 measured the
  picker pill reading `Location: New York, New York, Within 5 mi` while the app
  browsed Seattle at 10 mi. That string is where the observer lives.
- **Signed-in feed composition and ordering.** Discover is Facebook's own feed,
  and `discover.md` §0 measured what the session changes: ranked by "a
  popularity pool on an IP and a cookie" anonymously, and by "the account's own
  history" signed in. So which listings appear signed in, and in what order, is
  a statement about the account's interests. Store the listing facts from a
  signed-in Discover batch; do **not** store card position, and do not treat
  presence-in-feed as a property of the listing.
- **The observer's own Facebook profile id**, readable from the signed-in
  chrome.
- **Cookies, tokens, and any header from the Facebook session.**

Enforce at both ends. The client never sends them, which is what keeps them out
of request-level failure paths. The server rejects a batch that contains a field
labelled `observer_derived`, because "the client never sends them" is a property
of the current client and the server outlives it.

Search terms are the deliberate exception, and they are already an exception:
`analytics.md` §2 sends them to PostHog on purpose, having weighed it. A search
term reaches the ingest path only as the query fingerprint of §2.2 — a hash,
used to compare two runs of the same query, not a stored string.

---

## 2. The batch is the unit of everything

One ingest call carries one batch: a set of observations captured from one page
by one device at one time. Provenance lives on the batch, once, rather than on
every observation.

```sql
CREATE TABLE observation_batches (
  id                            uuid PRIMARY KEY,       -- UUIDv7
  received_at                   timestamptz NOT NULL DEFAULT now(),
  observed_at                   timestamptz NOT NULL,

  submitter_id                  bytea NOT NULL,         -- §4.2, not a device id
  submitter_trust               text NOT NULL,          -- trusted | normal | probation

  facebook_browser_variant      text NOT NULL,
  facebook_page_route           text NOT NULL,
  extraction_method             text NOT NULL,
  facebook_authentication_state text NOT NULL,

  extractor_revision            text NOT NULL,
  app_version                   text NOT NULL,
  app_build                     text NOT NULL,

  query_fingerprint             bytea,                  -- §2.2
  shape_fingerprint             bytea,                  -- §3.4

  cards_seen                    int NOT NULL,
  cards_submitted               int NOT NULL,
  cards_accepted                int NOT NULL,
  cards_quarantined             int NOT NULL,
  client_dropped                int NOT NULL,
  client_drop_reasons           text[] NOT NULL DEFAULT '{}'
);
```

Three of those columns are the ones that do not look necessary and are.

### 2.1 `cards_seen`, `client_dropped`, `client_drop_reasons`

`parsing-conventions.md` §1 requires the client to log every value it does not
recognise. It logs to `os_log`, on the phone, where nobody reading production
data will ever see it. So an extractor that drops every card on a page and a
page with nothing on it produce the identical server-side record: an empty
batch.

That is precisely the failure this whole document is trying to make loud. The
counts make a client-side drop legible server-side without shipping the dropped
payload: `cards_seen: 15, cards_submitted: 0, client_drop_reasons: {"card_unparseable"}`
is a Facebook change, and it is visible in a query.

`ListingStore.submitFeedObservations` is where the client counts them: it runs
the DOM parse itself and counts what came back nil, rather than taking the
grid's length as the answer.

### 2.2 `query_fingerprint`, and why absence usually proves nothing

A listing that was in a result set yesterday and is not today has *not* been
shown to have been delisted. It might be a different query, a different radius,
a different account's floor (`logged-in-findings.md` §7.3 — the account's radius
is a floor the app cannot raise), or the same query on a different day.

```
query_fingerprint = SHA256(query_text_lower ‖ availability ‖ daysSinceListed
                           ‖ sortBy ‖ deliveryMethod ‖ place_id ‖ radius)
```

With it, one narrow inference becomes available: the same fingerprint, from the
same authentication state, within a short window, missing a listing that a prior
run of it contained is **weak** delisting evidence. It never writes
`availability`; it can lower a confidence score and schedule a detail re-check.
Without the fingerprint, that inference is not available at all, and the
temptation is to make it anyway from whatever query happened to run.

The fingerprint is computed, stored and indexed. The inference itself is not
built — there is no confidence score to lower and no re-check queue to schedule
into, and adding either before the corpus exists would be guessing at both.

### 2.3 Where the schema puts each of these

`SubmitObservationsRequest` carries the batch: one capture context, one query
context, the extractor revision, the client's counts, the shape fingerprint, and
the observations. Field 1 on both observation messages is reserved, because
capture context describes the page and belongs on the batch rather than on every
card.

`FacebookMarketplaceQueryContext` holds the filter parameters of
`filter-parameters.md` §1 plus the query-text hash. It is what labels a card
from `availability=out of stock` as coming from the sold-filtered query —
presence in that result set is the strongest public evidence of sold there is,
and it is only usable if it is labelled. A separate page route would be the
wrong shape: it is the same search route with a filter on it.

`extractor_revision` sits on the batch rather than on each observation.
`data-model.md` §2 notes that debug pins build `1`, so the app build alone
cannot identify a parser.

Two fields on the query context are strings where an enum looks natural.
`sort_by` and `delivery_method` only feed the fingerprint, and an enum would
collapse a token nobody has surveyed into UNSPECIFIED — the silent drop
`parsing-conventions.md` §1 exists to forbid.

### 2.4 Only a live read may mint an observation

`ListingStore.enrich` paints the screen twice on purpose. Step 2 reads
`cache.profile(for:)` and stages a stored detail immediately; step 3 revalidates
against the live page and calls `record` only on that path. If the live read
fails — a login wall, a removed listing, no `itemURL` on a WebLite card —
`fetchLive` returns nil and `enrich` returns the **cached** value anyway.

So the returned `Listing` is the same type whether it came off the network or
off disk out of `ListingCache`, and a caller that submits it cannot tell which. That is
the whole hazard, and it is worst on exactly the path §5.4 depends on: a saved
listing re-opened offline would restate a weeks-old "available" as a fresh
observation, and `sold_not_before` would move forward on evidence that does not
exist.

Three rules, in the order they should be enforced.

**Mint at the live read, not from the return value.** The only code that knows
the read was live is `fetchLive`, at the point it already calls `record`. An
observation created anywhere downstream is guessing, so `record` is the single
mint point for an item observation and `ObservationCapture` is reachable from
nowhere else in the store.

That is a rule enforced by call site rather than by type, which is the weaker of
the two. A provenance on the returned value (`live(at:)` versus
`cached(fetchedAt:)`) would turn it into one the compiler asks about, and the
cache already knows the answer — `cached.fetchedAt` is in the log line the cache
branch writes. Worth doing the next time `enrich` is opened.

**`observed_at` is the fetch instant, never the submit instant.** A batch queued
offline and sent an hour later keeps the fetch time; `received_at` records the
difference. `FacebookMarketplaceObservationContext.observed_at` is already
required, so this is only a question of who fills it — and stamping `Date()` at
submit time is the mistake that makes a cache read indistinguishable from a live
one even when the first rule held.

**Mint from a settled read, not a partial one.** `loadDetail` fires `onPartial`
with text before the gallery, and the seller section renders after both
(`logged-in-findings.md` §7.4 — the fix was a short re-poll). An observation
minted at the partial stage records a truncated gallery and a
`SELLER_SECTION_STATUS_NOT_OBSERVED` that is our timing rather than Facebook's
page. §5.6 forbids a truncated capture from shrinking a gallery; this is the
same rule one step earlier, where it is cheaper.

The server cannot verify any of this — it has no way to tell a live read from a
replayed one — so it does the one thing it can: bound the claim. Reject a batch
whose `observed_at` is in the future beyond a small clock skew, or older than
`received_at` by more than a fixed window. That does not catch a dishonest
client. It catches the honest bug, which is the one that will actually happen.

### 2.5 What this removes from `data-model.md` §4

`data-model.md` §4 puts provenance directly on each row:
`listing_observations` carries `observer_device_id uuid REFERENCES
user_devices(id)`, `observer_app_version`, `observer_app_build`, and the four
context columns; `listing_changes` carries the same set again.

Those columns are the exact pattern §4 exists to remove. A foreign key to
`user_devices` on every observation is a browsing record with a join already
written, and repeating it on `listing_changes` puts it in the table that is kept
indefinitely.

Replace all of them with `batch_id uuid NOT NULL REFERENCES
observation_batches(id)` on both tables. Everything a reconciler or a debugger
needed is still one join away, the context is written once instead of once per
card, and the only identity on the path is the epoch pseudonym.

This does not weaken `data-model.md` §2's requirement that provenance be
server-attributed rather than trusted from the client. It moves where the server
attributes it: onto the batch, from the authenticated session, once per call.

---

## 3. Rejection: fail closed

"Aggressive" is only implementable as four specific gates. Every one of them
quarantines rather than nulls, because a null is indistinguishable from
`data-model.md`'s "this surface did not tell us" and a quarantine is not.

### 3.1 Present-but-wrong is fatal; absent is not

This is the whole rule, and it is the one that makes a Facebook change safe.

`parsing-conventions.md` §2 already separates absent from empty on the client.
Extend it with a third state at the ingest boundary: a field that is **present
and does not parse** fails the card. Not the field — the card.

A field Facebook stops sending degrades harmlessly: it arrives absent, and
`data-model.md` §5 already forbids a partial observation from erasing a richer
fact. A field Facebook changes the *shape* of is the dangerous one, and it fails
loudly under this rule. If `creation_time` ever moves from seconds to
milliseconds, a per-field drop yields listings from 1970 spread across the
corpus; a per-card refusal yields an empty batch and an alarm.

### 3.2 Plausibility envelopes, not just syntax

The validation in `listing.proto` is syntactic — `^[0-9]{8,}$`, currency length
3, rating within 0–5. Syntax does not catch a value that is well-formed and
absurd. Each of these quarantines the observation:

| field | envelope |
|---|---|
| `listed_at` | ≥ 2016-01-01 and ≤ received_at + 1 day |
| `amount_decimal` | ≥ 0 and < 10,000,000 major units; `0` stays valid — `data-model.md` §4 makes free a real price |
| `latitude` / `longitude` | on Earth, and within a generous multiple of the batch's searched radius |
| `title` | 1–500 characters after trimming |
| `media.position` | ≥ 0, dense, no duplicates within one observation |
| `availability` | `sold ∧ pending` is invalid — already in `data-model.md` §4 |
| `facebook_listing_id` vs `cover_photo_fbid` | a batch where every card shares one value is an extractor collision, not fifteen identical listings |

That last row is the "Today's picks" failure of `parsing-conventions.md` §3
arriving at the server. It has already happened four times on the client, with
coordinates, condition, sold state and photos.

### 3.3 The circuit breaker

Quarantine rate is measured per
`(browser_variant, page_route, extraction_method, extractor_revision)`. When it
crosses a threshold over a rolling window, **that combination stops being
accepted entirely** and its batches are stored raw for diagnosis without
touching canonical rows.

A per-card gate alone is not aggressive enough for the case that matters. When
Facebook changes something, the failure is not one bad card; it is every card
from every device on that build, arriving at whatever rate the fleet browses. A
gate that refuses each one individually still lets a systematically wrong
extractor keep writing whatever it happens to get right, which is worse than
nothing: it is a corpus with a bad patch in it and no marker where the patch
starts.

### 3.4 `shape_fingerprint`: the alarm that fires before the damage

For a payload-derived batch, hash the sorted set of JSON key paths the extractor
saw. Not the values — the shape.

A fingerprint that has never been seen before, appearing across many devices in
a short window, is Facebook shipping a change. It fires whether or not anything
failed to parse, which is the point: the expensive failures are the silent ones.
`DOOR_DROPOFF` (`parsing-conventions.md` §1) was found by a person reading a log
line and noticing a token that should not have been there. A fingerprint is that
person, running continuously.

### 3.5 Refusing a build outright

The breaker in §3.3 reacts to a rate, which means it needs traffic before it can
act and it acts on a whole surface. Neither is right for the case where a
*specific release* is known to be producing wrong data — a parser bug found
after shipping, a beta that went out with a half-finished extractor.

`BuildPolicy` refuses those by name, at the door, from the `X-Openmarket-App-Build`
header. A refused batch leaves no batch row, no observation and no quarantine
entry: the point is to throw the data out, not to file it. Two settings, both
off by default — a floor on `CURRENT_PROJECT_VERSION`, which is monotonic and so
can have one, and a list for a bad build newer than the last good one.

With a floor set, a client that sends no build is refused. It cannot show it is
above the floor, and a floor that lets those through is advisory.

### 3.6 Where quarantined rows go

A separate table, with the raw payload, the batch id, the failing gate, and the
field path. Not `listing_observations`. Retention is short — long enough to
diagnose a regression, per `data-model.md` §7 item 5 — and nothing in the
serving path reads it.

---

## 4. Attribution without identity

Three things want a "who": rate limiting, trust scoring, and corroboration
counting. Only the first two need the answer to persist, and none of the three
needs it attached to the data.

### 4.0 In plain terms

Writing `user_id` on every observation is the default, and it is the thing to
avoid. It leaks nothing on its own — but the table it produces *is* a record of
what each person browsed, and from then on every backup, every export, every
debugging query and every future engineer has one.

None of the three questions needs a name. Each needs strictly less:

| question | what it needs |
|---|---|
| Is one install flooding us? | a count per install. No listing ids. |
| Is this install's data any good? | a score per install. No listing ids. |
| Do two submissions of this price agree? | whether the two submitters differ. Not who they are. |

So a batch carries a nickname instead of a name. The value behind it is
`user_devices.id`, which migration 00003 already keys per `(user_id, install_id)`
— an install, not a person:

```
submitter_id = HMAC(k_epoch, device_id)
```

**Is HMAC reversible?** Not by inversion — there is no arithmetic that runs it
backwards, with or without the key. But that is the wrong question to stop at.
The real question is whether someone can *guess and check*, and that depends on
two things: do they have the key, and how many candidate inputs are there.

| | small input space | large input space |
|---|---|---|
| **without the key** | safe — you cannot compute a candidate's HMAC at all | safe |
| **with the key** | **recoverable** — enumerate every candidate and compare | safe |

`device_id` is a UUID, so the input space is far too large to enumerate and the
bottom-left cell does not apply. `facebook_profile_id` is a numeric Facebook id,
so it does — which is the caveat §1.4 already states about `seller_cluster_key`.
Neither case makes the hash useless. Both mean the key is the thing being
protected, and they differ only in what happens if it leaks.

That is why the key is deleted rather than kept. **A new secret each epoch, and
the old one destroyed.** Inside one week, "this submitter sent 900 batches of
the same listing" is answerable, which is what abuse detection needs. Once that
week's key is deleted, its nicknames point at nothing — not "nothing we look
up", but nothing anyone can compute, including whoever holds a copy of the
database.

**What is linkable, stated exactly.** Within one live epoch, two batches from
one install share a `submitter_id`, so they are linkable to each other. That is
not an oversight — §5.2 needs exactly this to tell corroboration from one device
repeating itself. What the pseudonym never gains is a name: reaching an install
from it needs the epoch key, and reaching a *person* needs the epoch key and
`user_devices`. After the key is deleted, neither step exists at any price.

So the guarantee has two tiers, and it is worth being clear which is which. In
the current epoch, the protection is that the key is a secret and §4.1 keeps the
other half of the join in a separate table. After the epoch, the protection is
mathematical and unconditional.

### 4.1 The split

> Two records, and neither one alone is a profile. One knows what happened and
> not who. The other knows who, and how much, and not what.

- `observation_batches` holds pseudonyms and content.
- `device_activity` holds a `device_id` and counters — batches and cards per day
  — and no listing ids, no query, no content.

Rate limiting and abuse detection read the second. Everything else reads the
first. Joining them is not possible after an epoch key expires, and there is no
code path that does it before.

### 4.2 Epoch keys

```sql
CREATE TABLE ingest_epoch_keys (
  epoch       date PRIMARY KEY,
  key         bytea NOT NULL,
  expires_at  timestamptz NOT NULL
);
```

A random key per epoch, stored, then deleted at `expires_at`. Deriving it from a
master key instead would be simpler and would defeat the purpose: a derived key
is recomputable forever, so nothing is ever actually unlinkable.

```
submitter_id = HMAC(k_epoch, device_id)[0:16]
```

**Rotation and deletion are two events, not one.** A key has three lifetimes,
and conflating them is how a design like this quietly stops working:

| phase | duration | what is possible |
|---|---|---|
| **active** — mints new pseudonyms | one epoch | everything |
| **retained** — superseded, still stored | a grace window | `submitter_id` still resolves to a device, for investigating a batch noticed late |
| **deleted** | forever after | nothing resolves; the pseudonym is a number |

**The recommendation: a one-week epoch, and a 14-day grace.** Worst case, an
observation is resolvable for about three weeks and then never again.

The week comes from §5.2 rather than from privacy. Corroboration compares two
`submitter_id` values, so it only works inside one epoch — and a shorter epoch
means more pairs of observations straddle a boundary and fail to corroborate
when they should. That is a safe failure (a value stays provisional longer, and
nothing false is written), but at a daily grain it would be the common case
rather than an edge.

The grace comes from what an investigation actually needs. A poisoned batch is
usually noticed days after it lands, and the question then is "which install
sent this, and what else did it send". Fourteen days answers that for anything
recent. It is deliberately not ninety: the longer the grace, the less the epoch
grain matters at all, because the resolvable window is grace-dominated.

**Volume abuse does not need any of this.** Rate limiting and "one install is
flooding us" read `device_activity` (§4.1), which is keyed on the real device id
and never pseudonymous. The epoch window only bounds questions that involve
*content* — which listings a submitter sent, and whether two submitters agree.
That is why the grace can be short without weakening the defences that matter.

### 4.3 Reputation survives the epoch; linkage does not

Trust cannot rotate weekly or a poisoner resets by waiting. So reputation lives
on the device, holding counters and nothing else:

```sql
CREATE TABLE device_reputation (
  device_id          uuid PRIMARY KEY REFERENCES user_devices (id) ON DELETE CASCADE,
  batches_accepted   bigint NOT NULL DEFAULT 0,
  cards_accepted     bigint NOT NULL DEFAULT 0,
  cards_quarantined  bigint NOT NULL DEFAULT 0,
  conflicts_caused   bigint NOT NULL DEFAULT 0,
  tier               text   NOT NULL DEFAULT 'normal',
  first_seen_at      timestamptz NOT NULL,
  last_seen_at       timestamptz NOT NULL
);
```

The ingest handler reads the tier and stamps `submitter_trust` onto the batch as
a **snapshot**. The reconciler then never joins back to a device: it has the
tier it needs, sitting on the row in front of it.

`user_devices` is per `(user_id, install_id)` already — migration 00003 made an
install the grain deliberately, because a Facebook cookie jar is a property of
an install. That is the right grain here too, and it means reputation is
per-install rather than per-person.

### 4.4 What this does not protect against, stated plainly

The server sees the real install id beside the listings it submitted, for as
long as it takes to authenticate the call and compute the HMAC. This design
protects what is *retained*, not what transits. The mitigations are that the
pair is never written and never logged — `cmd/api/logging_interceptor.go`
already logs procedure and duration and no message bodies, for the same class of
reason — and that the derivation happens in the handler rather than anywhere a
request tracer would reach.

Anyone with the live epoch key and `user_devices` can recompute that epoch's
pseudonyms. That is the design, not a flaw in it: the epoch is the window in
which abuse detection has to work. The guarantee is about what remains once the
key is deleted, and after that it is unconditional.

### 4.5 Do not join this to PostHog

`analytics.md` §5 already sends `listing_opened` with `listing_id`, `title`,
`price` and `place`, attached via `distinct_id` to the server's user id. That is
a deliberate, documented decision and this document does not reopen it.

It does mean two systems hold overlapping facts at different grains, and the
rule that keeps §4 meaningful is that **nothing joins them**. `listing_opened`
carries a user id and a listing id and a timestamp; an `observation_batches` row
carries a pseudonym, a listing set and a timestamp. Reconciling the two on time
and listing would re-identify submitters from the outside, using nothing the
schema here forbids. So the rule is not a schema constraint — it is a rule about
exports, and it needs stating because no table will enforce it.

This applies with more force once popularity counting arrives, since that is the
write path whose PostHog counterpart already exists.

---

## 5. Consistency, without knowing who

The user-facing question was "how do we know the data is from a reputable
source". The answer this design gives is that confidence in a *fact* should come
from the fact's own evidence, not from confidence in a submitter. Submitter
trust is one input, and it is the weakest of the three.

### 5.1 Source authority beats recency

`data-model.md` §5 merges per field group. Rank the sources within a group, so a
poorer source cannot overwrite a better one merely by arriving later:

| for | authoritative | weaker | must never write it |
|---|---|---|---|
| `listed_at` (exact) | embedded payload | — | rendered DOM, Discover card |
| price, availability | embedded payload; item page | rendered DOM | Discover card (carries no sold state) |
| media set completeness | item page | — | search card (cover photo only) |
| description, condition | item page | — | search card |
| `availability = sold` | the sold-filtered query, labelled per §2.2; item page `is_sold` | — | a plain search, which returns 0 sold by construction |

The last row is the one that has to be labelled to be usable. A plain search
returning 0 sold and 0 pending (`filter-parameters.md` §10, logged out,
2026-08-07) means *absence from a plain search is not evidence of anything* —
and presence in an `out of stock` result set is strong evidence of sold. Same
route, same parser, opposite meanings, distinguishable only by the query context.

### 5.2 Provisional and confirmed

Every accepted value on a volatile field carries `distinct_submitters` and a
state:

- **provisional** — one submitter, or one probationary submitter. Serve it,
  label it as recent-and-unconfirmed, and let it decay.
- **confirmed** — two independent submitters within a window, or one trusted
  submitter on an authoritative route.

Independence is a distinct `submitter_id` **within one epoch**. Two batches from
one device do not corroborate each other, which is exactly the case a poisoner
produces.

The epoch qualifier is load-bearing. Across a boundary the same device gets a
new pseudonym, so two of its own observations would read as independent
agreement. Requiring a shared epoch turns that into a missed corroboration
rather than a false one — the value stays provisional until a genuine second
device arrives. §4.2 is where the epoch length is chosen, and this is the
constraint that chooses it.

### 5.3 Availability transitions are not symmetric

Forward — `available → pending → sold` — accepts on a single authoritative
observation. It is where listings go, and being briefly wrong in that direction
means hiding something that has probably sold.

Backward — `sold → available` — requires corroboration or an item-page
observation. Relisting is real, so the transition must be possible; a single
stale card resurrecting a sold listing is the more likely cause and the more
damaging one.

### 5.4 Sold is an interval, not an instant

Facebook publishes no sale timestamp. `filter-parameters.md` §10 is explicit
about it: `creation_time` is the **only** time field anywhere in a sold card's
payload block, and no sale, close, sold-at or updated field exists.
`data-model.md` §2 already states the consequence — observing `sold = true` at
14:00 proves the listing was sold by 14:00 and establishes nothing else.

So store a bracket, and name the columns so that no reader mistakes it for a
fact:

```sql
-- on listings, replacing data-model.md §4's availability_changed_at
sold_not_before  timestamptz,   -- our last observation of NOT sold
sold_not_after   timestamptz,   -- our first observation of sold
```

`availability_changed_at` has to go. The name asserts we know when Facebook
changed the value. What we know is when we first saw it changed, and the two
differ by however long nobody looked.

**The width of that bracket is a fact about us, not about the listing.** If no
device observed a listing for three weeks, the bracket is three weeks wide. Any
surface that shows a sale date must therefore show its width too, or show
nothing — a midpoint rendered as a date is a fabricated fact.

`listing_changes` remains the durable record of the transition; the two columns
on `listings` are a materialized convenience derived from it.

**Two narrowings, and they are independent.**

1. **Pending.** The path is `available → pending → sold`, and a pending
   observation tightens `sold_not_before` without needing a second device.
2. **`listed_at`.** An item listed *n* days ago and observed sold has sold in at
   most *n* days. This bound does not depend on our observation cadence at all,
   which matters more than it sounds: a sold card in a comparables search is
   usually the first and only time we ever see that listing, so
   `sold_not_before` is null and this is the *only* bound available. It is the
   number the app already shows — `PriceEvidenceView.soldFootnote` renders
   "Sold in ~4 days" from `daysListed`.

That second bound inherits its precision from `listed_at`. `data-model.md` §4
already carries `listed_at_precision` (exact | day | week | month), and it has
to travel with any derived duration: "sold in ~4 days" computed from "Listed 3
weeks ago" is a different claim from the same phrase computed from an embedded
`creation_time`.

**Disappearance is not a sale.** A plain search returns 0 sold and 0 pending by
construction (`filter-parameters.md` §10, logged out, 2026-08-07). A listing
dropping out of a live result set is equally consistent with sold, pending,
deleted, expired, edited out of the query, or moved outside the radius. It must
never write `sold_not_after`. The same-fingerprint rule in §2.2 may lower a
confidence score and schedule a detail re-check, and that is the whole of what
absence buys.

**The bracket is revocable.** Relisting is real (§5.3), so a corroborated
`sold → available` clears both columns rather than leaving behind a bracket
describing a sale that was undone.

**The saved-listing re-open is the one path that tightens it for free** — and
only when the read was live, which §2.4 is about. A save is the only durable
reason a device has to return to one listing, and `DetailView.task` re-enriches
on every open — so a user revisiting something they kept produces a dated
item-page observation, on a listing the server has almost certainly already seen
as a search card. `sold_not_before` and
`sold_not_after` then close around a real interval instead of an open-ended one.

Three things make this work, and all three already exist:

- **It is the re-check `discover.md` §5.2 asks for.** That section rules out
  bulk re-checking as exactly the automation-shaped traffic the app avoids
  (`decision-desktop-primary.md`), and says to re-check on open instead. A save
  is what makes an open happen twice.
- **The item page carries `is_sold`**, which a plain search never does.
- **It joins on an alias we already have.** `SavedListings` keys on
  `Listing.identity`, the cover-photo FBID, which `data-model.md` §3 already
  treats as a unique alias.

Two traps come with it. A sold item page carries **21** `is_sold` values and
only one belongs to the listing on screen — anchor on `location_text`, per
`discover.md` §5.2 and `parsing-conventions.md` §3. And a re-open that hits a
login wall, a 404, or a removed listing has observed nothing: it must write no
availability at all, because `RawDetail.isSold` being nil means "nothing told
us", never "available".

Nothing new is sent to make this work, and nothing should be. The save list is
local — `SavedListings` keeps ids in `UserDefaults` and they never leave the
phone — and the observation a re-open produces is an ordinary
`PAGE_ROUTE_ITEM` detail observation. **Do not add a "this came from a save"
flag.** It would buy nothing the reconciler needs and would label a watchlist in
the database.

The pattern is still visible without the flag, and it is worth naming. Repeated
item observations of the same few listings from one `submitter_id` are a
watchlist to anyone reading the table during a live epoch. That is the strongest
concrete argument for a short epoch grain (§7 item 4): after the key is deleted
the pattern remains, but there is nothing left to attach it to.

One thing the bracket can never become. Every price on a sold card is an
**asking** price: Facebook publishes what the item was listed at and never what
changed hands, so an accepted offer below asking is invisible
(`filter-parameters.md` §10). A sale interval and a sale price are separate
problems, and only the first one is solvable from this data.

### 5.5 The currency is a property of the page

`listing_price` is `amount` (`"75.00"`) and `formatted_amount` (`"CA$75"`), and
it carries no currency code. The code is published once for the whole page, at
`marketplace_settings.current_marketplace.primary_currency` — measured
2026-08-23, `"primary_currency":"USD"` on a US search. Every card on that page
shares it, so the client reads it once and stamps it on each observation.

`price_minor` is then the decimal scaled by that currency's exponent. "Minor
units" is not a synonym for cents: two places for most currencies, zero for JPY,
three for KWD, which is exactly why the code has to be a fact rather than a
default.

**Do not read `amount_with_offset_in_currency`.** It looks like the price in
minor units and is not. On a Toronto payload it read `5429` against an `amount`
of `"75.00"`, with the same ~0.7239 factor on every card — an internal converted
amount, not CAD. Three failures follow from treating it as the price, and the
first is the one that hides:

- it collapses to the listing price on US pages, so a US-only check passes;
- it stores CA$75 as 54.29; and
- it moves with the exchange rate, manufacturing price changes on listings
  nobody edited.

The currency also cannot come from the symbol in `formatted_amount`. `$` is CAD,
AUD and MXN as readily as USD, and `CA$75` only disambiguates because Facebook
chose to render a prefix it is under no obligation to keep.

`strikethrough_price` carries a decimal too —
`{"formatted_amount":"$150","amount":"150.00"}` — so `previous_price_minor` is a
number on structured search cards under the same rule.

`price_formatted` is kept beside the number regardless. "Free", "$20 - $40" and
"CA$40" are all real and all lose something in the parse.

### 5.6 "Photos stay up to date" is about ids, not URLs

`data-model.md` §4 already states that fbcdn URLs are expiring locators rather
than identity, and the freshness rule falls straight out of it:

- the same `facebook_photo_id` with a new URL is **expiry**. Refresh
  `last_source_url`; nothing about the listing changed.
- a new `facebook_photo_id` is **a new photo**. Insert it.
- a `facebook_photo_id` that stops appearing is **not a deletion**. Only a
  complete item-page media observation can shrink a gallery, and only when the
  seller section and gallery both parsed — a truncated capture must not delete
  photos. `logged-in-findings.md` §1 also notes that rendered photo counts
  undercount lazy-loaded galleries, so a short list is routine.

---

## 6. Retention

| data | kept |
|---|---|
| canonical `listings`, `listing_media`, `sellers` | indefinitely |
| `listing_changes` (price and availability history) | indefinitely |
| `listing_observations` raw payloads | short window, per `data-model.md` §7 item 5 |
| quarantined payloads | short window |
| `ingest_epoch_keys` | one epoch, plus a 14-day grace (§4.2) |
| `device_activity` counters | rolling window sufficient for abuse detection |
| `device_reputation` counters | life of the install |

**Nothing here deletes an observation.** The key is what gets destroyed. The
listing corpus, `listing_changes`, and the batches themselves stay on their own
schedules — a batch keeps its `submitter_id` forever, and that value simply
stops meaning anything once the key is gone.

Deleting the key is the operation that makes the privacy claim true, so it
should be a scheduled job with its own alarm rather than a `TODO` in a cleanup
routine.

**Database backups bound the real date.** A key deleted from the live database
is still in every backup taken while it existed, so unlinkability actually
begins at *key deletion plus backup retention*. Nothing in the schema can fix
that. Either keep the keys in a store with its own short backup policy, or state
the true date as the longer of the two and stop describing it as immediate.

---

## 7. Open verification work

In priority order. The first decides what the `sellers` table contains.

1. **Pin the rest of the mobile signed-out seller block.** Name and rating are
   confirmed (§1.3). One probe run against mobile with no cookies should settle
   rating count, `Highly rated on Marketplace`, and join year in the same pass,
   and should record the field list rather than a summary — the field list is
   what the previous version of this claim was missing. All three are stored
   already, so this moves them from the second test to the first rather than
   unblocking anything.
2. **Confirm the sold-filtered query still works signed out.** The measurement is
   2026-08-07 and it is what puts the entire comparables corpus above the
   visibility floor (`filter-parameters.md` §10).
3. **Survey the signed-out mobile matrix**, which `data-model.md` §7 item 1
   already lists. This document adds a reason: mobile signed out is the surface
   that decides several `unverified` verdicts, and it has now decided two.
4. **Confirm the epoch grain and grace against real backup retention.** §4.2
   proposes one week plus fourteen days, chosen from §5.2's corroboration
   window. The number that can invalidate it is backup retention (§6): if
   backups are kept for ninety days, the grace is decoration until the keys live
   somewhere with its own policy.
5. **Tune the circuit breaker against real quarantine rates** (§3.3). It ships
   at 40% over six hours with a 200-card floor, and both are placeholders: the
   floor exists so three cards cannot switch off a working extractor, and the
   rate is a guess until there is traffic to measure.
6. **Merge an unresolved seller into a keyed one.** When a keyed capture finds
   the listing already pointing at an unresolved seller row, `resolveSeller`
   promotes that row if the key is free and otherwise repoints the listing,
   leaving the unresolved row behind. Both outcomes are correct; the second
   leaks a row nothing will ever join.
