import Foundation
import SwiftUI
import os

extension Logger {
    static let store = Logger(subsystem: "lol.frens.openmarket", category: "store")
}

/// Owns what the grid shows: dedupe, filtering, paging, and the parse-health
/// counters behind the telemetry and the debug parity report.
@MainActor
final class ListingStore: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoadingFirstPage = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var paginationPaused = false
    /// The first visible row expected from the active Search top-up.
    @Published private(set) var loadingPlaceholderCount = 0
    /// A server-declared end, or a confirmed bottom on the browser path.
    @Published private(set) var reachedEnd = false
    @Published private(set) var health = ParseHealth()
    @Published var query: SearchQuery?

    /// Bumped every time the search grid's contents are *replaced* rather than
    /// extended — a new search or a re-run.
    ///
    /// The scroll offset survives the swap: someone five pages into "desk" who
    /// searches for "lamp" keeps their offset over a grid of twelve cards, so
    /// the screen goes blank. `ResultsView` scrolls back to the top on each
    /// change. Appending never has this problem, hence a counter on replacement
    /// rather than an observer on `listings`.
    @Published private(set) var resultsGeneration = 0

    /// Browser host for authenticated GraphQL and fallback for unsupported queries.
    let desktop: DesktopFeedEngine
    /// Retained for resolving mobile cards that lack a canonical URL.
    let feed: FeedEngine
    let detail: DetailEngine
    private let prefs: Preferences
    private let metrics: MetricsReporter
    private let cache: ListingCache
    private let authenticated: any GraphQLFeedLoading
    private let anonymous: any GraphQLFeedLoading
    private var graphQLPagination: GraphQLFeedPagination?
    private var graphQLRequest: Task<GraphQLFeedPage, Error>?
    @Published private var graphQLState: FeedEngine.LoadState?
    @Published private(set) var paginationError: String?
    /// The shared one, deliberately — the grid, the saved shelf and the detail
    /// screen all read distances from it, and a second instance would give them
    /// different answers from a different cache.
    private let distances: DistanceResolver
    private let paginationTimeBudget: Duration
    private var seenIDs = Set<String>()
    /// True while the grid is showing last session's cards. They render on the
    /// first frame, but their `cardIndex` refers to a DOM that no longer
    /// exists, so nothing may tap through them until live cards replace them.
    private(set) var isShowingCachedResults = false
    /// Cached cards remain visible while their live page is loading. They must
    /// not paginate the previous DOM during that interval.
    @Published private(set) var isRefreshingSearch = false

    /// Which context the current results were fetched under.
    ///
    /// The result *set* differs by authentication, not just the fields on it:
    /// signed in, a San Francisco query returned 15 San Francisco listings where
    /// signed out it spread to Martinez, Vallejo and Oakland. So this keys the
    /// results cache and tags every profile stored from these cards.
    @Published private(set) var session: BrowserSession = .unauthed

    /// Records the session the engines are running under, after a sign-in or
    /// sign-out. Propagates to the engines, not just this object: `canLoadMore`
    /// is the desktop engine's answer, and a stale one has a signed-out grid
    /// paginating against a page Facebook already pinned shut.
    func setSession(_ session: BrowserSession) {
        // Before the guard: an injected engine can start out of step with this
        // object, and the call that would correct it is the one returning early.
        desktop.session = session
        detail.session = session
        guard session != self.session else { return }
        detail.cancel()
        self.session = session
        resultsGeneration += 1
        graphQLRequest?.cancel()
        graphQLPagination = nil
        graphQLState = nil
        isLoadingMore = false
        isLoadingFirstPage = false
        isRefreshingSearch = false
        paginationError = nil
        paginationPaused = false
        paginationBuffer = []
        scrolledSinceLastPage = false
        loadingPlaceholderCount = 0
        reachedEnd = true
        Logger.store.info("session -> \(session.rawValue, privacy: .public)")
    }

    private var capture: CaptureContext {
        CaptureContext(session: session, surface: .desktop, capturedAt: Date())
    }

    init(desktop: DesktopFeedEngine? = nil,
         feed: FeedEngine? = nil,
         detail: DetailEngine? = nil,
         prefs: Preferences = .shared,
         metrics: MetricsReporter = LocalMetrics.shared,
         cache: ListingCache = .shared,
         anonymous: (any GraphQLFeedLoading)? = nil,
         authenticated: (any GraphQLFeedLoading)? = nil,
         distances: DistanceResolver = .shared,
         paginationTimeBudget: Duration = .seconds(8)) {
        self.desktop = desktop ?? DesktopFeedEngine()
        self.feed = feed ?? FeedEngine()
        self.detail = detail ?? DetailEngine()
        self.detail.authenticatedWebView = self.desktop.webView
        self.prefs = prefs
        self.metrics = metrics
        self.cache = cache
        self.anonymous = anonymous ?? AnonymousFeedClient()
        self.authenticated = authenticated ?? AuthenticatedFeedClient(webView: self.desktop.webView)
        self.distances = distances
        self.paginationTimeBudget = paginationTimeBudget
    }

    /// The desktop engine's state, mapped onto the shape the UI already knows.
    /// `FeedEngine.LoadState` stays the vocabulary because both engines produce
    /// the same four outcomes and the views shouldn't care which ran.
    var feedState: FeedEngine.LoadState {
        if let graphQLState { return graphQLState }
        switch desktop.state {
        case .idle: return .idle
        case .loading: return .loading
        case .ready: return .ready
        case .loginWall: return .loginWall
        case .failed(let message): return .failed(message)
        }
    }

    var canLoadMore: Bool {
        !reachedEnd && (graphQLPagination?.hasNextPage ?? desktop.canLoadMore)
    }

    var requiresFacebookForMore: Bool {
        guard case .ready = desktop.state else { return false }
        return session == .unauthed && graphQLPagination == nil && graphQLState == nil
    }

    var payloadCoverage: DesktopFeedEngine.PayloadCoverage {
        graphQLPagination == nil ? desktop.coverage
            : .init(rendered: listings.count, withPayload: listings.count)
    }

    // MARK: - Searching

    func run(_ query: SearchQuery, hiddenAsViewed: Set<String> = []) async {
        graphQLRequest?.cancel()
        self.query = query
        resultsGeneration += 1
        let generation = resultsGeneration
        graphQLPagination = nil
        graphQLState = nil
        paginationError = nil
        paginationPaused = false
        paginationHiddenAsViewed = hiddenAsViewed
        isLoadingMore = false
        isShowingCachedResults = false
        listings = []
        seenIDs = []
        deepestVisibleIndexSeen = -1
        scrolledSinceLastPage = false
        paginationBuffer = []
        loadingPlaceholderCount = 0
        reachedEnd = false
        isRefreshingSearch = true
        health = ParseHealth()

        // Last session's cards for this exact query, on the first frame. The
        // live load underneath takes 5.13s to produce anything; there is no
        // reason to show a skeleton for it when we know what was there.
        if let cached = cache.results(for: query, session: session) {
            listings = cached
            seenIDs = Set(cached.map(\.id))
            isShowingCachedResults = true
            isLoadingFirstPage = false
            Logger.store.info("restored \(cached.count) cards from cache")
        } else {
            isLoadingFirstPage = true
        }

        defer {
            if generation == resultsGeneration {
                isLoadingFirstPage = false
                isRefreshingSearch = false
                if scrolledSinceLastPage, paginationError == nil, !Task.isCancelled {
                    Task {
                        guard generation == resultsGeneration else { return }
                        await topUpIfAtMargin()
                    }
                }
            }
        }
        graphQLState = .loading
        do {
            var pagination = GraphQLFeedPagination()
            let started = ContinuousClock.now
            for index in 0..<Self.graphQLPageBudget {
                if index > 0, started.duration(to: .now) >= paginationTimeBudget { break }
                let pageStarted = ContinuousClock.now
                let page = try await requestFeedPage(query, cursor: pagination.cursor)
                guard generation == resultsGeneration, !Task.isCancelled else { return }
                let payload = try pagination.accept(page)
                graphQLPagination = pagination
                graphQLState = .ready
                await ingest(payload: payload)
                guard generation == resultsGeneration, !Task.isCancelled else { return }
                logPagePublication(started: pageStarted)
                if (!isShowingCachedResults && !visibleListings(in: listings).isEmpty) || !pagination.hasNextPage { break }
            }
            // A verified empty response replaces stale cached results too.
            if isShowingCachedResults {
                listings = []
                seenIDs = []
                isShowingCachedResults = false
            }
            reachedEnd = !pagination.hasNextPage
            paginationPaused = !reachedEnd && visibleListings(in: listings).isEmpty
            cache.saveResults(listings, for: query, session: session)
            return
        } catch {
            guard generation == resultsGeneration, !Task.isCancelled else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard (error as? GraphQLFeedError)?.permitsBrowserFallback == true else {
                graphQLState = graphQLPagination == nil ? .failed(error.localizedDescription) : .ready
                paginationError = error.localizedDescription
                return
            }
            graphQLPagination = nil
            graphQLState = nil
            Logger.store.info("GraphQL feed unavailable; using browser")
        }
        await loadBrowser(query, generation: generation)
    }

    private func requestFeedPage(_ query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        let client = session == .authed ? authenticated : anonymous
        let task = Task { try await client.page(for: query, cursor: cursor) }
        graphQLRequest = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadBrowser(_ query: SearchQuery, generation: Int) async {
        let payload = await desktop.load(query)
        guard generation == resultsGeneration, !Task.isCancelled else { return }
        if case .failed(let message) = desktop.state {
            paginationError = message
            return
        }
        await ingest(payload: payload)
        guard generation == resultsGeneration, !Task.isCancelled else { return }
        let cards = await desktop.renderedCards()
        guard generation == resultsGeneration, !Task.isCancelled else { return }
        await ingest(cards: cards)
        guard generation == resultsGeneration, !Task.isCancelled else { return }
        cache.saveResults(listings, for: query, session: session)
    }

    /// What the search actually did, once it has stopped doing it.
    ///
    /// A separate event from the submission, because the gap between the two is
    /// the whole product: "somebody searched" and "somebody got results" are the
    /// same number in a working app and very different ones in a walled or
    /// throttled session, and the only way to see the wall in aggregate is to
    /// count both ends.
    ///

    /// How many cards from the end a page starts loading — about two screens of
    /// the two-column grid. A page is three webview scrolls with a settle after
    /// each, so starting near the final card would expose the loading skeletons
    /// for too long. This buys enough runway for the cards to arrive first.
    static let prefetchMargin = 10

    /// Count visible cards toward the target. Exhausting a request or scroll
    /// budget pauses recovery without declaring the upstream feed ended.
    private static let paginationTarget = 6
    static let graphQLPageBudget = 6
    private static let maxScrollsPerTopUp = 3
    private static let loadingReservation = 2
    private static let progressivePublishSize = 2

    /// Whether the user has moved the grid since the last page landed.
    ///
    /// What keeps the wider margin from reading ahead on its own: the trigger
    /// card is still within ten of the end after a page arrives, so without this
    /// the results would page themselves to exhaustion untouched. See
    /// `DiscoverFeed.scrolledSinceLastTopUp` — same gate, same reasoning.
    private var scrolledSinceLastPage = false

    /// How far down the visible grid the user has been.
    ///
    /// Tracked because `.task` fires when the lazy stack *creates* a cell and
    /// never again, so "are we near the end" could otherwise only be asked at
    /// the moment a cell happens to be built. Reset with the list, never on
    /// append. See `DiscoverFeed.deepestIndexSeen` — same problem.
    private var deepestVisibleIndexSeen = -1
    /// The view's stable "Only new" snapshot for the current result set.
    private var paginationHiddenAsViewed = Set<String>()
    /// Parsed and geocoded pagination cards waiting for a visible row boundary.
    private var paginationBuffer: [Listing] = []

    func updateHiddenAsViewed(_ hidden: Set<String>) {
        paginationHiddenAsViewed = hidden
    }

    /// Re-check even an armed drag: a cache refresh or filter may have changed
    /// the margin without recreating the visible cells.
    func noteScroll(hiddenAsViewed: Set<String>) {
        paginationHiddenAsViewed = hiddenAsViewed
        guard query != nil else { return }
        scrolledSinceLastPage = true
        Task { await topUpIfAtMargin() }
    }

    /// Records how far the user has reached, then asks whether that is
    /// far enough. Called from each cell as it is built.
    func loadMoreIfNeeded(
        currentItem: Listing,
        hiddenAsViewed: Set<String>
    ) async {
        paginationHiddenAsViewed = hiddenAsViewed
        let visible = visibleListings(in: listings)
        guard let index = visible.firstIndex(where: { $0.id == currentItem.id }) else { return }
        deepestVisibleIndexSeen = max(deepestVisibleIndexSeen, index)
        await topUpIfAtMargin()
    }

    /// One page, about two screens from the end, for a user who has scrolled
    /// since the last one; never speculatively. One batch at a time — one
    /// page ahead, maximum).
    private func topUpIfAtMargin() async {
        let visibleCount = visibleListings(in: listings).count
        guard query != nil, !isRefreshingSearch, !isLoadingMore, canLoadMore,
              scrolledSinceLastPage, paginationError == nil,
              (visibleCount == 0 || deepestVisibleIndexSeen >= 0),
              deepestVisibleIndexSeen >= visibleCount - Self.prefetchMargin else { return }
        Logger.store.info("""
            prefetch: at visible \(self.deepestVisibleIndexSeen, privacy: .public) \
            of \(visibleCount, privacy: .public) \
            (\(self.listings.count, privacy: .public) stored)
            """)
        await performTopUp()
    }

    /// Scrolls the desktop feed one screen at a time, harvesting after each,
    /// until the next visible screen is full or three sparse windows have been
    /// tried.
    ///
    /// Harvests *between* scrolls because the desktop feed virtualises: a single
    /// read at the bottom returns the last window, not everything loaded on the
    /// way there. The native path consumes complete structured pages instead.
    func loadMore() async {
        guard !paginationPaused, paginationError == nil else { return }
        await performTopUp()
    }

    private func performTopUp() async {
        guard query != nil, !isRefreshingSearch, !isLoadingMore, canLoadMore else { return }
        paginationPaused = false
        scrolledSinceLastPage = false
        let generation = resultsGeneration
        if graphQLPagination != nil {
            await loadMoreGraphQL(generation: generation)
            return
        }
        isLoadingMore = true
        defer {
            if generation == resultsGeneration {
                if Task.isCancelled, !reachedEnd { paginationPaused = true }
                isLoadingMore = false
                loadingPlaceholderCount = 0
            }
        }
        loadingPlaceholderCount = Self.loadingReservation
        paginationBuffer = []
        let beforeStored = listings.count
        let beforeVisible = visibleListings(in: listings).count
        var scrolls = 0
        var confirmedEnd = false
        let started = ContinuousClock.now
        pagination: while visiblePaginationCount - beforeVisible < Self.paginationTarget,
                          scrolls < Self.maxScrollsPerTopUp {
            if scrolls > 0, started.duration(to: .now) >= paginationTimeBudget { break }
            scrolls += 1
            let outcome = await desktop.scrollOnce()
            guard generation == resultsGeneration, !Task.isCancelled else { return }
            switch outcome {
            case .advanced:
                break
            case .exhausted:
                confirmedEnd = true
                break pagination
            case .indeterminate:
                break pagination
            }
            let cards = await desktop.renderedCards()
            guard generation == resultsGeneration, !Task.isCancelled else { return }
            await ingest(cards: cards, stageForPagination: true)
            guard generation == resultsGeneration, !Task.isCancelled else { return }
            publishReadyPaginationRows()
        }
        publishReadyPaginationRows(flush: true)
        loadingPlaceholderCount = 0

        let addedStored = listings.count - beforeStored
        let addedVisible = visibleListings(in: listings).count - beforeVisible
        if addedStored == 0 {
            // A window full of duplicates, a transient network boundary and a
            // genuinely exhausted result set are indistinguishable here, so end
            // the attempt without setting `reachedEnd`.
            Logger.store.info("loadMore: no new cards over \(scrolls, privacy: .public) screens, retryable")
        } else {
            Logger.store.info("loadMore: \(addedVisible, privacy: .public) visible, \(addedStored, privacy: .public) stored over \(scrolls, privacy: .public) screens")
        }
        if confirmedEnd {
            reachedEnd = true
            Logger.store.info("loadMore: confirmed end of search results")
        }
        paginationPaused = !reachedEnd && addedVisible < Self.paginationTarget
        isLoadingMore = false

        // Preserve one drag made while the current page was loading. Without
        // this re-check the gesture arms `scrolledSinceLastPage`, fails the
        // `isLoadingMore` guard, and can never trigger again when a dry attempt
        // appends no new cell tasks.
        if scrolledSinceLastPage {
            await topUpIfAtMargin()
        }
    }

    private func loadMoreGraphQL(generation: Int) async {
        guard let query else { return }
        isLoadingMore = true
        loadingPlaceholderCount = Self.loadingReservation
        paginationError = nil
        paginationBuffer = []
        let before = visiblePaginationCount
        let started = ContinuousClock.now
        var pages = 0
        defer {
            if generation == resultsGeneration {
                publishReadyPaginationRows(flush: true)
                if Task.isCancelled, !reachedEnd { paginationPaused = true }
                loadingPlaceholderCount = 0
                isLoadingMore = false
                let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
                let added = visiblePaginationCount - before
                Logger.store.info("search top-up: pages=\(pages, privacy: .public) visible_added=\(added, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) paused=\(self.paginationPaused, privacy: .public) end=\(self.reachedEnd, privacy: .public)")
                if scrolledSinceLastPage, paginationError == nil, !Task.isCancelled {
                    Task {
                        guard generation == resultsGeneration else { return }
                        await topUpIfAtMargin()
                    }
                }
            }
        }
        // A page may be empty or entirely filtered while its cursor advances.
        // Bound recovery work without declaring that the remote feed ended.
        for _ in 0..<Self.graphQLPageBudget {
            if pages > 0, started.duration(to: .now) >= paginationTimeBudget { break }
            guard let pagination = graphQLPagination, pagination.hasNextPage else { break }
            do {
                pages += 1
                let pageStarted = ContinuousClock.now
                let page = try await requestFeedPage(query, cursor: pagination.cursor)
                guard generation == resultsGeneration, !Task.isCancelled else { return }
                var next = pagination
                let payload = try next.accept(page)
                await ingest(payload: payload, stageForPagination: true)
                guard generation == resultsGeneration, !Task.isCancelled else { return }
                graphQLPagination = next
                reachedEnd = !next.hasNextPage
                publishReadyPaginationRows()
                logPagePublication(started: pageStarted)
                if reachedEnd || visiblePaginationCount - before >= Self.paginationTarget { break }
            } catch {
                guard generation == resultsGeneration, !Task.isCancelled else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if (error as? GraphQLFeedError)?.permitsBrowserFallback == true {
                    publishReadyPaginationRows(flush: true)
                    graphQLPagination = nil
                    graphQLState = nil
                    await loadBrowser(query, generation: generation)
                    guard generation == resultsGeneration, !Task.isCancelled else { return }
                    paginationPaused = canLoadMore && visiblePaginationCount - before < Self.paginationTarget
                } else {
                    paginationError = error.localizedDescription
                }
                return
            }
        }
        paginationPaused = !reachedEnd && visiblePaginationCount - before < Self.paginationTarget
    }

    func retryLoadingMore() async {
        guard !isRefreshingSearch, !isLoadingMore else { return }
        if graphQLPagination == nil, case .failed = feedState {
            await retry()
        } else {
            paginationError = nil
            await performTopUp()
        }
    }

    func retry() async {
        guard let query else { return }
        await run(query, hiddenAsViewed: paginationHiddenAsViewed)
    }

    private func logPagePublication(started: ContinuousClock.Instant) {
        let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
        let visible = visibleListings(in: listings).count
        Logger.store.info("search page processed: request_to_publish_ms=\(elapsed, privacy: .public) published_visible=\(visible, privacy: .public) staged=\(self.paginationBuffer.count, privacy: .public)")
    }

    // MARK: - Ingestion

    /// The structured first page: exact timestamps, numeric prices, delivery
    /// types, sold state.
    ///
    /// Runs before `ingest(cards:)` on a fresh search so the richest version of
    /// each listing lands first and the DOM pass can only fill gaps, never
    /// overwrite. Both are idempotent on listing identity.
    private func ingest(payload: [PayloadListing], stageForPagination: Bool = false) async {
        guard !payload.isEmpty else { return }
        let listingsFromPayload = payload.enumerated().map { index, item in
            item.makeListing(cardIndex: index)
        }
        await absorb(listingsFromPayload, replacingCache: isShowingCachedResults,
                     stageForPagination: stageForPagination)
    }

    /// The markup tail — everything past the first page, plus anything rendered
    /// that the payload didn't describe.
    private func ingest(
        cards: [DesktopRawCard],
        stageForPagination: Bool = false
    ) async {
        guard !cards.isEmpty else { return }
        var parsed: [Listing] = []
        for (index, card) in cards.enumerated() {
            guard let listing = DesktopCardParser.parse(card, cardIndex: index) else { continue }
            parsed.append(listing)
        }
        await absorb(
            parsed,
            replacingCache: isShowingCachedResults && !parsed.isEmpty,
            stageForPagination: stageForPagination
        )
    }

    /// Merges a batch into the grid: new listings append, known ones fill gaps.
    ///
    /// Async for `DistanceResolver.resolveAll`, so the grid arrives at its final
    /// size instead of shrinking for seconds as distances land. It belongs here
    /// because this is the only place listings become visible — the payload
    /// pass, the markup pass, pagination and WebLite all funnel through.
    private func absorb(
        _ incoming: [Listing],
        replacingCache: Bool,
        stageForPagination: Bool = false
    ) async {
        // Live cards replace restored ones outright, in one assignment at the
        // end. `listings` is `@Published` and the grid renders "Nothing found
        // nearby" on an empty array, so a clear-then-refill would tear down the
        // grid and pop any listing the user has open.
        let generation = resultsGeneration
        var seen = replacingCache ? Set<String>() : seenIDs

        var counts = ParseHealth()
        counts.domCards = incoming.count

        var fresh: [Listing] = []
        for listing in incoming {
            counts.extracted += 1
            counts.fieldCounts["title", default: 0] += listing.title != nil ? 1 : 0
            counts.fieldCounts["price", default: 0] += listing.priceText != nil ? 1 : 0
            counts.fieldCounts["thumbnail", default: 0] += listing.thumbnailURL != nil ? 1 : 0
            counts.fieldCounts["location", default: 0] += listing.locationText != nil ? 1 : 0

            guard !shouldFilter(listing) else {
                counts.dropped += 1
                continue
            }
            guard !seen.contains(listing.id) else {
                fillGaps(from: listing)
                continue
            }
            seen.insert(listing.id)
            // A listing we've fully read before arrives already complete, so its
            // detail screen opens with everything on the first frame.
            var seeded = listing
            if let cached = cache.profile(for: listing.id) {
                seeded.detail = cached.detail
                seeded.itemURL = seeded.itemURL ?? cached.itemURL
                if seeded.locationText == nil { seeded.locationText = cached.detail?.locationText }
            }
            fresh.append(seeded)
        }

        guard !fresh.isEmpty else { return }       // keep whatever is on screen

        // Before anything is published: everything below is an assignment to
        // `@Published` state, and so a frame the user sees.
        let resolving = ContinuousClock.now
        await distances.resolveAll(fresh.map(\.locationText))
        guard generation == resultsGeneration, !Task.isCancelled else { return }
        let geocodeMS = Int(resolving.duration(to: .now) / .milliseconds(1))
        Logger.store.info("search distance resolution: cards=\(fresh.count, privacy: .public) geocode_ms=\(geocodeMS, privacy: .public)")

        if replacingCache {
            isShowingCachedResults = false
            // SwiftUI retains cached cells with the same IDs without rerunning
            // their appearance tasks. Remap observed IDs into the live order.
            let observedIDs = Set(visibleListings(in: listings)
                .prefix(deepestVisibleIndexSeen + 1).map(\.id))
            deepestVisibleIndexSeen = visibleListings(in: fresh)
                .lastIndex(where: { observedIDs.contains($0.id) }) ?? -1
            counts.rendered = fresh.count
            listings = fresh                       // one assignment, never empty
        } else if stageForPagination {
            paginationBuffer.append(contentsOf: fresh)
            counts.rendered = listings.count + paginationBuffer.count
        } else {
            counts.rendered = listings.count + fresh.count
            listings.append(contentsOf: fresh)
        }
        seenIDs = seen
        health = counts
        metrics.parseHealth(counts)
    }

    /// Visible pagination cards include staged rows so the six-card target is
    /// about what the user will receive, not merely what parsing found.
    private var visiblePaginationCount: Int {
        visibleListings(in: listings + paginationBuffer).count
    }

    private func visibleListings(in candidates: [Listing]) -> [Listing] {
        ListingWinnower.apply(
            to: candidates,
            hiddenAsViewed: paginationHiddenAsViewed,
            hidingViewed: true,
            radiusKM: prefs.radiusKM,
            distances: distances
        ).items
    }

    /// Publishes the first visible cards immediately into the reserved row,
    /// then grows the grid by complete two-column rows. Hidden cards before a
    /// visible boundary travel with that boundary so stored order is preserved.
    private func publishReadyPaginationRows(flush: Bool = false) {
        guard !paginationBuffer.isEmpty else { return }
        if flush {
            listings.append(contentsOf: paginationBuffer)
            paginationBuffer = []
            return
        }

        let visibleBufferedCount = visibleListings(in: paginationBuffer).count
        let reservedCount = min(loadingPlaceholderCount, visibleBufferedCount)
        if reservedCount > 0 {
            publishPaginationPrefix(containingVisibleCount: reservedCount)
            loadingPlaceholderCount -= reservedCount
        }

        let remainingVisibleCount = visibleListings(in: paginationBuffer).count
        let rowCount = remainingVisibleCount
            - remainingVisibleCount % Self.progressivePublishSize
        if rowCount > 0 {
            publishPaginationPrefix(containingVisibleCount: rowCount)
        }
    }

    private func publishPaginationPrefix(containingVisibleCount target: Int) {
        guard target > 0 else { return }
        var visibleCount = 0
        var prefixCount = 0
        for listing in paginationBuffer {
            prefixCount += 1
            if !visibleListings(in: [listing]).isEmpty {
                visibleCount += 1
                if visibleCount == target { break }
            }
        }
        guard visibleCount == target else { return }
        listings.append(contentsOf: paginationBuffer.prefix(prefixCount))
        paginationBuffer.removeFirst(prefixCount)
    }

    /// WebLite ingestion, retained for the demoted mobile path.
    ///
    /// Extraction returns every card in the DOM each time, so this is
    /// idempotent: known ids are skipped and only genuinely new cards append.
    private func ingest(_ raw: [FeedEngine.RawCard]) async {
        // Replace rather than merge: merging keeps last session's `cardIndex`,
        // which now points at a different card, and a tap opens the wrong
        // listing. Detail already fetched comes back from the profile cache.
        let isReplacingCached = isShowingCachedResults && !raw.isEmpty
        // A copy, so a replacement that yields nothing leaves the restored grid
        // intact rather than half-dismantled.
        var seen = isReplacingCached ? Set<String>() : seenIDs

        var counts = ParseHealth()
        counts.domCards = raw.count

        var fresh: [Listing] = []
        for card in raw {
            guard let listing = CardParser.parse(card) else { continue }
            counts.extracted += 1
            counts.fieldCounts["title", default: 0] += listing.title != nil ? 1 : 0
            counts.fieldCounts["price", default: 0] += listing.priceText != nil ? 1 : 0
            counts.fieldCounts["thumbnail", default: 0] += listing.thumbnailURL != nil ? 1 : 0
            counts.fieldCounts["location", default: 0] += listing.locationText != nil ? 1 : 0

            guard !shouldFilter(listing) else {
                counts.dropped += 1
                continue
            }
            guard !seen.contains(listing.id) else {
                fillGaps(from: listing)
                continue
            }
            seen.insert(listing.id)
            // A card we've fully read before arrives already complete, so its
            // detail screen opens with everything on the first frame.
            var seeded = listing
            if let cached = cache.profile(for: listing.id) {
                seeded.detail = cached.detail
                seeded.itemURL = cached.itemURL
                if seeded.locationText == nil { seeded.locationText = cached.detail?.locationText }
            }
            fresh.append(seeded)
        }

        guard !fresh.isEmpty else { return }       // keep the restored grid

        // Same rule as the desktop path: every distance known before anything
        // is drawn, so the grid can't resize itself afterwards.
        await distances.resolveAll(fresh.map(\.locationText))

        if isReplacingCached {
            isShowingCachedResults = false
            counts.rendered = fresh.count
            listings = fresh                       // one assignment, never empty
        } else {
            counts.rendered = listings.count + fresh.count
            listings.append(contentsOf: fresh)
        }
        seenIDs = seen
        health = counts
        metrics.parseHealth(counts)
    }

    /// Filtering happens in Swift, after extraction, so the page's own
    /// scripts stay undisturbed and the rules are unit-testable.
    private func shouldFilter(_ listing: Listing) -> Bool {
        listing.badgeText?.lowercased() == "sponsored"
    }

    // MARK: - Detail

    // Listings are opened only when a user taps them — no prefetch. The desktop
    // card carries its own item URL, so a tap costs about what a prefetch saved,
    // and speculative item-page fetches are the most automation-shaped traffic
    // the app could generate. See docs/decision-desktop-primary.md.

    /// Opens a listing, in three steps:
    ///
    ///  1. The caller has already painted the card's own fields — price, title,
    ///     photo, city, condition — so the screen is never empty.
    ///  2. If we've fully read this listing before, that profile paints now,
    ///     from disk, on the first frame.
    ///  3. Either way we refetch it live. A cached profile is a head start, not
    ///     an answer — price drops and sold status are exactly what changes
    ///     while a listing sits in a cache.
    ///
    /// `onStage` can publish cache, text, gallery, then complete details. Each is built from
    /// the original card rather than accumulated, so a late partial can't
    /// interleave with an earlier one into a state neither described.
    func enrich(_ listing: Listing, onStage: @escaping @MainActor (Listing) -> Void = { _ in }) async -> Listing {
        let started = Date()
        var best = listing

        // Step 2 — the local profile store.
        if let cached = cache.profile(for: listing.id), let cachedDetail = cached.detail {
            best.detail = cachedDetail
            best.itemURL = best.itemURL ?? cached.itemURL
            if best.locationText == nil { best.locationText = cachedDetail.locationText }
            apply(best)
            onStage(best)
            Logger.store.info("tap -> cache in \(String(format: "%.3f", Date().timeIntervalSince(started)))s (age \(Int(Date().timeIntervalSince(cached.fetchedAt)))s)")
        }

        // Step 3 — revalidate live, always.
        if let fresh = await fetchLive(best, startedAt: started, onStage: onStage) {
            best = fresh
        }
        return best
    }

    /// The live read.
    ///
    /// On the desktop surface this is almost always the first branch: every card
    /// carries its canonical URL, so opening a listing is a single page load
    /// with no resolve step — ~0.9s to usable data. The two fallbacks below
    /// belong to the demoted WebLite path, where cards carry no id at all.
    private func fetchLive(_ listing: Listing,
                           startedAt started: Date,
                           onStage: @escaping @MainActor (Listing) -> Void) async -> Listing? {
        if let url = listing.itemURL {
            // Text first, gallery after. The description is readable well
            // before the photos have rendered, and holding the screen empty
            // until both are ready is what made an open feel slow.
            guard let detailValue = await detail.loadDetail(
                id: listing.id,
                url: url,
                onPartial: { partial in
                    var staged = listing
                    staged.detail = partial
                    if staged.locationText == nil { staged.locationText = partial.locationText }
                    onStage(staged)
                    Logger.store.info("tap -> detail stage in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                }
            ) else { return nil }
            var updated = listing
            updated.detail = detailValue
            if updated.locationText == nil { updated.locationText = detailValue.locationText }
            record(updated)
            onStage(updated)
            Logger.store.info("tap -> revalidated in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
            return updated
        }

        // No URL yet, and the card index is only meaningful against live cards.
        guard !isShowingCachedResults else { return nil }

        if let harvest = await feed.openItem(cardIndex: listing.cardIndex,
                                             onPartial: { partial in
                                                 Logger.store.info("tap -> text in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
                                                 onStage(Self.merging(listing, partial))
                                             }) {
            let updated = Self.merging(listing, harvest)
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: true)
            Logger.store.info("tap -> complete in \(String(format: "%.2f", Date().timeIntervalSince(started)))s (harvested in place)")
            record(updated)
            onStage(updated)
            return updated
        }

        // The tap didn't land. Search the desktop surface for the title and load
        // the item page separately — slower, needs a 6-character title, and can
        // pick wrong among ties.
        var updated = listing
        updated.itemURL = await detail.resolveItemURL(for: listing, citySlug: prefs.locationSlug)
        guard let url = updated.itemURL else { return nil }
        guard let detailValue = await detail.loadDetail(id: updated.id, url: url) else { return nil }
        updated.detail = detailValue
        if updated.locationText == nil { updated.locationText = detailValue.locationText }
        record(updated)
        onStage(updated)
        return updated
    }

    /// Writes a fully-read listing to both the grid and the profile store,
    /// tagged with the context it was read under so a later reader can tell
    /// "this seller has no rating" from "we had no session when we looked".
    private func record(_ listing: Listing) {
        guard listing.detail != nil else { return }
        cache.store(listing, capture: capture)
        apply(listing)
    }

    /// Guarantees a saved listing has something behind it. The save control is
    /// live on the detail screen's first frame, seconds before a cold listing's
    /// enrichment lands, so a save in that window would otherwise leave the
    /// saved-items screen nothing to draw.
    func remember(_ listing: Listing) {
        cache.store(listing, capture: capture)
    }

    /// Cards for a list of ids, in the order given, entirely from disk — this
    /// is what lets the home screen's saved grid and recently-viewed strip
    /// render with no network at all. Ids with no profile behind them are
    /// skipped rather than rendered blank.
    func listings(for ids: [String]) -> [Listing] {
        cache.listings(for: ids)
    }

    /// Folds a harvest onto the card the user tapped. Built from the original
    /// listing every time rather than accumulated, so a partial stage and the
    /// final one can't interleave into something neither of them said.
    private static func merging(_ listing: Listing, _ harvest: FeedEngine.ItemHarvest) -> Listing {
        var updated = listing
        updated.itemURL = harvest.url
        updated.detail = harvest.detail.listingDetail
        if updated.locationText == nil { updated.locationText = harvest.detail.locationText }
        return updated
    }

    /// The preview rule applied to the grid: never replace text that's already
    /// correct, only fill in what was missing when the card was first read.
    private func fillGaps(from parsed: Listing) {
        guard let index = listings.firstIndex(where: { $0.id == parsed.id }) else { return }
        var existing = listings[index]
        var changed = false

        if existing.locationText == nil, parsed.locationText != nil {
            existing.locationText = parsed.locationText
            changed = true
        }
        if existing.title == nil, parsed.title != nil {
            existing.title = parsed.title
            changed = true
        }
        if existing.badgeText == nil, parsed.badgeText != nil {
            existing.badgeText = parsed.badgeText
            changed = true
        }
        if existing.originalPriceText == nil, parsed.originalPriceText != nil {
            existing.originalPriceText = parsed.originalPriceText
            changed = true
        }
        if changed { listings[index] = existing }
    }

    private func apply(_ listing: Listing) {
        guard let index = listings.firstIndex(where: { $0.id == listing.id }) else { return }
        listings[index] = listing
    }
}
