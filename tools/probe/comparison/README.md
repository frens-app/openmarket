# Comparison latency probe

This opt-in Simulator XCTest compares the old serial browser path, shorter
browser waits, parallel browser searches, anonymous GraphQL, the production
search pool, request pacing, and staged detail publication. It logs only
aggregate timings/counts and the fixed probe's query metadata. It does not
call Jev, send messages, or export browser cookies/tokens.

The full class requests at most 16 search operations (plus bounded recovery for
empty pages in the production pair) and one item detail. Browser benchmarks
use the existing browsing session as the original app did. The new comparison
path is always anonymous. Normal app startup can also load Discover. Keep this
out of routine test runs; use the fixed small probe only when comparing changes.

From the repository root:

1. Copy `tools/probe/comparison/ComparisonProbeTests.swift` into
   `apps/ios/Tests/ComparisonProbeTests.swift`.
2. Run `xcodegen generate --spec apps/ios/project.yml`.
3. Run `xcodebuild test -project apps/ios/OpenMarket.xcodeproj -scheme OpenMarket
   -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
   -only-testing:OpenMarketTests/ComparisonProbeTests` and save the output.
4. Read `COMPARISON_PROBE` lines. Stop on failed/blocked requests rather than
   repeating them. `testPacingOnly` uses no network. To measure only the final
   production path, select `ComparisonProbeTests/testProductionPairAndDetail`.
5. Remove the temporary copy from `apps/ios/Tests/` and regenerate the project.

The mode order is fixed, so caches and network variability confound attribution
of individual changes. Use the measurements as exploratory evidence, not a
controlled experiment or production p95. First use means a fresh engine/client,
not flushed OS or server caches. The detail probe records whether the text
callback already had photos; in that case gallery lead over final completion
was not created by the new gallery callback.

See `docs/comparison-performance-2026-10-02.md` for the measured results, bounds,
and caveats. `results-2026-10-02.json` preserves the aggregate observations.
