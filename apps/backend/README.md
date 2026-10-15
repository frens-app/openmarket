# Backend

Go + Connect RPC + Postgres. Accounts, Apple/Google/phone login, seller follows, Price Check, and AI Search.

**Full write-up: [`docs/backend.md`](../../docs/backend.md).** The platform
evaluation that led here is [`docs/backend-platform.md`](../../docs/backend-platform.md).

## Run it

Create local config and add your Prelude API key. Apple/Google setup is documented
in [provider setup](../../docs/social-login.md):

```bash
cp apps/backend/.env.local.example apps/backend/.env.local
```

Then, from the repo root:

```bash
make dev
```

Starts Postgres in Docker on host port `5433` (container port `5432`) and runs
the API on `:8080`. This leaves the default Postgres port free for other projects.
The server applies
migrations at boot, so that is the whole setup.

It also asserts a Tailscale Serve mapping on the way past, which is what lets a
physical iPhone reach this API over https — see
[apps/ios/README.md](../ios/README.md). It's a no-op once registered, and it
never fails the target: with Tailscale absent or signed out you get a note and
the API starts anyway, since Simulator work doesn't need it.

Phone login and signup continue through Prelude during the transition. The country
allowlist, SMS controls, accounts and sessions are preserved. Apple/Google can be
configured later; missing social provider settings do not block the phone service.
Apple revocation credentials are required when Apple login is enabled in production.

```bash
make generate     # protobuf (Go + Swift) and sqlc, from /protos
make ci           # buf lint, go vet, go test, gofmt
```

## What's here

```
cmd/api/          main, RPC handlers, interceptors, Dockerfile
pkg/auth/         JWT signing, refresh-token hashing, request context
pkg/identity/     Apple/Google ID-token verification and Apple grant revocation
pkg/llm/          Price Check's model calls, and the record of what they cost
pkg/config/       flags → environment → .env files
pkg/db/           sqlc output — generated, do not edit
deployments/      migrations (goose), queries (sqlc), compose, railway
```

`pkg/llm` identifies the seller's item before search and evaluates candidate
relevance afterwards. `EvaluateComparables` uses Jev through Vercel's
`POST /v1/evaluate`, with one boolean question per candidate and a fixed target.
The phone computes all prices and sold-time statistics from accepted listings.
Rejected results remain visible at the end of the evidence carousels.

Comparison relevance uses `AI_GATEWAY_API_KEY`, falling back to `LLM_API_KEY` when
`LLM_PROVIDER=vercel`. Google identification can therefore coexist with Jev by
setting a separate gateway key. Missing credentials disable relevance checks
with an explicit error; the identification stub never fabricates relevance.
The comparison endpoint requires an OpenMarket account, accepts at most 30
candidates, uses a 10-second per-attempt deadline, and shares the existing model
call ceiling. Migration 00013 adds `RELEVANCE` to `llm_runs`; each attempt records
model, token usage and latency without storing candidate text.

The initial acceptance probability is 0.8. This is a conservative starting
policy, not a measured accuracy guarantee; validate it on labeled Marketplace
pairs before tuning. Candidate descriptions are sent only when already loaded.
Jev receives text and condition, not photos or numeric prices. A failed or
incomplete evaluation stops the comparison instead of using unfiltered prices.

`.env.development` ships `LLM_PROVIDER=stub` for item identification, which
answers in-process with no key or network. Relevance still needs the gateway
key above; unit tests use synthetic gateway responses without spending money.
For an opt-in billed smoke test using synthetic listings, run
`JEV_LIVE_API_KEY=… go test ./pkg/llm -run '^TestJevLive$' -v -count=1`.

Two real providers sit behind the same interface, chosen with `LLM_PROVIDER` in
`.env.local`:

| | `vercel` | `google` |
|---|---|---|
| Route | AI Gateway, OpenAI Chat Completions surface | Gemini's Interactions API |
| Model | `google/gemini-3.6-flash` — vendor-prefixed | `gemini-3.6-flash` |
| Why | one key for every model, one invoice to reconcile `llm_runs` against | one fewer hop, and a free tier |

Item identification uses the Gateway’s Chat Completions surface because the point of a gateway is
changing models without changing code, and that is the shape every model behind
it maps onto. It carries what this package needs: JSON-Schema structured output,
and reasoning tokens reported separately. The one gap is that its `reasoning`
object does not reach Anthropic's `output_config` on Claude Opus 4.7 and later —
irrelevant here, since nothing configures reasoning, but it is the reason to add
an Anthropic Messages provider beside this one rather than bend it.

The stub is refused under `ENV=production`: it is the one configuration
that returns an answer nothing generated, and a price built on it would look
exactly like a price.

Every model call writes an `llm_runs` row — including the failures and each
retry — carrying the provider, the model that actually served it, and the token
counts. **There is no cost column.** Cost is a function of those counts and the
model id, so it can be computed retroactively once a rate table exists; a token
count that was never written down is gone. See migration `00004`, and `00005`
for why reasoning tokens get their own column — and for the measured answer to
the question that column was opened for.

Two things worth knowing before anyone writes that rate table. The Gateway
*does* return a cost, in `usage.cost` and `usage.cost_details` — recomputing
from tokens is a fallback, not the only route. And with a BYOK provider key attached
to the Gateway, `cost` is `0` and the real number is `market_cost`: the spend is
on Google's invoice, not Vercel's, so a dashboard reading `cost` reads zero
while the money is being spent somewhere else.

A failed call leaves two records, and they say different things. `error_code`
in the row is the category, which is what you query; the provider's own words go
to the log beside it at `warn`, because "the schema was rejected" and *which
field* it rejected are not the same fact, and only the column-sized one fits in
a column. `bad_request` and `refused` look adjacent and are opposites: the first
is our request being wrong and every user hits it at once, the second is the
model declining this item and rewording it may help.

Three tables, three lifetimes: `users` (the account), `user_devices` (one app
install — where the Facebook connection and the APNs token live), `user_sessions`
(one sign-in). `docs/backend.md` §4 explains why the middle one has to exist.

`cmd/api/auth_interceptor.go` makes RPCs authenticated by default. Only sign-in
and token refresh are public. See `docs/social-login.md` for token verification
and the additive migrations that preserve existing phone accounts.

## Configuration

`.env.development` is committed and holds dev-only values. Real credentials go in
`.env.local` — see `.env.local.example`, which documents every variable and is
also the list the Railway service needs.

The server refuses missing session signing keys, equal access/refresh keys, and
incomplete production identity-provider settings.

## Experimental search result filtering endpoint

`SearchService.FilterListings` exposes the image filter for explicit experiments. The iOS
Search screen does not call it. Configure `JEV_API_KEY` in `.env.local` or the
deployed backend environment. This calls TypeSafe directly with `jev-1.14.0` and
its image header. AI Search shares this image-filter runner; Price Check relevance and the AI Search conversation model use their existing Gateway paths.

The authenticated endpoint accepts a query and up to 20 search cards containing
only an ID, title, and headline photo URL. It downloads Facebook CDN thumbnails
with four workers and a two-second total image budget, bounds decoding, and
resizes/pads to Jev-compatible JPEGs. It returns match, unknown, or mismatch
decisions; missing photos produce unknown decisions. Model failures return an
error for the caller to handle. A five-second model-run deadline includes image preparation, with no
retries. Existing per-user model limits and `llm_runs` usage recording apply.

The withdrawn Search UI prototype, accuracy/cost measurements, and lessons about
repeated live evaluations are preserved in the
[research findings](../../tools/probe/jev_filter/README.md).

The optional billed smoke harness exercises the production image downloader and
provider against a frozen research dataset. From `apps/backend`, run
`go run ../../tools/probe/jev_filter/smoke.go ../../build/jev-research/dataset-0.json`.
It reads only `JEV_API_KEY` from `.env.local`; frozen datasets are local research
artifacts, not committed fixtures. Normal unit tests make no paid requests.

## AI Search

`ShoppingService` runs an authenticated, temporary shopping conversation. Both
Openmarket and the device's reported Facebook connection are required. Configure
`AI_GATEWAY_API_KEY` (or `LLM_API_KEY` with `LLM_PROVIDER=vercel`),
`JEV_API_KEY` for direct image relevance, and optionally
`SHOPPING_MODEL`, which defaults to `google/gemini-3.5-flash-lite` for faster
tool selection, using the model's default minimal thinking level. AI Search uses the
Gateway independently of Price Check's configured identification provider. Missing
credentials disable AI Search explicitly; there are no fabricated shopping results.

The phone executes search, inspection, and display actions. The backend sends
card titles and headline photo URLs through the shared direct `jev-1.14.0` image
filter against the search query. Match and unknown decisions are retained; only
clear mismatches are removed. Missing photos remain unknown. The conversation
model receives each retained card's verdict and image-use flag, then evaluates
full user requirements using parsed details. A failed model batch reports an
error for the whole page; it never supplies a partially filtered page. See [the spec](../../docs/ai-search.md).

Sessions expire after 30 minutes without client activity and are lost on process
restart. Use one backend replica for this first version; multiple replicas need
session affinity. No chat tables are created. Migration 00014 adds only the
`SHOPPING` model-accounting stage; existing usage ceilings include these calls.
Tool responses are capped at 256 KB before processing, and each Jev batch at 20
candidates, with a five-second deadline and no automatic retry per image-filter batch.
The model has at most five planning calls plus a closing response restricted to
display or text, two source-page actions and three inspections per user message.
Retrieval stops after 60 seconds; displaying existing evidence remains possible.
Successful product display finishes the run without another model call. Repeated
identical pages and repeated inspections within a run are rejected.

Run `go test -race ./cmd/api ./pkg/llm` for the scripted frontend/tool loop, account
isolation, pagination binding, cancellation, filtering failure, and Gateway tests.
These tests use synthetic provider responses and do not spend model credits.

## Seller profiles and follows

Migration `00019` adds `facebook_sellers`, keyed by the Facebook profile ID,
and `seller_follows`, keyed by `(user_id, seller_id)`. The profile stores the
name, current profile image URL, Facebook join text, rating, rating count, and
highly-rated badge. Optional fields remain nullable; partial uploads preserve
previously known values. Explicit zero counts and false badges are retained.
No seller locations, Facebook credentials, image binaries, or individual review
texts are stored. Join text is kept as displayed rather than converted into an
invented exact account-creation date. These are device-reported observations,
not verified Facebook records; supplied fields use the latest received value.

All `SellerService` RPCs require an OpenMarket session. They do **not** require a
Facebook login, device row, or reported Facebook connection:

- `POST /openmarket.api.v1.SellerService/UpsertSeller` accepts `seller` with its
  numeric-string `id`, `name`, and optional profile fields.
- `POST /openmarket.api.v1.SellerService/SetSellerFollow` accepts `sellerId` and
  `following`. Following also requires a matching `seller`; the profile and
  follow are written in one transaction. Unfollowing needs only the ID.
  Repeating either desired state is safe. The user comes from the session.
- `POST /openmarket.api.v1.SellerService/ListFollowedSellers` returns up to 100
  profiles and `nextAfterId`; send it as `afterId` until it is empty.

The iOS app uploads seller fields encountered in listing details and seller
profiles. Follow/unfollow updates the local list immediately, then sends the
desired state to the API. Each account has its own persisted cache and pending
changes. Failed synchronization retries after 30 seconds and on foreground or
opening Following; a status message indicates unsynced changes. Legacy/device-only
follows are imported into the first OpenMarket account once. Account deletion
removes its follows without removing shared seller profiles.

Seller inventory browsing still uses the existing Facebook sign-in flow;
storing profiles and managing follows are independent of that browsing access.

To exercise the migration, authorization, partial updates, pagination, and account
deletion against a disposable Postgres database (name must end in `_seller_test`):

```bash
cd apps/backend
SELLER_TEST_DATABASE_URL=postgres://…/example_seller_test go test ./cmd/api -run '^TestSellerIntegration$' -count=1 -v
```

The iOS `FollowedSellersTests` and `SellerSyncTests` cover local persistence,
migration, offline retries, rapid toggles, reads racing changes, and account isolation.

## Saved listings

Migration `00020` adds `listings` (our UUID plus a unique Facebook listing ID)
with a validated `SavedListingSnapshot` JSON payload, and `saved_listings`
keyed by `(user_id, listing_id)` with `saved_at`. Shared metadata survives an
unsave and account deletion. Sold/unavailable listings remain saved until removed.
There is no observation-history table. `field_observed_at` tracks freshness for
individual fields, including seller fields: missing values preserve known data,
newer supplied values replace old ones, and false/zero remain meaningful. Read
snapshots report conservative group observation times so re-uploading restored
data cannot make a retained older field appear fresh.

Both `SavedListingService` RPCs require an OpenMarket account, independently of
Facebook login or device registration:

- `ApplySavedListingChanges` accepts 1–50 ordered changes. Each has a UUID
  `mutation_id`, a `facebook_listing_id`, and optional `saved`. `true` saves with
  a matching snapshot and `saved_at`; `false` removes without a snapshot; absent
  `saved` refreshes metadata without changing bookmark membership. Entries have
  independent transactions and validation results. A transient request failure
  can follow committed entries, so retry the same frozen mutation IDs/payloads.
- `ListSavedListings` returns up to 100 records with metadata, internal UUID,
  `saved_at`, and `next_after_id`. Pagination uses Facebook ID, while clients
  display by `saved_at` descending. Finish all pages before replacing local state.

`saved_listing_mutations` stores only account-scoped mutation IDs and request
hashes, not user observation history. Receipts remain until account deletion so
an old retry cannot resurrect a bookmark removed after that mutation committed.
Reusing a mutation ID with different contents is rejected. Newly accepted changes
use server processing order across devices; client clocks do not decide conflicts.
Observation/save timestamps must be from 2004 onward and no more than five minutes
in the future. Account deletion removes bookmarks and receipts under the same user
row lock used by writes.

On iOS, resolved cards use `fb:<Facebook listing ID>` for identity, including guest
GraphQL and desktop DOM cards. Photo FBIDs remain optional snapshot metadata.
Saved snapshots and pending mutations are persisted together, separately for each
account and guest use. Sign-in claims guest saves once. The old `savedListingIDs`
array migrates using cached item URLs; duplicates collapse, order is preserved
using import timestamps, and unresolved legacy entries remain visible locally.
Entries without cached metadata also remain local; item GraphQL can recover their
title when opened. Placeholder UI text is never uploaded as a Facebook title.
New unresolved mobile DOM cards must resolve their item URL before saving.
Saved renders from its own persisted data, independent of browsing-cache eviction.

Sync runs after changes, sign-in, foregrounding, opening Saved, and a 30-second
retry after transient failures. Permanent per-entry errors preserve the local save
and show a status message; refreshing the listing can repair a rejected save.

Validation:

```bash
SAVED_LISTING_TEST_DATABASE_URL=postgres://…/example_saved_listing_test \
  go test -race ./cmd/api -run 'TestSavedListingIntegration|TestListingMerge|TestListingChange' -count=1
```

The database must be disposable and its name must end in `_saved_listing_test`.
`SavedListingSyncTests` covers migration, account isolation, offline removals,
lost acknowledgements, in-flight edits, metadata-only refresh, and fresh-device
restoration. Snapshot URLs can expire; sync retains metadata, not image binaries.

### Listing views

`POST /openmarket.api.v1.ListingViewService/SubmitListingView` records an item
open, independently of saving it. Send `facebook_listing_id` and `viewed_at`;
a successful live read also sends `snapshot` and `source`. The iOS detail screen
submits the click immediately, then the refreshed snapshot after extraction.
Uploads run independently of screen dismissal; failures are logged and are not
currently queued for offline retry. Unresolved mobile cards submit once their
Facebook listing ID is known.

An authenticated OpenMarket account is required. Guest browsing never submits
views. The server derives `listings.last_viewed_by` from the verified session;
`last_view_received_at` determines the latest view, while `last_viewed_at` retains
the client clock time for that submission. Client clock skew cannot stop a later
received view from becoming the latest. Facebook authentication is separate from
OpenMarket account authentication: a signed-in app user may fetch Facebook data
without a Facebook session.

`last_detail_updated_by` identifies the account that last submitted an accepted
snapshot, independently of the latest viewer. `last_detail_received_at` determines
which submission is latest; `last_detail_observed_at` retains its client clock
time. `last_detail_source` distinguishes anonymous/authenticated Facebook GraphQL,
desktop page, and mobile page extraction. These describe the overall submission,
not individual fields. Existing per-field observation timestamps still protect
newer values from older cached fields, and missing values preserve prior facts.
Account deletion clears both viewer and data-submitter attribution.

The endpoint neither saves a bookmark nor appends view history. Contents, source,
and client observation times are client-reported, not independently verified.
