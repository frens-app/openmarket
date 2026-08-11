# The backend, as built

**Date:** 2026-08-10
**Code:** `apps/backend`, `protos/openmarket/api/v1`, `apps/ios/Sources/Account`
**Decision record:** `backend-platform.md` — this document is what came of it

`backend-platform.md` evaluated the platform. This is the narrower record of
what actually shipped and why the scope is what it is.

---

## 1. Scope: accounts, and nothing else yet

The server owns **users, sessions, phone login, and push tokens**. It does not
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
  pkg/phone/                  E.164 normalisation + country allowlist
  pkg/verify/                 Prelude Verify client, and the dev bypass
  pkg/config/                 flags → env → .env files
  pkg/db/                     sqlc output (generated)
  railway.toml                deploy config (see §8 — its path is load-bearing)
  deployments/
    migrations/               goose
    queries/                  sqlc input
    compose.yml               local Postgres
apps/ios/Sources/Account/     Keychain, install identity, Connect client,
                              AccountSession
apps/ios/Sources/UI/PhoneLoginView.swift
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

Two RPCs, and the account comes into existence as a side effect of the second —
there is no separate signup call.

```
StartPhoneVerification(+14155550123)   → provider sends a code
VerifyPhone(+14155550123, "123456")    → session, and the user row if new
```

`VerifyPhoneResponse` carries `is_new_user`, which is what decides whether
onboarding runs. Asked of the server rather than inferred from an empty profile,
so a reinstall on an existing account doesn't walk the user through it again.

**A verification provider, not our own OTP table.** The service never generates,
stores or compares a code. Code generation, delivery, expiry, per-code attempt
limits and fraud scoring are all behind one HTTP call, and what we keep is the
`users` table and our own sessions.

### The provider is Prelude

Chosen over Twilio Verify on cost and on fit: roughly 30% cheaper per US
verification at list price, and its API is addressed by phone number rather than
by a service resource, so there is nothing per-environment to create. It also
scores each request on **signals** — `StartPhoneVerification` forwards
`install_id` and the platform, which is how a real app install asking about one
number is told apart from a script walking a range. Twilio Verify has no
equivalent parameters. See [`backend-platform.md`](backend-platform.md) §3 for
the evaluation.

`verify.Sender` is three methods, so the provider is swappable in the sense that
matters — a replacement is one file in `pkg/verify` and its tests — but there
is exactly **one** implementation of it and no runtime switch. A second one kept
"just in case" is a second one nobody exercises.

The one thing to know before touching `PreludeSender`: **a refused send comes
back as HTTP 200 with `status: "blocked"`**, not as an error status. `Start`
therefore inspects the body on success as well as on failure, and a rewrite that
only checks the status code would silently count every blocked number as a code
delivered.

### Development runs the same path, not a different one

`pkg/verify.Sender` is the seam, and the arrangement around it matters more than
it looks.

The first version had **two implementations** — the real provider, and a dev
sender that returned a fixed answer — chosen by a flag. That meant a developer
picked between a login they could use and a login that ran the production code,
so request encoding, the auth header, response parsing and provider-error mapping
were only ever exercised in production. The parts most likely to be wrong were
the parts dev never ran.

The second version replaced that with a local HTTP service imitating the
provider. It fixed the fidelity problem and introduced a worse one: a base-URL
override, wired to configuration, whose only purpose was to point the service at
something that isn't Prelude. That override has to exist in production in order
to be unset there, and a production deploy still pointed at a stand-in would
accept any code from anybody while looking perfectly healthy. The guard against
it was a boot panic — a guard that only exists because the hazard was invented.

**Now there is one client and no override.** `PreludeSender` always talks to
`https://api.prelude.dev`; `PreludeOptions.BaseURL` survives for tests only and
is not reachable from any configuration value. Every environment has the same
provider on the other end.

What makes that liveable is that the skip is **in-process**:

- **`verify.BypassSender`** *wraps* the real sender so a listed number never
  reaches it. Everything not on `DEV_BYPASS_PHONE_NUMBERS` goes to Prelude
  normally, so both modes work at once. An empty list returns the wrapped sender
  unchanged, so production carries no bypass code at all — not a disabled one.

**The list takes `*`, and that is what development ships with.** Every number is
then intercepted, so a developer types their own number — or a made-up one — and
no text is sent, nothing is billed, and Prelude's per-number limit never enters
into it. That limit is the reason: it is the provider's defence against exactly
the pattern of signing in over and over with one number, so a developer testing
the login screen looks like abuse and gets `repeated_attempts` after a handful of
tries. Set the list back to explicit E.164 numbers when you want the ones you
type to reach Prelude for real, which is the only way to confirm the provider
path still works.

`*` rides on the list rather than being its own setting so that it inherits the
list's production guard: `requireAPIValues` already refuses to boot on a
non-empty list under `ENV=production`, and a separate boolean would be a second
thing to remember there.

**The dev code is still checked.** `BypassSender.Check` compares against
`DEV_VERIFICATION_CODE` rather than accepting anything, so the code screen — its
error state, its resend, its autofill sizing — is testable rather than skipped
past.

The cost of dropping the stand-in is that provider *failure* paths — blocked,
repeated attempts, landline — are no longer reachable by typing a magic number
into the app. They are covered instead by `pkg/verify/prelude_test.go`, which
points `BaseURL` at an `httptest` server and asserts each mapping, including the
one most likely to be got wrong: **a refused send is HTTP 200 with
`status: "blocked"`**, not an error status.

`config.requireAPIValues` panics at boot if `DEV_BYPASS_PHONE_NUMBERS` is
non-empty with `ENV=production`. That list is now the only way a code is accepted
without Prelude having sent it, which is what makes one guard sufficient.

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
| User | The account | Phone number, display name, onboarding |
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
again. It belongs on `user_devices`, and that is where it is.

An install identifies itself with a client-generated `install_id`, sent **only on
`VerifyPhone`**. The session records which device it belongs to, so every later
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

The client reports from the three places that already detect the session, deduped
against what the server last returned so the common foreground costs nothing:

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

## 5. Abuse controls on `StartPhoneVerification`

This is the one endpoint that is unauthenticated **and** costs money on every
call. Almost everything that guards it belongs to the provider, and the useful
question turned out to be which part doesn't.

The table below was reasoned against Twilio Verify, which is what this service
used first. **Prelude covers the same four** — per-number request limits and
per-window check limits are configurable in its dashboard (`repeated_attempts`,
`too_many_checks`), and its ML scoring plus allow/block lists occupy the ground
Fraud Guard does. The conclusion — that the only thing worth building here is a
global spend ceiling — is unchanged, because it follows from *every* provider
limit being per entity, which is true of both.

### What the provider already does, so we don't

| Threat | Twilio Verify's answer, and Prelude's equivalent |
|---|---|
| One number hammered | **Built in: 5 sends per number per 10 minutes** ([60203](https://www.twilio.com/docs/api/errors/60203)), no configuration |
| Codes brute-forced | Built in: max check attempts ([60202](https://www.twilio.com/docs/api/errors/60202)) |
| One script, one address | [Service Rate Limits](https://www.twilio.com/docs/verify/api/programmable-rate-limits) — you define the keys to meter, IP being the documented example |
| **SMS pumping** | [Fraud Guard](https://www.twilio.com/docs/verify/preventing-toll-fraud/sms-fraud-guard) — **on by default**, blocks by destination prefix, and blocked attempts are included in Verify's price rather than billed |

The first version of this service reimplemented the first three in Postgres, on
the reasoning — inherited from `backend-platform.md` — that "the bill arrives
before the alert does." That was written about Programmable Messaging and carried
into a Verify design where it largely doesn't hold. Fraud Guard in particular has
cross-customer traffic signal that a single service cannot reproduce, so a local
pumping heuristic is strictly worse than the one already running.

### The one thing that survives, and why

**Every limit above is per entity. None of them caps total spend.**

The provider's built-in limit is per *number*, so somebody cycling a thousand
ordinary US mobiles trips it zero times. And that traffic looks nothing like
pumping — no premium prefix, nobody taking a revenue share — so the anti-fraud
model has no reason to flag it. It's griefing rather than fraud, which is exactly
why no third party is watching for it: there's no attacker profit to detect. A
provider's own spend controls are account-level and after the fact.

So `verification_sends` is a **circuit breaker on the invoice**, not a fairness
mechanism: one row per send, counted over a window, refused past a ceiling
(`VERIFICATION_MAX_SENDS`, default 500/hour, global).

Three things about it:

- **It stores nothing but a timestamp.** No number, no IP, no country. Counting
  is the whole job, and the provider's dashboard is already the per-number audit
  trail — duplicating it would mean holding data we don't need.
- **The counter is in Postgres, not in process.** An in-memory one resets on
  every deploy and stops existing at all once there are two instances.
- **Hitting it logs at error level**, because a global ceiling being reached
  means either an attack or a badly set number, and in both cases real users are
  being turned away.

### What else is still ours

**The country allowlist** (`pkg/phone`), because it fails closed at boot in a way
a console setting doesn't: `phone.NewAllowlist("")` returns an error and the
server refuses to start. A missing env var must not silently unlock every premium
range on earth. It also validates E.164 before an API call is spent.

**The resend countdown** is now a hint the server reports, not a limit it
enforces — Verify's per-number limit is what actually stops a runaway client, and
keeping the number server-side means pacing can be tuned without an app release.

### On A2P 10DLC: the open question before launch

This section has been wrong twice. The first version called US A2P 10DLC Brand
and Campaign registration a hard blocker. The second called it simply "not
required". Both were too broad: **the answer depends on whose sender the messages
go out on**, and that is the one thing not settled.

10DLC governs **bring-your-own-number A2P messaging** — you own a 10-digit long
code and carriers want it registered. Since February 2025 carriers block
unregistered A2P 10DLC traffic outright, OTP included. It is binary, not a volume
threshold: ten users fail exactly the way ten thousand would, and delivery does
not degrade gracefully, it stops.

**Twilio Verify is carved out**, which is what this doc previously described.
Twilio's [A2P 10DLC overview](https://www.twilio.com/docs/messaging/compliance/a2p-10dlc)
says it directly — "if you're only using 10DLC numbers to send user verification
text messages, you can use Twilio Verify rather than registering for A2P 10DLC" —
because you are renting their pre-registered sender pool.

**Prelude publishes no equivalent carve-out.** Its
[10DLC guide](https://prelude.so/blog/10dlc-guide) says registration is mandatory
for US SMS including login codes, lists OTP as a campaign type that must be
declared, and says Prelude manages the process on your behalf.

> **Open question — settle this with Prelude before launch.** Ask whether Verify
> traffic goes out on *their* pre-registered sender or requires a brand and
> campaign in our name. If theirs, nothing needs registering. If ours, a
> **sole-proprietor 10DLC brand** is the small-launch path: no EIN required,
> approval in days rather than the 4–6 weeks a standard brand takes, throttled to
> roughly 1,000 messages/day on T-Mobile and ~15/min on AT&T, limited to one
> campaign and one number. That is far above early-user volume and buys time for
> a standard brand to clear.

What applies either way: Prelude's messaging policy and consent rules, which are
not a multi-week blocker.

---

## 6. What the phone number is, and isn't

It is the login identity, and that is all. It is returned to its own owner in
`Viewer` and is never exposed to another user.

This closes open question 3 in `backend-platform.md`. Recording the reasoning
because the alternative is tempting: showing a seller's number would make
contact trivial and would also make the app a phone-number directory for
anyone willing to scrape it. Contact stays where it already is — Facebook
Messenger — until there is a messaging story of our own.

`DeleteAccount` soft-deletes the user and **deletes the auth-method row in the
same transaction**. That second part is the one that is easy to skip: the row's
primary key *is* the phone number, so leaving it behind would mean the person
could never sign up again with a number they own. `VerifyPhone` also handles the
inverse — an auth method whose user row is gone is released and treated as an
unclaimed number rather than a dead end.

Soft delete rather than hard: an in-flight request must not be able to resurrect
the row by racing the delete. A purge job is a separate, later problem.

---

## 7. Local development

```bash
cp apps/backend/.env.local.example apps/backend/.env.local
make dev
```

Starts Postgres in Docker — the only thing there is to start — then runs the
API. The server applies migrations itself at boot, so there is no separate
migration step and the schema can never be older than the code that expects it.

**Put a real Prelude key in `.env.local`.** It is required in development as well
as production, and nothing is defaulted in quietly, because a config that fills
itself in is a config where dev and prod quietly diverge. There is no offline
mode: dev talks to the same Prelude the deployed service does. What keeps that
from costing anything is `DEV_BYPASS_PHONE_NUMBERS=*`, which development ships
with — every number is handled in-process and nothing leaves it. Narrow the list
to real numbers when you want to exercise the provider. The boot panic names the
`cp` if you forget the key either way.

```bash
make generate            # protobuf (Go + Swift) and sqlc
make migration-create name=add_listings
make dev-infra-reset     # drop the volume; next boot re-migrates
make ci                  # buf lint, go vet, go test, gofmt
```

Two files, and the split is deliberate.

`.env.development` is committed and holds only what is genuinely shared and
genuinely not secret: the database URL, the test number on the bypass list, the
resend cooldown off, and signing keys that are obviously not secrets. It carries
**no provider credentials at all** — credentials in a committed file read as real
settings somebody has to understand, and they are neither shared nor true.

`.env.local` is gitignored, merged on top, and is where the Prelude key lives.
The example is copied, not merged, so the key you paste in is yours and never a
committed default that somebody could mistake for a working one.

Postgres **18** specifically: `uuidv7()` is a builtin from 18 onward and it is
the default on every primary key.

The Simulator reaches a laptop server at `http://localhost:8080` — verified, ATS
permits loopback — and `OPENMARKET_API_URL` overrides it for a device on the same
network. Debug builds only; release builds have the host compiled in so a shipped
app cannot be pointed anywhere.

---

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
| `PRELUDE_API_KEY` | From the Prelude dashboard → API Keys |
| `ALLOWED_COUNTRY_CODES` | `1` |
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
