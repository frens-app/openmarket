# The backend, as built

**Date:** 2026-08-10
**Code:** `apps/backend`, `protos/openmarket/api/v1`, `apps/ios/Sources/Account`
**Decision record:** `backend-platform.md` — this document is what came of it

`backend-platform.md` evaluated the platform. This is the narrower record of
what actually shipped and why the scope is what it is.

---

## 1. Scope: accounts, and nothing else yet

The server owns **users, sessions, Apple/Google login, and push tokens**. It does not
index listings, does not accept sightings, and does not run search. All of that
still happens on the device, exactly as `feasibility-2026-07-31.md` describes.

This is a deliberate first slice, and it is worth being explicit about the
reason: the schema for listings is the part with real open questions on it
(`backend-platform.md` §5 — the natural key breaks for native listings), and the
account layer has none. Shipping identity first means the hard schema decisions
get made against a system that is already deployed and already has a principal
to hang ownership off, rather than in the abstract.

What that buys immediately:

- A stable user id, which is what listing ownership, moderation and abuse
  control all need before they can be designed.
- A device install identity (§4), which is where Facebook connection and push
  tokens live.
- Onboarding state on the account rather than in `UserDefaults`, so a reinstall
  doesn't repeat it.

What it explicitly does not change: the app still browses Facebook through
WKWebView, and the Facebook session in `SignInView` is untouched. **Those are two
unrelated sign-ins** and the code says so in both places, because they were easy
to confuse when there was only one of them.

---

## 2. Layout

```
protos/openmarket/api/v1/     the schema — one source, two generated types
buf.gen.yaml                  Go → apps/backend/pkg/protos
                              Swift → apps/ios/Packages/OpenMarketProtos
apps/backend/
  cmd/api/                    main, handlers, interceptors, Dockerfile
  pkg/auth/                   JWT signing, refresh-token hashing, context
  pkg/identity/               Apple/Google token verification and Apple revocation
  pkg/config/                 flags → env → .env files
  pkg/db/                     sqlc output (generated)
  railway.toml                deploy config (see §8 — its path is load-bearing)
  deployments/
    migrations/               goose
    queries/                  sqlc input
    compose.yml               local Postgres
apps/ios/Sources/Account/     Keychain, install identity, Connect client,
                              AccountSession
apps/ios/Sources/UI/AccountLoginView.swift
```

Two things about this shape are load-bearing.

**`protos/` is at the repo root, and one `make generate` writes both sides.**
The whole argument for a protobuf IDL is that hand-written Swift `Codable`
structs cannot drift from hand-written Go structs, and that only holds if
regenerating both is a single step nobody can half-do. The Swift package is
local, not versioned, for the same reason — pinning it would reintroduce the
drift.

**`deployments/` lives under `apps/backend`, not at the root.** The Docker build
context is `apps/backend`, so the iOS app, the probe harness and ~55MB of Xcode
output never enter it. Railway's root directory is set to `apps/backend`.

---

## 3. The auth flow

Apple and Google native sign-in are exchanged for app sessions. See
[social-login.md](social-login.md) for provider setup, nonce validation,
account deletion, retired phone login, and linking existing phone accounts.

### Sessions

- **Access token**: HS256 JWT, 30 minutes, carrying `sub` (user) and `sid`
  (session).
- **Refresh token**: 32 random bytes, one year, and **only its HMAC is stored**.
  A database dump is therefore not a set of usable credentials.
- **Every authenticated call checks the session row**, not just the signature.
  That is what makes revocation immediate: `Logout` and `DeleteAccount` take
  effect on the next request rather than whenever the access token expires. It
  costs one indexed lookup per call and it is the reason the access token can be
  short-lived.
- **Refresh rotates.** `RotateRefreshToken` is a conditional `UPDATE` on the old
  hash, which is also the concurrency control: two clients racing a refresh with
  the same token both run it, exactly one matches a row, and the loser is told
  to re-authenticate rather than both being handed live sessions.

The client mirrors this in `AccountSession`: one in-flight refresh at a time,
awaited by every concurrent caller, because two simultaneous refreshes would
leave the loser holding a token the server has already retired.

`access_token_expires_in_seconds` is on the wire so the client never parses our
JWT. The token's internals are the server's business, and a client that reads
them is a client that breaks when the claims change.

---

## 4. Devices, and why the Facebook connection lives on one

There are three lifetimes here, not two, and the Facebook connection is what
makes the third one obvious.

| | Lives as long as | Example |
|---|---|---|
| User | The account | Provider identity, display name, onboarding |
| **Device** | **The app install** | **Facebook connection, APNs token** |
| Session | One sign-in | Refresh token, revocation |

"Connect with Facebook" in this app is a **WKWebView cookie jar**, not an OAuth
grant — `backend-platform.md` fixes that as constraint 2. A cookie jar lives in
one app container on one phone. It does not travel to a second device, it does
not survive a reinstall, and no amount of signing into the account elsewhere
reproduces it.

So `facebook_connected` on `users` would assert something false the moment
someone picks up a second phone: the server would believe they were connected
while the app in their hand had no cookies and no way to get them without asking
again. It belongs on `user_devices`, and that is where it is. The separate
`users.facebook_last_connected_at` records historical connection across installs;
NULL means none recorded. It advances on connection transitions and remains on
disconnect. It must not be used to decide whether this device needs Facebook login.

An install identifies itself with a client-generated `install_id`, sent **only on
`SignIn`**. The session records which device it belongs to, so every later
call derives the device from the session — a client cannot report about an
install it did not sign in from, because it never names one.

The id is kept in the **keychain beside the session tokens**, which makes the
lifetimes line up exactly: lose the id and you have lost the cookie jar too, so a
fresh row starting at `facebook_connected = false` is the correct answer rather
than a lost one. Not `identifierForVendor` — that survives a reinstall, which is
precisely the property we don't want.

`SetFacebookConnection` takes the client's word for it, because the client is the
only thing that can observe the state. That is fine for what the flag is for —
deciding whether to prompt on this device — and it is emphatically not an
authorisation input. Nothing treats it as one.

The client reports when it detects the session, deduped
against what the server last returned so the common foreground costs nothing:

- **After app-account sign-in or restoration**, including Settings sign-in, to
  associate an existing browser session with the current app account.
- **Every foreground** (`scenePhase == .active`) — the only place that notices a
  session lapsing on its own, through an expiry or a password change elsewhere.
- **After the Facebook sign-in webview completes.**
- **After Facebook sign-out** — the transition nothing else watches, since the
  completion handler only fires on sign-*in* and the scene phase never changes.

A failed report deliberately leaves the local copy alone, so the next foreground
retries rather than the app concluding it has already told us.

### Push tokens live here too, and only the token

An APNs token is opaque per app install, which is this table's grain rather than
a session's. On `user_sessions` it would be dropped every time somebody signed
out and back in on the same phone.

**What is deliberately *not* stored: the APNs topic and the sandbox/production
environment.** Both are constants of a deployment, not facts about a row — this
service serves one bundle id, from builds in one APNs environment — so a column
for either stores the same value on every row. They belong in the sender's
config, and the sender does not exist yet.

The first version of this table had both, copied from a service that does send
pushes rather than derived from what this one needs. The giveaway was that the
only code reading `apns_bundle_id` was a check rejecting any value that didn't
match the `APNS_BUNDLE_ID` config — the server asserted the column was a
constant, then stored the constant.

The case that brings the environment back is a staging backend serving TestFlight
builds (production tokens) and Xcode builds (sandbox tokens) at once. Add the
column then: a device re-registers its token on launch, so there is no history to
reconstruct. Until then a mismatch would surface as `BadDeviceToken` on send,
which is detectable and prunable.

Because nothing had been deployed, this was fixed by editing `00001` and `00003`
in place rather than adding a fourth migration — which also let `00001` stop
creating push columns on `user_sessions` only for `00003` to remove them.

---

## 5. Sign-in controls

The backend verifies provider signatures, issuer, audience, expiry and a
single-use nonce bound to provider and install. Challenges expire in five minutes
and are pruned every minute. Configure edge rate limits for public sign-in routes.
The phone verification endpoints now return a retired-sign-in error without
sending SMS or issuing sessions, including to older clients. Existing phone
sessions can link Apple/Google without changing the user ID; see
[social-login.md](social-login.md#linking-existing-phone-accounts).

## 6. Account identity

Accounts are keyed by provider and stable subject, never by email. Apple and
Google identities remain separate unless a signed-in phone account explicitly
links an unused provider identity. Linking preserves the user ID and analytics
identity; existing accounts are never merged. DeleteAccount releases the identity, revokes
app sessions and removes saved price checks. Apple deletion also revokes the
provider grant after reauthorization; see `social-login.md`.

## 7. Local development

```bash
cp apps/backend/.env.local.example apps/backend/.env.local
make dev
```

Starts Postgres in Docker — the only thing there is to start — then runs the
API. The server applies migrations itself at boot, so there is no separate
migration step and the schema can never be older than the code that expects it.

Configure providers in `.env.local` following [social-login.md](social-login.md).
`make dev` starts Postgres and the API. The API applies migrations on startup.
Development can boot without Google or Apple signing keys, but those provider
operations stay unavailable until configured. No sign-in bypass is provided.

## 8. Deploying to Railway

Two settings in the Railway UI, and neither can be expressed in the config file:

| Setting | Value |
|---|---|
| Root Directory | `apps/backend` |
| Config file path | `/apps/backend/railway.toml` |

**The second one is the trap.** Railway's config file
[does not follow the Root Directory setting](https://docs.railway.com/config-as-code)
— it is looked up from the repository root unless given an absolute path. Leave
it unset and `railway.toml` is ignored *silently*: Railway doesn't fail, it falls
back to auto-detection, builds something out of a repo whose root is an Xcode
project, and brings it up with no healthcheck and no restart policy.

`apps/backend/railway.toml` then supplies the Dockerfile build, the `/health`
healthcheck (which pings the pool, so a container that has lost its database is
replaced rather than left serving errors), the restart policy, and watch patterns
that keep the iOS app from triggering deploys.

**Provision Postgres 18 or newer.** `uuidv7()` is an 18 builtin and it is the
default on every primary key, so on an older major the first migration fails with
`function uuidv7() does not exist` and the container never starts. That is a loud
enough failure not to be worth a version assertion in the schema, but it is worth
one `select version();` when you create the database.

Environment variables on the service — the full list is in
`apps/backend/.env.local.example` with notes:

| Variable | Notes |
|---|---|
| `ENV` | `production`. Also what makes the dev bypass a boot-time panic |
| `DATABASE_URL` | Injected by the Postgres plugin. Use the private-network host |
| `JWT_SECRET` | `openssl rand -hex 32`. Set both keys by hand rather than scripting them into place: they are the keys to every session, and rotating one signs everybody out, so that should be a thing you did rather than a thing that happened |
| `REFRESH_TOKEN_HMAC_KEY` | `openssl rand -hex 32`, **different from the above** — the server refuses to boot if they match, because rotating one should not invalidate every stored refresh token |
| `VERIFICATION_MAX_SENDS` | `500` per hour, global. The spend ceiling (§5). Raise it before a launch push, not during one |
| `APNS_BUNDLE_ID` | `lol.frens.openmarket`. The `apns-topic` header for outgoing pushes. Nothing reads it yet — there is no sender (§4) |

Then point `API.baseURL` in `apps/ios/Sources/Account/APIClient.swift` at the
service's public domain.

`make railway-deploy` pushes the working tree — for a first deploy or a hotfix.
Let the GitHub integration handle the rest.

The image is 26.7MB, `FROM scratch`, static binary. There is no shell in it,
which is the point — debugging goes through logs.

---

## 9. What this pass did not decide

The listing questions from `backend-platform.md` §7 are all still open, and none
of them were prejudged here. The two that the account layer now makes *easier*
to answer:

- **Question 4 — do sightings stay anonymous?** There is now a principal to
  attribute them to, which would make abuse control much easier and would make
  the corpus personally identifiable. `data-model.md` chose `devices`
  deliberately to avoid exactly that, and having accounts does not overturn the
  reasoning — it just means the choice is now a choice.
- **Question 5 — moderation posture.** Unchanged in substance, but there is now
  an owner to attach a moderation decision to.

Not touched at all: image hosting, the enrichment pipeline, and search. All three
are still as `backend-platform.md` describes them.
