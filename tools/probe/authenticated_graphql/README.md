# Authenticated GraphQL probe

This opt-in XCTest uses the Facebook session already signed into Openmarket Dev.
It keeps cookies and request tokens inside WebKit and prints only response
shapes, counts, and timing. It requests at most three Search and two Browse
pages, with the production client's pacing. Normal app startup may also load
its Discover feed. Do not run it as part of unattended or repeated unit tests.

To run after signing into Facebook in the Simulator app:

1. Temporarily copy `AuthenticatedGraphQLProbeTests.swift` into `apps/ios/Tests/`.
2. Run `xcodegen generate --spec apps/ios/project.yml`.
3. Run `xcodebuild test` with the OpenMarket project/scheme, the signed-in
   Simulator destination, and
   `-only-testing:OpenMarketTests/AuthenticatedGraphQLProbeTests`.
4. Inspect `AUTH_PROBE` lines. A failure stops the probe; it does not switch to
   anonymous requests. An absent session skips it.
5. Remove the temporary test copy and regenerate the project.

The test mounts the app's WebKit engine in a window, loads each feed's module,
and exercises the actual `AuthenticatedFeedClient`. The injected response
observer reports shapes without retaining raw responses or printing tokens,
account IDs, listing inventories, or cursor values.

Measured results and implementation details are in
[`docs/anonymous-graphql-2026-09-30.md`](../../../docs/anonymous-graphql-2026-09-30.md#authenticated-session-backed-graphql).
