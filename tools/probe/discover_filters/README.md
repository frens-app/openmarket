# Discover radius and refinement probes

Read-only, cookie-free experiments against the Discover pagination operation.
These are opt-in live probes, excluded from ordinary tests. No Facebook account
settings, listings, or messages are changed. Each `radius.py` mode issues at most
eight requests (four for `alternate_path`), with fresh cursors per variant and
one second between requests. HTTP failures, GraphQL errors, or nonadvancing
cursors stop the run. No credentials, listing IDs, or cursor values are saved.

From the repository root:

```sh
python3 tools/probe/discover_filters/radius.py --mode radius --output /private/tmp/discover-radius.json
python3 tools/probe/discover_filters/radius.py --mode refinement --output /private/tmp/discover-refinement.json
python3 tools/probe/discover_filters/radius.py --mode alternate_path --output /private/tmp/discover-alternate.json
swift tools/probe/discover_filters/InspectDiscoverInputs.swift
```

The Swift probe opens an ephemeral macOS WebView at the public San Francisco
Marketplace page and inspects loaded query metadata and the browse component's
refinement field names. It never invokes mutations. Its final condensed source
was syntax-checked; the live metadata investigation used equivalent, more
verbose temporary probes to trace the module exports.

`radius` brackets 8,000 and 2,000 with repeated 65,000 controls. `refinement`
tests the field names observed in Facebook's browse component. The string
`local` is a candidate value, not a value verified from Facebook's UI.
`alternate_path` compares 65,000 and 8,000 with `useSDFPath: false`, a value
observed as the container query's default.

Listings in these responses expose city names but no coordinates. Distance
metrics are null when coordinate coverage is zero; city counts are not exact
in-radius counts. Missing delivery types mean unknown, not shipping-only.
The saved refinement run predates ID-overlap comparison against its control,
so that unmeasured field is omitted from its results.

Findings: [Discover filters, 2026-10-02](../../../docs/discover-filters-2026-10-02.md).

## Count comparison

`count.py` measures listing counts, feed-unit counts, response sizes, timings,
and duplicate IDs, reading only the Discover connection and its streamed edges.
The comparison mode makes at most 15 requests: three pages each at counts
1, 2, 4, 8, and a repeated 1. The cap mode makes four requests: one seed page,
then counts 5, 8, and 16 independently from the seed's cursor. Cursor replay in
cap mode is deliberate; do not combine those three responses into one feed.

```sh
python3 tools/probe/discover_filters/count.py --output /private/tmp/discover-count.json
python3 tools/probe/discover_filters/count.py --mode cap --output /private/tmp/discover-count-cap.json
```

Both modes default to radius 8,000 and stop on errors without retries. No
listing IDs, cursors, cookies, or response bodies are written to disk.
Results: [Discover count measurements](../../../docs/discover-count-2026-10-02.md).
