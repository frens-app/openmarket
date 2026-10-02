# Detail GraphQL probe

Opt-in, read-only Simulator experiments comparing the browser detail loader
with Facebook's detail/gallery operations. The app now uses the direct client;
the comparison calls `loadBrowserDetail` explicitly to retain its browser
baseline. No messages or listing mutations are sent.

The comparison uses the Facebook session already signed into Openmarket Dev.
Without one, it skips and requests login through the normal app. Cookies and
CSRF tokens stay inside WebKit. Anonymous requests use an ephemeral,
cookie-disabled URLSession and only observed query IDs/variables.

One run requests two search pages, at most three item pages, up to six signed-in
GraphQL requests, and two anonymous GraphQL requests. Normal app startup may
also load Discover. This is a bounded manual experiment, not a background
monitor or part of routine tests. Errors stop the affected probe; do not
repeatedly run it against blocked responses.

From the repository root:

1. Copy `tools/probe/detail_graphql/DetailGraphQLProbeTests.swift` to
   `apps/ios/Tests/DetailGraphQLProbeTests.swift`.
2. Run `xcodegen generate --spec apps/ios/project.yml`.
3. Run `xcodebuild test -project apps/ios/OpenMarket.xcodeproj -scheme OpenMarket
   -destination 'platform=iOS Simulator,name=Openmarket Detail QA'
   -parallel-testing-enabled NO
   -only-testing:OpenMarketTests/DetailGraphQLProbeTests`.
4. Inspect `DETAIL_PROBE` output for timings, error codes and field comparisons.
5. Remove the temporary test copy and regenerate the Xcode project.

The probe logs query metadata, field shapes and comparisons rather than raw
responses, seller names, cookies or credentials. Existing production loader
logs can contain listing/seller data; do not commit the full Xcode log.
Committed results omit listing IDs and private rating values.

`observed-operations-2026-10-02.json` records private query metadata without
listing/account identifiers. It is an observation, not a durable API contract.
The probe discovers fresh metadata from its initial item page each run.

## Anonymous comparison and production check

Use the separate **Openmarket Detail QA** Simulator, keeping it logged out of
Facebook. Never target `booted` when multiple Simulators are running, and do
not use the user's iPhone 17 Pro for these tests.

Copy `AnonymousDetailProbeTests.swift` to `apps/ios/Tests/` and regenerate.
Use the destination above with
`-only-testing:OpenMarketTests/AnonymousDetailProbeTests/testAnonymousComparison`
for the three-listing comparison (two feed queries, three browser detail loads,
six direct queries). Use
`-only-testing:OpenMarketTests/AnonymousDetailProbeTests/testProductionAnonymousRoute`
for one feed query and one production detail open, asserting that the browser
stays unloaded. Both skip when signed in. Remove the temporary copy and
regenerate when done.

`anonymous-results-2026-10-02.json` contains the final comparison's aggregate
results. Seller fields can occasionally be present anonymously; the test does
not require their absence. Private rating values are not printed.

Limitations and field mappings are documented in
[`docs/detail-graphql-2026-10-02.md`](../../../docs/detail-graphql-2026-10-02.md).


## Single-request capability investigation

`combined-results-2026-10-02.json` records the anonymous investigation. No
working combined request was found. Mixed document IDs were explicitly
rejected by the batch endpoint, the same-document control also failed, and
custom query text was blocked. Do not repeatedly replay rejected requests.
The blocked custom-document probe is deliberately not retained for replay.

`CombinedDetailProbeTests.swift` retains the discovery/coverage inspection and
bounded batch experiments as opt-in diagnostic source. It is excluded from
normal tests. The same-document test asserts two decoded results and **failed**
on the observed endpoint; it is a capability check, not an app regression.
Its cleaned-up source was syntax-checked after the live runs, not rerun live.
If new evidence justifies a future investigation, copy it temporarily into
`apps/ios/Tests/`, regenerate, and select only the required method using
`-only-testing:OpenMarketTests/CombinedDetailProbeTests/<method>` with explicit
QA destination `platform=iOS Simulator,id=09ACC966-0D21-478F-84AB-141EDA94E883`
and `-parallel-testing-enabled NO`. Remove the copy and regenerate afterward.
Logs contain operation metadata and aggregate comparisons, not session tokens.
