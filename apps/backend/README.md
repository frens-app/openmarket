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
to the real API, so two ways to sign in and the difference matters:

- the **Skip verification (dev)** button on the login screen, which uses the
  reserved test number on `DEV_BYPASS_PHONE_NUMBERS`. Handled in-process by
  `verify.BypassSender` — nothing is sent and nothing is billed.
- **any other number**, which sends a real text message and is billed.

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
pkg/config/       flags → environment → .env files
pkg/db/           sqlc output — generated, do not edit
deployments/      migrations (goose), queries (sqlc), compose, railway
```

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
