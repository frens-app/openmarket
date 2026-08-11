# Backend

Go + Connect RPC + Postgres. Accounts and phone login; nothing else yet.

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

Starts Postgres in Docker and runs the API on `:8080`. The server applies
migrations at boot, so that is the whole setup.

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

`pkg/llm` has a **stub provider**, and it is the whole local-development story
for Price Check: `.env.development` ships `LLM_PROVIDER=stub`, which answers
in-process with no key, no network and no bill. The feature runs end to end
against it — including the recording — so the iOS side can be built and re-run
without spending anything. Point it at Gemini by setting `LLM_PROVIDER`,
`LLM_API_KEY` and `LLM_MODEL` in `.env.local`.

The stub is refused under `ENV=production`, exactly like
`DEV_BYPASS_PHONE_NUMBERS`, and for the same reason: it is the one configuration
that returns an answer nothing generated, and a price built on it would look
exactly like a price.

Every model call writes an `llm_runs` row — including the failures and each
retry — carrying the provider, the model that actually served it, and the token
counts. **There is no cost column.** Cost is a function of those counts and the
model id, so it can be computed retroactively once a rate table exists; a token
count that was never written down is gone. See migration `00004`, and `00005`
for why reasoning tokens get their own column.

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
