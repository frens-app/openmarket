# Listing alerts

The `user_listing_alerts` table stores each user’s alert and its schedule.
`listing_alert_check_runs` stores each search run and its upload/evaluation progress.
`listing_alert_background_fetch_attempts` traces silent pings and foreground recovery.
`listing_alert_notification_outbox` stores grouped match notifications and their single-send outcome.
An account can hold three alerts, including paused alerts. Each alert saves the
buyer's text, a fallback search location, and the current device. Deleting an
alert frees a slot and deletes its checks, listing records, and notification
queue. Account deletion also removes all alert data.

Creation and resume require an active OpenMarket session, Facebook connected on
that same install, notification permission enabled, and a registered APNs token.
Resuming binds an alert to the current device. Facebook cookies and request
tokens remain in the phone's WebKit store; the backend never receives them.

## Alerts tab

Use the plus button to create an alert with one text field for the product and
any preferences or requirements. There is no separate location field. The tab
lists active and paused alerts
with match and unread counts. Open an alert to see its matching listings, or use
its options menu to pause, resume, or delete it. Opening a push notification takes
you to that alert. Matches have individual viewed status; there is no separate
notification-history inbox.

## Deployment configuration

Add these to the backend deployment (or `apps/backend/.env.local` for development):

```dotenv
PRICE_ALERTS_ENABLED=true
AI_GATEWAY_API_KEY=<Vercel AI Gateway key with access to typesafe-ai/jev>
APNS_KEY_ID=<Apple APNs signing key ID>
APNS_TEAM_ID=<Apple Developer team ID>
APNS_PRIVATE_KEY=<complete contents of the APNs .p8 file>
APNS_BUNDLE_ID=lol.frens.openmarket
APNS_ENVIRONMENT=production
```

`PRICE_ALERTS_INTERVAL` is optional and defaults to `30s`. Keep it configurable
for faster development polling (`10s`) versus production pacing. The enable flag
lets development run without push credentials. Credentials, signing configuration,
and these environment-specific controls stay in configuration; the three-alert
limit and daily schedule are product rules in code.

`APNS_PRIVATE_KEY` accepts actual PEM newlines or literal `\n` sequences. Keep it
in server secrets, never in the iOS app. The Xcode project currently uses team
`6M3V5JF982`; the APNs key must belong to the team that signs the app.

For Xcode Debug builds use `APNS_BUNDLE_ID=lol.frens.openmarket.dev` and
`APNS_ENVIRONMENT=development`. TestFlight and App Store builds use the production
APNs environment. A backend serves one bundle/environment combination; don't
point both Debug and Release installs at one alerts-enabled backend.

`AI_GATEWAY_API_KEY` can be omitted only when `LLM_PROVIDER=vercel` and the existing
`LLM_API_KEY` supplies the gateway credential. Alert matching has no per-user
model-call rate cap. It still uses `LLM_MAX_ATTEMPTS` for failed-call retries,
the existing 0.8 Jev acceptance threshold, and records usage in `llm_runs`.
Alert matching respects explicit product requirements and price limits in the
buyer's text; the more permissive Price Check comparable rules remain separate.

The existing `DATABASE_URL`, authentication, and other required backend settings
still apply. Migrations `00024_listing_alerts.sql` and
`00025_listing_alert_fetch_tracking.sql` run automatically at API startup, after
main's existing migrations through `00023_link_sign_in.sql`.
There is no external cron service: the API hosts the recurring worker. Keep at
least one instance running continuously. A PostgreSQL advisory lock serializes
worker activity across replicas, and a shared dispatch deadline preserves the
configured staggering interval. The minimum accepted interval is 10 seconds.
`PRICE_ALERTS_ENABLED` defaults to false; creation remains unavailable until the
worker and credentials are enabled. Existing alerts can still be read/deleted.

In Apple Developer, enable Push Notifications for both App IDs you use and
refresh their provisioning profiles. Create/download an APNs token signing key
(`.p8`) with permission for the selected environment/topic. Rebuild the app after
`xcodegen generate`: `project.yml` includes the existing APNs entitlement and the
new `remote-notification` background mode. The app registers the notification
center delegate and background-fetch callback at launch.

## Server-controlled search options

The silent push is a wake-up signal containing alert/check IDs. The app fetches
`/v1/price-alerts/work` with authentication and uses each check's `searchOptions`.
Settings are read when work is fetched, so even a previously sent push can use
updated server settings. Foreground recovery uses the same path.

`LISTING_ALERT_SEARCH_OPTIONS` is one optional JSON object, applied to all alerts
on that backend. Leave it unset to retain newest-first, available listings with
no price, age, delivery, or condition restriction. For example:

```dotenv
LISTING_ALERT_SEARCH_OPTIONS={"sort":"creation_time_descend","daysSinceListed":1,"delivery":"local_pick_up"}
```

Supported fields:

| Field | Values | Default |
| --- | --- | --- |
| `sort` | `best_match`, `creation_time_descend`, `distance_ascend`, `price_ascend`, `price_descend` | `creation_time_descend` |
| `minPrice`, `maxPrice` | Whole units of the searched marketplace's currency, 0–2147483647 | No bound |
| `daysSinceListed` | `0`, `1`, `7`, `30` | `0` (any age) |
| `delivery` | `""`, `local_pick_up`, `shipping` | `""` (any) |
| `conditions` | Array containing `new`, `used_like_new`, `used_good`, `used_fair` | `[]` (any) |

Update configuration and restart/redeploy the backend to apply it; no iOS build
is needed after the app version supporting `searchOptions` is installed. Invalid
values and unknown configuration keys prevent startup. Bounds are global, so a
price range will narrow every alert on that deployment. The buyer's text remains
authoritative, and Jev still checks the buyer's criteria.
Availability stays available-only, and each check stays limited to one page.
Changing these settings affects future searches, not previously checked listings.

Older apps ignore `searchOptions` and continue using their built-in search
settings. Updated apps also accept a server that omits `searchOptions`, retaining
the newest-first defaults. Unknown fields in a work response are ignored; unknown
values for supported options fail the search rather than silently dropping a
constraint. Entirely new search capabilities or Facebook protocol changes can
still require an app release. Jev matching logic runs on the server and can be
changed independently of the app.

## Scheduling and recovery

`created_at` is the database's exact wall-clock timestamp. `alert_hour` is the UTC
hour from rounding creation to the nearest hour, with half-hours rounded upward;
`next_check_at` holds the corresponding timestamp. An alert rounded into the past
is eligible immediately. The daily hour stays fixed in UTC and is displayed in
the device's local time, so travel and daylight-saving changes can change that
local display.

Each worker interval chooses one oldest due alert that hasn't completed a check
in 24 hours. Overdue checks stay eligible after their hour passes. A unique active
check per alert prevents overlapping daily searches. A dispatch is not a completed
check: only a fully uploaded and evaluated search updates `last_checked_at`.

A background APNs message contains `kind=price_alert_check`, `alert_id`, and
`check_id`, plus a unique `fetch_attempt_id`. The authenticated work API supplies the saved search. The
phone uses its signed-in Facebook transport, server-supplied search options,
and the available-products filter. Each check fetches only the first page and uploads it
as a complete search, even if Facebook offers more pages. Upload sequence numbers
make retries idempotent. Facebook listing IDs, including rejected
candidates, are unique per alert, so subsequent checks never reevaluate or
renotify a previously checked listing. The buyer's text is immutable; create a new
alert to change the requested product.
Each work request includes the app's current saved search location and radius,
so future checks follow location changes on that device. If the device has no
saved location, the server falls back to the location stored when the alert was
created. Each fetch snapshots the actual location used; a retry keeps that
snapshot. Alerts do not request a new GPS fix during a background wake.

Jev evaluation runs on the backend in batches of 30. Failed evaluations remain
pending and retry after an hour; they never become negative matches. All matched
listings are stored before a durable notification outbox creates one summary per
completed check. Each visible notification is claimed atomically before one send;
failures and unknown outcomes are not retried. Invalid APNs device tokens
are cleared and can be registered again on the next launch. APNs acceptance and
notification timestamps don't prove that a person saw a notification. Listing
`viewed_at` records the first actual opening of that listing in the Alerts UI.

Silent pushes are spaced at least 30 minutes apart on each device. An unfinished
check gets at most three attempts per 24-hour retry cycle. The app also polls for
pending work every minute while foregrounded. Its background callback completes
within 25 seconds, cancelling outstanding work at 23 seconds to leave time for
a best-effort failure report. If the upload did not finish,
a later wake or foreground session retries the first page. Facebook account
changes may require pausing and resuming the alert; already uploaded/evaluated
listings remain deduplicated.

The available filter is sent to Facebook and explicitly sold cards are discarded.
Location is a saved Facebook search location; this flow does not fetch detail
coordinates to impose a strict radius. Facebook may return surrounding areas.
The listing snapshot includes the title, price, thumbnail and location from the
search card. It opens the app's existing listing detail screen for current detail.

## Delivery limits

Apple [does not guarantee background push delivery](https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app)
and provides approximately 30 seconds of background runtime. Force quitting,
disabled Background App Refresh, low-power policies, missing connectivity, and
WebKit suspension can defer a Facebook search until the app is foregrounded. This
architecture cannot guarantee a daily search at an exact time with only a phone's
Facebook session. No environment variable removes that platform constraint.

Notification delivery is at least once: stable APNs collapse identifiers reduce
duplicate retries, but a process/network failure after APNs accepts a visible
push and before the database records success can still produce a repeated push.
Persisted listing matches and evaluation records remain unique in that case.

## API and verification

The authenticated JSON endpoints are `POST /v1/price-alerts/{action}`. They reuse
the existing access-token and active-session authentication. Actions are `list`,
`create`, `state` (pause/resume), `delete`, `work`, `page`, `matches`, and `viewed`.
The Go request/response types live in `cmd/api/alerts.go`; iOS wire types are in
`PriceAlertsService.swift`. Responses use RFC3339 timestamps. Match pagination
uses the exact `matchedCursor` string and listing ID as a pair so equal timestamps
and fractional seconds never drop rows. Requests are capped at 512 KiB and 100
listings per page. `viewed` accepts only explicit listing IDs belonging to the
signed-in user's alert.

Run the normal Go build, vet and test commands. For database coverage, set
`ALERTS_TEST_DATABASE_URL` to a **disposable PostgreSQL 18 database** and run:

```sh
cd apps/backend
ALERTS_TEST_DATABASE_URL='postgres://…' go test ./cmd/api -run 'TestAlertsIntegration|TestPriceAlertMigrationUpgradesMain' -count=1 -v
```

These tests apply migrations, create isolated accounts, and clean up those
accounts. They cover concurrent limits, scheduling, permissions, cross-account
access, upload retries, cursor recovery, matched/rejected deduplication,
notification retries, pagination, and viewed state. A separate migration test
applies main through version 23, seeds existing account, listing price,
saved-listing/view, and sign-in linking data, then upgrades to version 24 and
rolls back/reapplies it, checking that the existing data remains intact. The APNs tests verify signed
provider tokens and push headers against a local HTTP server. No unit/integration
test sends real pushes or bills Jev.

Before production rollout, test on a signed physical iPhone with the deployment's
APNs environment: create an alert, background the app, confirm a check uploads
one page and finishes, open the resulting notification, open a match and verify its
viewed state, then pause and delete the alert. Also test a missed wake followed by
foreground recovery. Real Facebook, APNs delivery, and billed Jev matching require
this device smoke test; simulator/unit tests do not establish their reliability.
## Tracing a check

Every silent ping creates a `listing_alert_background_fetch_attempts` row before
sending. The payload ID follows the device acknowledgment, work request, search
start, and upload. Each retry has a different ID under the same `check_id`.
Foreground recovery creates its own row with `trigger='foreground'`, no send or
acknowledgment timestamp, and never gets credited as a response to a silent ping.
A push arriving while another search runs is acknowledged and records
`already_running`; it does not borrow that search's results.

The row stores server-observed timestamps, APNs acceptance/error, the exact work
response in `search_request`, all uploaded candidate snapshots in
`returned_listings`, and the first reported failure stage/code. A retried work
request uses its original snapshot. `upload_received_at` is written in the same
transaction as the listings and scan completion. Repeated uploads preserve the
original timestamp and data. Empty successful uploads store `[]`, distinct from
no upload. A stale competing fetch cannot claim another attempt's upload.

Candidate snapshots include listings deduplicated out of matching. Canonical
alert matches remain in `listing_alert_listings`; its `check_id` identifies the
check that first discovered that listing. The fetch snapshot preserves what each
search actually uploaded, including previously seen candidates. Explicitly sold
or untitled cards discarded by the phone are not uploaded.

Example timeline query for one check (substitute its UUID):

```sql
SELECT f.id AS fetch_attempt_id, f.trigger, f.device_id,
       f.send_started_at, f.apns_accepted_at, f.send_error,
       f.acknowledged_at, f.work_requested_at, f.search_started_at,
       f.upload_received_at,
       extract(epoch FROM f.acknowledged_at-f.send_started_at) AS acknowledgment_seconds,
       extract(epoch FROM f.upload_received_at-f.send_started_at) AS response_seconds,
       jsonb_array_length(f.returned_listings) AS uploaded_candidates,
       f.failure_at, f.failure_stage, f.failure_code,
       c.evaluation_started_at, c.evaluation_error_at, c.evaluation_error_code,
       c.completed_at, n.send_started_at AS notification_send_started_at,
       n.sent_at AS notification_apns_accepted_at, n.send_error AS notification_error
FROM listing_alert_background_fetch_attempts f
JOIN listing_alert_check_runs c ON c.id=f.check_id
LEFT JOIN listing_alert_notification_outbox n ON n.check_id=c.id
WHERE c.id='00000000-0000-0000-0000-000000000000'
ORDER BY f.created_at;
```

Read `search_request` and `returned_listings` from a fetch row to inspect the
search settings and candidate IDs/content. Use `listing_alert_listings` joined
by the check/alert and listing ID to inspect match decisions and viewed state.
Structured backend logs include fetch/check/notification IDs at their respective
stages. Client failures use bounded codes (for example `facebook_disconnected`,
`invalid_facebook_response`, or `network_timeout`), not raw errors or cookies.
Evaluation errors remain on the check as historical diagnostics after recovery.

A missing acknowledgment means no response was observed. It does not identify
whether iOS delivered the push, the app ran, or its report could reach the API.
Event reporting is best effort; authentication or connectivity failures can
prevent it. Durations include network latency and use the server clock, avoiding
phone clock skew. Upload completion remains authoritative even if a late failure
report arrives. APNs acceptance never proves visible notification delivery.

The visible outbox keeps `send_started_at`, `send_finished_at`, `send_error`, and
`sent_at` (APNs accepted). If the process crashes after claiming a send, it stays
claimed with an unknown outcome instead of risking a second notification. The
migration marks previously attempted notifications as already claimed, preserving
successful sends and labelling failed/unknown historical sends
`legacy_outcome_unknown`.

Old apps remain compatible but cannot supply per-fetch receipts or upload
correlation. Deploy the backend before installing the new client. No new
environment variables are required. Deleting an alert/account cascades its fetch
history and uploaded snapshots along with its existing alert data.
