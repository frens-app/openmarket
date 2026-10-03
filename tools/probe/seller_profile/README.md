# Seller profile validation

Seller screens require Facebook authentication, including entry from a saved
Following profile. An unauthenticated tap opens sign-in before navigation;
a successful login resumes that seller. Cancelling leaves the user on the
originating screen. The screen rechecks authentication on entry/foreground and
closes on sign-out. The loader rejects anonymous access before navigation.

Following stores ID, name, photo URL, join text, public rating/count and the highly-rated
badge in device UserDefaults. Saved profiles survive signing out. Local following
does not follow the seller on Facebook, sync accounts, or send notifications.
No credentials or inventory cursors are persisted by this feature.

## Public-page experiment, 2026-10-03

The user-supplied Marketplace profile loaded while signed out in the in-app
browser and in a fresh nonpersistent desktop WebKit session on the QA simulator.
Its initial HTML contained one available listing. Inventory data appears under
`data.profile.marketplace_listing_sets.edges[].node.canonical_listing`; separate
streamed records carry additional edges and deferred `page_info`. The supplied
profile's page-info explicitly reported `has_next_page: false`.

The dialog sits over Marketplace recommendations. Collecting every item link
would mix other sellers into this profile, so the loader reads only the matching
profile query and connection patches. The numeric route ID resolves to a pfbid
in the response; subsequent requests use and validate that resolved ID.

Two cookie-free requests, one for each observed inventory operation, returned
HTTP 200 with GraphQL error 1675002, “Unauthorized logged out query.” Selecting
Sold & out of stock in the signed-out browser also produced an unavailable-page
error. Public initial HTML is therefore not evidence that anonymous filter or
pagination requests work. The feature intentionally requires authentication.

The observed filter component exports:

- Available & in stock: `IN_STOCK`
- Sold & out of stock: `OUT_OF_STOCK`
- All listings: `IN_STOCK`, `PENDING`, `OUT_OF_STOCK`

The native second filter combines `PENDING` and `OUT_OF_STOCK`, as requested.
Query metadata is recorded in `observed-operations-2026-10-03.json`. The loader
uses the page's current pagination module ID when available. Tokens stay inside
the existing WebKit session. Private numeric seller ratings in profile payloads
are not imported or displayed.

## Signed-in simulator validation, 2026-10-03

The user's existing Facebook session on iPhone 17 Pro loaded Emery Garden's
available inventory, the combined pending/sold/out-of-stock filter, and a second
page of sold listings. Filter switching initially failed with URL error -1005
or a false session-change error: a same-URL reload leaves the old document
readable until navigation commits. The loader now waits for its own navigation's
`didCommit` before reading bootstrap data or issuing GraphQL requests.

The profile page's embedded `data.user` includes
`commerce_profile_picture_with_fallback_160.uri` and `profile_picture_160.uri`.
The loader accepts the photo only when that user's ID matches the resolved
inventory profile ID (or the numeric route ID). Opening the saved Emery Garden
profile on the signed-in simulator displayed its photo and updated the Following
row. Avatars use the existing disk-backed image cache and fall back to initials
on missing or failed images. Old saved profiles without a photo remain readable;
opening their seller page refreshes the photo URL, whose CDN signature may expire.

Comparison against Facebook's visible inventory and mobile user-agent behavior
remain unverified.

## Opt-in probes

`SellerProfileProbeTests.swift` discovers a seller through a listing using an
existing signed-in session. `AnonymousSellerProbeTests.swift` inspects the
supplied public profile with a fresh nonpersistent WebKit store. Both are
excluded from routine tests.

Copy only the desired probe into `apps/ios/Tests/`, regenerate using
`xcodegen generate --spec apps/ios/project.yml`, then run the matching test class:

```
xcodebuild test -project apps/ios/OpenMarket.xcodeproj -scheme OpenMarket \
  -destination 'platform=iOS Simulator,id=09ACC966-0D21-478F-84AB-141EDA94E883' \
  -parallel-testing-enabled NO -only-testing:OpenMarketTests/AnonymousSellerProbeTests
```

Use **Openmarket Detail QA**, not the user's running iPhone 17 Pro. No probe
messages, follows, or modifies a Facebook account. The anonymous probe writes
noncredential query/component metadata into the QA app's Documents directory.
Keep raw logs local: existing detail-engine logging can include seller data.
Remove the temporary test copy and regenerate afterward.

## Automated coverage

Regular tests cover sign-in-before-navigation, cancellation and continuation
after login, loader rejection before anonymous navigation, persistence/unfollow,
invalid identities, profile refresh, stale filter responses, deduplication,
pagination retry, session changes, streamed edges, deferred page info,
wrong-profile rejection, explicit availability badges, incomplete responses and
late GraphQL errors. These fixtures validate decoding and access control; they
do not replace the signed-in live checks above.
