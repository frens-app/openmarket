# Backend platform — database and API server

**Date:** 2026-08-10
**Supersedes:** the "What isn't decided" section of `apps/backend/README.md`
**Related:** `data-model.md`, `onboarding.md` §5, `logged-in-findings.md`
**Built:** `backend.md` records what shipped from this — the accounts layer only.
Of the open questions in §7, only 3 (phone visibility) is answered there; the
listing questions are all still open and were not prejudged.

The app is being rebuilt around accounts: phone login as a hard gate, Facebook
connect pushed hard on the next screen, push tokens stored, and users posting
listings we index ourselves. This is the record of what that does to the
backend choice.

Four constraints set before the evaluation started, and they do most of the work:

- **The backend is Go, with protobuf**, matching the other app.
- **"Connect with Facebook" means the WKWebView session, not the Graph API.**
  We log into the website and drive the user's account through it. No OAuth, no
  Meta app id, no Graph tokens on our server.
- **Listings posted in this app are native to us.** They are not cross-posted to
  Facebook. This is the constraint with the largest schema consequence (§5).
- **We are not hosting images yet.** Read as a phasing decision, not a permanent
  one — see §5 on why it has a short shelf life.

---

## 1. What the new requirements actually need

`apps/backend/README.md` leaned Convex, and the reasoning was sound for the
system it described:

> The access pattern is document-shaped (photo FBID → record, batch lookup, no
> joins worth the name).

That system no longer exists. Scoring what replaced it:

| New requirement | What it needs | Where it lands |
|---|---|---|
| Phone login | SMS OTP, rate limiting, fraud protection | Bought, not built (§3) |
| Facebook connect | Nothing server-side — it's a cookie jar on the device | **No backend implication at all** |
| Push tokens | A table and an APNs client | Free anywhere |
| Users post listings | Ownership, moderation state, draft reconciliation | §5 |
| **Server-side indexing** | Inverted index + vector index + geo, ranked together | **Postgres, decisively** |
| **LLM categorisation** | Durable queue, retries, rate limits, idempotency | Go's home ground (§4) |
| **Enriched search** | Hybrid lexical + semantic + distance in one ranked query | **Postgres, decisively** |

Search is the one that decides it. "Enriching search" concretely means a single
query that filters by distance, matches text, matches embedding, and ranks the
fusion of all three. In Postgres that's `tsvector` + `pgvector` + PostGIS in one
`SELECT`, with RRF in the `ORDER BY` — mature, `EXPLAIN`-able, and a well-trodden
path. Everything else on that list is portable across any of the candidates.

---

## 2. Choosing Go settles most of this

### It kills Convex outright

Convex is not a database you connect to. It's a TypeScript function runtime with
a database welded to it, and essentially all of its value — transactional
mutations, the scheduler, reactive queries — is only reachable from inside that
runtime. From a Go service you would either:

- write the backend in TypeScript after all, abandoning the Go/protobuf
  investment, or
- treat Convex as a dumb document store over HTTP, abandoning every property
  that made it the front-runner.

There is no third option. Combined with §1 — beta geospatial, action-scoped
vector search with equality-only filters — Convex is out, and the Go decision
alone is sufficient to retire it. Worth recording, because the earlier README
called it the leading option and this is what changed.

### It shrinks Supabase to "hosted Postgres"

My first pass recommended Supabase, and the two loads it was carrying were
Facebook identity-linking and image storage. You've removed both. What's left
that a Go service could use is phone OTP (GoTrue issues JWTs you can verify in
Go) and Realtime for hypothetical future messaging. That's real but thin — and
you'd pay for it with a second platform and a cross-provider hop on every query
from a Go service running on Railway. RLS, PostgREST, the client SDKs and Edge
Functions are all dead weight when the client talks to your own API.

Supabase is a good answer for a TypeScript app that wants a backend. You are a
Go app that already has one.

### It leaves Neon on the same footing as before

Branching is genuinely excellent and would make the schema churn ahead cheaper.
Against it: scale-to-zero's 300–500ms cold start lands in a mobile app's p99, so
you'd disable it and lose the pricing advantage; and you need compute on Railway
regardless, so you've bought a cross-provider hop for a Postgres that Railway
now also offers with HA. Take Neon only if per-PR database branching is a
workflow you'd actually adopt.

### Recommendation: Railway Postgres

Railway shipped [one-click HA Postgres on Patroni in March 2026](https://blog.railway.com/p/best-postgresql-hosting-2026)
— PITR, read replicas, pooling, pgvector and PostGIS available. Colocated with
the Go service on private networking, so no hop on the hot path. One bill, one
platform, the one you know.

The thing you're giving up versus Supabase is bought-in auth, and §3 buys it
back for less than the cost of the split.

---

## 3. Auth: a verification provider, not a home-grown OTP table

Phone login is the only identity the server has. Don't build it:
[Verify Fraud Guard](https://www.twilio.com/docs/messaging/features/sms-pumping-protection-programmable-messaging)
exists specifically because SMS pumping targets exactly this endpoint, and the
bill arrives before the alert does. Verify handles code generation, delivery,
expiry, attempt limits and fraud scoring behind one HTTP call — which is all a
Go service wants — and you keep your own `users` table and issue your own
session tokens.

One thing to start now rather than during integration:

- **A country allowlist, and a ceiling on total spend**, from the first commit.

> **Update (2026-08-10), third correction.** The provider is now **Prelude**,
> not Twilio. The reasoning in this section survives the swap intact — it argues
> for *buying* verification rather than building an OTP table, and every claim it
> makes about what the provider handles is equally true of Prelude, which does
> per-number limits, per-window check limits, ML scoring and allow/block lists of
> its own.
>
> Why: roughly 30% cheaper per US verification at list price, no per-environment
> service resource to create, and a `signals` parameter that takes the install id
> and platform, so its scorer can tell a real app install from a script walking a
> number range. Twilio Verify has no equivalent.
>
> The cost of the switch is recorded rather than glossed: **the 10DLC carve-out
> below is Twilio's, not Prelude's.** Prelude publishes no equivalent, and US
> carriers block unregistered A2P traffic outright. `backend.md` §5 carries the
> open question to settle with Prelude, and the sole-proprietor registration path
> if the answer is the unfavourable one. Twilio was briefly kept behind a
> `VERIFY_PROVIDER` switch as a hedge and then removed — a fallback nobody
> exercises is not a fallback, and the real mitigation is that `verify.Sender` is
> three methods.

> **Correction (2026-08-10), second of two.** This originally said "rate-limit by
> IP and by phone prefix, with a country allowlist." Verify does the first two
> itself — a built-in per-number limit, Service Rate Limits for IP, and Fraud
> Guard for pumping, which has cross-customer signal no single service can
> reproduce. Reimplementing them locally was duplicated work, and `backend.md` §5
> records what replaced it. What Verify genuinely cannot do is cap total spend,
> because every limit it enforces is per entity.

> **Correction (2026-08-10).** This section originally called US A2P 10DLC
> registration a launch blocker. That is wrong for the option it recommends.
> 10DLC governs bring-your-own-number Programmable Messaging; Verify manages the
> sender itself, and Twilio's
> [A2P 10DLC overview](https://www.twilio.com/docs/messaging/compliance/a2p-10dlc)
> says so directly — "if you're only using 10DLC numbers to send user
> verification text messages, you can use Twilio Verify rather than registering
> for A2P 10DLC." Skipping Brand and Campaign registration is a substantial part
> of what Verify is being bought for, and the original text argued against the
> choice it was making. What remains is Twilio's Messaging Policy and consent
> rules, plus the trial-account restriction to verified numbers.

**Forcing Facebook is an App Review risk worth avoiding anyway.** Guideline 4.8
governs third-party login. Since the Facebook step is a webview session rather
than a login provider you're probably outside its scope, but a hard wall in
front of the app is the version most likely to draw a reviewer's attention —
and `onboarding.md` §5 already argues on product grounds for a strong push with
a "Not now" rather than a gate. Nothing has changed that argument.

---

## 4. The API server: Go yes, protobuf yes, gRPC no

### Go over Node/TypeScript

The deciding factor is that you already run Go with protobuf on another app. A
second backend language on a small team is a permanent tax — two sets of idioms,
two dependency-update treadmills, two deploy shapes, and a person on call who
has to hold both. That tax needs an offsetting benefit, and there isn't one here.

**The one honest argument for TypeScript is the LLM ecosystem, and it is weak
for this specific shape of LLM work.** The argument holds when the work is
agentic or interactive: tool-use loops, token-by-token streaming into a UI,
agent frameworks. Your enrichment step is none of those — it is batch structured
extraction. A listing goes in, JSON matching a schema comes out, the row gets
updated. Anthropic's Go SDK
([`anthropic-sdk-go`](https://github.com/anthropics/anthropic-sdk-go)) is
official and generated from the same OpenAPI spec as the TypeScript one, so the
endpoints and features are the same. What TypeScript actually gets you is
ergonomics — a Zod schema straight into a typed parsed object — where Go passes
a raw JSON schema and unmarshals into a struct. That's boilerplate you write
once, not an architectural difference.

What Go wins on for *this* workload is more concrete than familiarity:

- **The enrichment pipeline is a concurrency problem** — rate-limited LLM fan-out
  over bursts of sightings, with backpressure, per-listing idempotency and cost
  caps. That is `errgroup`, channels, semaphores and `context` cancellation, and
  a long-lived Go process can host the job queue in-process (River, or
  pg-boss-shaped, straight onto the same Postgres) rather than needing a separate
  worker tier.
- **Bulk ingest.** Sightings arrive batched, one request per feed page.
  `pgx.CopyFrom` is dramatically faster than row-by-row inserts, and pgx is a
  better Postgres driver than anything in the Node ecosystem — real control over
  pooling, prepared statements and binary encoding.
- **Static binary, small image, fast cold start** on Railway.

### Use the Batch API for categorisation

Independent of language, and worth building the pipeline around from the start:
listing categorisation is not latency-sensitive. The
[Message Batches API](https://platform.claude.com/docs/en/build-with-claude/batch-processing)
runs asynchronously at **50% of standard price**, up to 100,000 requests per
batch, and most batches finish within the hour. Pair it with prompt caching on
the shared classification prompt — the instructions and category taxonomy are
byte-identical across every listing, which is the ideal cache prefix.

The design consequence: the enrichment queue should accumulate listings and
submit them in batches on a timer, not fire one request per listing as it
arrives. Reserve synchronous calls for the case where a user is watching — their
own listing, at post time.

### Protobuf, but for the IDL

Protobuf is also right, but for the **IDL**, not the transport. `data-model.md`
has ~40 fields on `listings` with nullability semantics that are explicitly
load-bearing, and hand-written Swift `Codable` structs drifting against
hand-written Go structs is how you reintroduce exactly the bug that document
warns about. One schema, two generated types, is worth the codegen step here.

The earlier README ruled out gRPC — "roughly three endpoints doesn't earn
HTTP/2 plumbing or a `protoc` step" — and the endpoint count has since gone from
three to twenty-odd. But the client-side half of that objection has, if
anything, gotten stronger. [gRPC-Swift 2](https://www.swift.org/blog/grpc-swift-2/)
is a real rewrite on Swift Concurrency, and it still means SwiftNIO, HTTP/2 and
your own TLS/ALPN stack — bypassing URLSession, and with it the system's
handling of cellular, proxies, ATS and background transfer. On a consumer app
whose whole hostile-network story today is WKWebView and URLSession, that's the
wrong trade.

**[Connect](https://connectrpc.com/docs/swift/using-clients/) is the middle that
fits.** One protobuf service definition; `connectrpc.com/connect-go` on the
server speaks the Connect protocol, gRPC and gRPC-Web from the same handler;
[connect-swift](https://github.com/connectrpc/connect-swift) is <200KB, stable
at 1.2.3 as of July 2026, and rides on URLSession. You keep the IDL and the
generated types, you can `curl` an endpoint while debugging, and you can turn on
real gRPC later for service-to-service without touching the app.

Start with the JSON codec over Connect and switch to binary proto if payloads
ever justify it. The schema is the value; the encoding is a tuning knob.

### One footgun, and it's the free-listings bug again

proto3 scalars are non-optional with a zero default. `price_minor = 0` is a
**valid, meaningful value** — `data-model.md` closes an open question
specifically to record that free listings exist and that any truthiness check on
price silently drops them. A plain `int64 price_minor` makes "free" and "unknown"
the same wire value, and the bug the docs warn about comes back through the
type system.

Mark **every** nullable column `optional` (proto3 field presence) so the
generated Swift is `Int64?` and the generated Go is `*int64`. Consider a lint in
CI: no bare scalar fields on the listing messages.

---

## 5. Native listings break the natural key

Listings posted here are ours, not cross-posted to Facebook. That settles the
open question this doc previously carried, and the answer is the expensive one.

`data-model.md` rests on one assumption, stated as such:

> A listing is identified by the Facebook photo ID of its cover image.
> `cover_photo_fbid text NOT NULL UNIQUE`

**A native listing has no Facebook photo.** The primary natural key of the entire
schema is undefined for the highest-value rows in the new product, and there is
no later moment where Facebook assigns one. This needs deciding before any DDL
runs, and it is independent of every other choice in this document.

The shape that survives:

```sql
ALTER TABLE listings
  ADD COLUMN source   text NOT NULL DEFAULT 'observed',  -- 'observed' | 'native'
  ADD COLUMN owner_id uuid REFERENCES users(id),
  ALTER COLUMN cover_photo_fbid DROP NOT NULL;

-- uniqueness applies only where the key exists
CREATE UNIQUE INDEX listings_cover_photo_fbid_key
  ON listings (cover_photo_fbid) WHERE cover_photo_fbid IS NOT NULL;

ALTER TABLE listings ADD CONSTRAINT listings_identity CHECK (
  (source = 'observed' AND cover_photo_fbid IS NOT NULL AND owner_id IS NULL)
  OR (source = 'native' AND owner_id IS NOT NULL)
);
```

**`listing_media` breaks in the same place**, and it's easy to miss:
`fb_photo_id text NOT NULL` with `UNIQUE (listing_id, fb_photo_id)` has no
meaning for a photo we host. That table needs the same nullable-key treatment
plus a storage key column.

The consequence worth thinking about beyond the DDL: the sighting write path's
never-regress rules exist because observed data is untrusted and partial. Native
listings are the opposite — the owner is authoritative, and a sighting must never
touch them at all. `source = 'native'` should be a **hard exclusion** on the
sighting upsert, not another `COALESCE`. Getting that wrong means a scraped card
that happens to collide can overwrite a real user's own listing.

Two more things follow from ownership that the observed corpus never needed:
**moderation state** (native listings are content you host and are responsible
for) and **deletion that actually deletes** (an owner removing their listing is
a different operation from a scraped listing going stale).

### Image hosting has a shorter shelf life than "not yet" implies

Taking "not yet" as a phasing decision. It's the right call for sequencing and
the wrong one to design around, because **a marketplace listing without a photo
is not a viable listing** — hosting arrives roughly the moment posting ships, not
some quarter later.

Two things to do now, both cheap:

1. **Pick the blob store, even if you don't turn it on.** For an image-heavy
   marketplace, egress is the cost line that scales with success rather than
   with data volume, and **Cloudflare R2 charges none**. That is worth more here
   than any database feature in this document. Decide it now so the media table
   and upload path are shaped for it.
2. **Put the storage key in the schema with the rest of the media changes**, so
   turning hosting on is a feature flag rather than a migration on a live table.

This also connects to an existing to-do: `status.md` records that fbcdn URLs
expire in ~107 hours and that saved cards need cached image bytes. That is the
same piece of work as hosting native photos — one storage layer, two callers.

---

## 6. Where this leaves the stack

| | Choice | Because |
|---|---|---|
| Database | **Railway Postgres** (HA) | Hybrid search + geo; colocated with Go; one platform |
| API | **Go + Connect RPC** | Existing investment; protobuf IDL without gRPC's client cost |
| Auth | **Prelude Verify** + own `users` table | Fraud protection is the whole product; keep the identity |
| Queue | **In-process, Postgres-backed** | No second tier until it earns one |
| LLM | **Batch API + prompt caching** | Categorisation isn't latency-sensitive; 50% off |
| Images | **Deferred, but decide on R2 now** | Zero egress; schema shaped for it up front (§5) |
| Realtime | **Deferred** | Messaging isn't now; Go + WebSockets when it is |

Nothing here is a one-way door except the protobuf IDL, and that one you've
already walked through on the other app.

---

## 7. Open questions

1. **Do native and observed listings share one index and one ranking**, or are
   they separate surfaces the app interleaves? Decides whether §5's `source` is a
   filter or a partition, and it changes the search implementation materially.
2. Do LLM-improved titles get re-embedded? Categorisation rewrites the text the
   embedding was built from, so the enrichment job has to invalidate the vector.
3. Is the phone number login-only, or visible to buyers? Different retention,
   different disclosure, and it's easier to decide before the first row.
4. Does the sighting write path stay anonymous now that there's a principal?
   Attributing sightings to users makes abuse control much easier and makes the
   corpus personally identifiable. `data-model.md` chose `devices` deliberately
   to avoid exactly that; accounts don't automatically overturn the reasoning.
5. What is the moderation posture on native listings? You now host user content,
   which is a different liability shape from indexing someone else's.
