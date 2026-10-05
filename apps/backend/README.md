# Backend

Go + Connect RPC + Postgres. Accounts, phone login, Price Check, and AI Search.

**Full write-up: [`docs/backend.md`](../../docs/backend.md).** The platform
evaluation that led here is [`docs/backend-platform.md`](../../docs/backend-platform.md).

## Run it

Once, to create your local config, then put a real Prelude API key in it:

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

The server **refuses to boot without a Prelude key, in development too.** Nothing
is defaulted in quietly: that is what keeps dev running the same code production
does. The panic names the `cp` above.

**There is no local substitute for Prelude and no base-URL override.** Dev talks
to the real API, and what keeps that free is `DEV_BYPASS_PHONE_NUMBERS`:

- **`*`**, which development ships with. Every number is intercepted in-process
  by `verify.BypassSender`: type any number, then the dev code (`123456`, or the
  **Skip verification (dev)** button on each step). Nothing is sent, nothing is
  billed, and Prelude's per-number rate limit never applies.
- **explicit E.164 numbers**, which bypasses only those and sends a real,
  **billed** text to anything else. Use it to confirm the provider path works.

The code is checked either way, so a wrong one is still rejected.

```bash
make generate     # protobuf (Go + Swift) and sqlc, from /protos
make ci           # buf lint, go vet, go test, gofmt
```

## What's here

```
cmd/api/          main, RPC handlers, interceptors, Dockerfile
pkg/auth/         JWT signing, refresh-token hashing, request context
pkg/phone/        E.164 normalisation and the country allowlist
pkg/verify/       Prelude Verify client, and a bypass that wraps rather than
                  replaces it
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

Jev uses `AI_GATEWAY_API_KEY`, falling back to `LLM_API_KEY` when
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

The stub is refused under `ENV=production`, exactly like
`DEV_BYPASS_PHONE_NUMBERS`, and for the same reason: it is the one configuration
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

Two files are worth reading before changing anything in here:

- `cmd/api/ratelimit.go` — why `StartPhoneVerification` has exactly one local
  limit and not four. Per-number limiting and pumping detection are the
  provider's, and better than ours; what it can't do is cap total spend, because
  every limit it enforces is per entity.
- `cmd/api/auth_interceptor.go` — `skipAuth` is an allowlist, so a new RPC is
  authenticated by default and opening one up is a visible edit.

## Configuration

`.env.development` is committed and holds dev-only values. Real credentials go in
`.env.local` — see `.env.local.example`, which documents every variable and is
also the list the Railway service needs.

The server refuses to boot rather than come up misconfigured: a missing signing
key or Prelude key, an empty country allowlist, `JWT_SECRET` equal to
`REFRESH_TOKEN_HMAC_KEY`, or `DEV_BYPASS_PHONE_NUMBERS` left set with
`ENV=production` are all panics. That last one is the only way a code is accepted
without Prelude having sent it, which is why it is the only override guarded.

## AI Search

`ShoppingService` runs an authenticated, temporary shopping conversation. Both
Openmarket and the device's reported Facebook connection are required. Configure
`AI_GATEWAY_API_KEY` (or `LLM_API_KEY` with `LLM_PROVIDER=vercel`) and optionally
`SHOPPING_MODEL`, which defaults to `google/gemini-3.5-flash-lite` for faster
tool selection, using the model's default minimal thinking level. AI Search uses the
Gateway independently of Price Check's configured identification provider. Missing
credentials disable AI Search explicitly; there are no fabricated shopping results.

The phone executes search, inspection, and display actions. Jev evaluates search
cards against the broad query only; the conversation model evaluates full user
requirements after receiving parsed details. See [the spec](../../docs/ai-search.md).

Sessions expire after 30 minutes without client activity and are lost on process
restart. Use one backend replica for this first version; multiple replicas need
session affinity. No chat tables are created. Migration 00014 adds only the
`SHOPPING` model-accounting stage; existing usage ceilings include these calls.
Tool responses are capped at 256 KB before processing, and each Jev batch at 30
candidates. The model has at most five planning calls plus a closing response restricted to
display or text, two source-page actions and three inspections per user message.
Retrieval stops after 60 seconds; displaying existing evidence remains possible.
Successful product display finishes the run without another model call. Repeated
identical pages and repeated inspections within a run are rejected.

Run `go test -race ./cmd/api ./pkg/llm` for the scripted frontend/tool loop, account
isolation, pagination binding, cancellation, filtering failure, and Gateway tests.
These tests use synthetic provider responses and do not spend model credits.
