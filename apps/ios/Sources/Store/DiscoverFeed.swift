import Foundation
import WebKit
import os

/// Session-scoped nearby feed. GraphQL transport follows the Facebook session;
/// unsupported requests fall back to desktop browser extraction.
@MainActor
final class DiscoverFeed: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    /// Scrolling for more, with cards already on screen.
    @Published private(set) var isLoadingMore = false
    @Published private(set) var paginationPaused = false
    /// Slots reserved for the first row of the top-up currently being harvested.
    ///
    /// Each filtered WebView window can contain only one nearby card. Reducing
    /// this count as the first cards arrive lets them replace skeletons at the
    /// same grid positions. Refreshes do not reserve slots because their old
    /// grid stays up.
    @Published private(set) var loadingPlaceholderCount = 0
    /// True on a server-declared end or the anonymous browser fallback limit.
    /// A dry batch or a failed request remains retryable.
    @Published private(set) var reachedEnd = false
    /// Whether the cards on screen were fetched without a working account.
    ///
    /// Not the same question as "is the user signed in" — a session whose
    /// cookies have stopped working walls this page too, and the accurate next
    /// step there is also a login.
    @Published private(set) var isAnonymous = true

    /// How many in-radius cards a fill tries to have in hand before
    /// it finishes, and how many each top-up aims to add.
    ///
    /// A target rather than a page count: Facebook's feed reaches wherever it
    /// likes, and one measured load returned 20 cards across 11 cities of which
    /// a 6 mi radius kept 9.
    static let browseTarget = 12
    static let graphQLPageBudget = 6
    /// The UI reserves one two-column row, not the whole harvest target —
    /// `browseTarget` is an effort goal, not a promise that twelve survive.
    private static let loadingReservation = 2
    /// Once the reserved row is full, publish whole grid rows rather than each
    /// sparse one-card WebView window independently.
    private static let progressivePublishSize = 2
    /// How many screens one harvest may scroll, and how many of those may turn
    /// up new listings that are *all* too far before the attempt ends.
    ///
    /// `dryScreenBudget` counts only screens that produced new listings, none
    /// close enough. A screen producing no new listings at all is not counted:
    /// the feed virtualises, so the first several screens of a top-up re-read
    /// cards the fill already took. Counting those as dry ended the feed after
    /// 2644px of a 6650px document, signed in, still paginating.
    static let scrollBudget = 14
    static let dryScreenBudget = 4

    /// How many cards from the end a top-up starts — roughly two screens of a
    /// two-column grid. A top-up drives a hidden webview a screen at a time, so
    /// starting nearer the final card would leave the placeholders exposed.
    /// See `scrolledSinceLastTopUp` for what stops this becoming a treadmill.
    static let prefetchMargin = 10

    private let engine: DesktopFeedEngine
    private let authenticated: any GraphQLFeedLoading
    private let anonymous: any GraphQLFeedLoading
    private let currentSession: @MainActor () async -> BrowserSession
    private let paginationTimeBudget: Duration
    private var graphQLPagination: GraphQLFeedPagination?
    private var graphQLRequest: Task<GraphQLFeedPage, Error>?
    private var activeQuery: SearchQuery?
    @Published private(set) var generation = 0
    @Published private(set) var loadError: String?
    @Published private(set) var usesBrowserFallback = false
    private let prefs: Preferences
    private let distances: DistanceResolver
    private var hasLoaded = false
    /// Which session the current cards were fetched under, so a sign-in or
    /// sign-out rebuilds the feed.
    ///
    /// Distinct from `isAnonymous`: this records the session we *asked* under,
    /// and a walled signed-in load sets only the other. Sharing one value would
    /// make every subsequent `loadIfNeeded` see a mismatch and refetch the wall.
    private var filledUnder: BrowserSession?
    /// Listing ids already taken this fill. Held across scrolls because the
    /// desktop feed virtualises and each harvest overlaps heavily with the last.
    private var browseSeen = Set<String>()

    /// Must be in the view hierarchy for WebKit to render it — see `RootView`.
    var webViews: [WKWebView] { [engine.webView] }

    var radiusKM: Int { SearchQuery.discoverRadiusKM(prefs.radiusKM) }

    init(engine: DesktopFeedEngine? = nil,
         prefs: Preferences = .shared,
         distances: DistanceResolver = .shared,
         anonymous: (any GraphQLFeedLoading)? = nil,
         authenticated: (any GraphQLFeedLoading)? = nil,
         paginationTimeBudget: Duration = .seconds(8),
         currentSession: @escaping @MainActor () async -> BrowserSession = {
             await SessionState.isSignedIn() ? .authed : .unauthed
         }) {
        self.engine = engine ?? DesktopFeedEngine()
        self.prefs = prefs
        self.distances = distances
        self.anonymous = anonymous ?? AnonymousFeedClient()
        self.authenticated = authenticated ?? AuthenticatedFeedClient(webView: self.engine.webView)
        self.currentSession = currentSession
        self.paginationTimeBudget = paginationTimeBudget
    }

    /// Fills once per launch. `force` is the pull-to-refresh path. Also refills
    /// when the session changed, since signing in makes Facebook serve a
    /// different page.
    func loadIfNeeded(citySlug: String, force: Bool = false) async {
        let beforeSession = generation
        let session = await currentSession()
        guard beforeSession == generation else { return }
        let query = SearchQuery(kind: .browse, radiusKM: radiusKM,
                                citySlug: citySlug,
                                coordinate: prefs.resolvedPlace?.segment == citySlug
                                    ? prefs.resolvedPlace?.coordinate : nil)
        guard force || !hasLoaded || session != filledUnder || activeQuery != query else { return }
        guard force || !isLoading || activeQuery != query || session != filledUnder else { return }
        generation += 1
        let current = generation
        graphQLRequest?.cancel()
        activeQuery = query
        filledUnder = session
        graphQLPagination = nil
        usesBrowserFallback = false
        loadError = nil
        paginationPaused = false
        isLoading = true
        isLoadingMore = false
        loadingPlaceholderCount = 0
        scrolledSinceLastTopUp = false
        defer {
            if current == generation {
                isLoading = false
                hasLoaded = !Task.isCancelled
                if scrolledSinceLastTopUp, loadError == nil, !Task.isCancelled {
                    Task {
                        guard current == generation else { return }
                        await topUpIfAtMargin()
                    }
                }
            }
        }
        reachedEnd = false
        deepestIndexSeen = -1
        let startedAt = Date()
        let isRefresh = hasLoaded
        await fill(query: query, session: session, generation: current)
        guard current == generation, !Task.isCancelled else { return }

        // Here rather than in the view, which is too late to tell "empty"
        // from "walled". A handful per session at most: a launch, a refresh, a
        // change of city.
        Analytics.capture(.discoverLoaded, [
            "count": listings.count,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "is_anonymous": isAnonymous,
            "reached_end": reachedEnd,
            "is_refresh": isRefresh,
            "radius_km": query.radiusKM
        ])
    }

    /// Facebook's Marketplace feed for this place, cut to the user's radius.
    private func fill(query: SearchQuery, session: BrowserSession, generation current: Int) async {
        browseSeen = []
        isAnonymous = session == .unauthed
        engine.session = session
        do {
            let pageStarted = ContinuousClock.now
            let page = try await requestFeedPage(query, cursor: nil)
            guard current == generation, !Task.isCancelled else { return }
            var pagination = GraphQLFeedPagination()
            let payload = try pagination.accept(page)
            let batch = await nearby(payload: payload)
            guard current == generation, !Task.isCancelled else { return }
            graphQLPagination = pagination
            publish(batch.kept, replacing: true, started: pageStarted)
            reachedEnd = !pagination.hasNextPage
            if !reachedEnd, listings.count < Self.browseTarget {
                loadingPlaceholderCount = Self.loadingReservation
                await loadMoreGraphQL(wanted: Self.browseTarget - listings.count, generation: current)
                if current == generation { loadingPlaceholderCount = 0 }
            }
            return
        } catch {
            guard current == generation, !Task.isCancelled else { return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            guard (error as? GraphQLFeedError)?.permitsBrowserFallback == true else {
                loadError = error.localizedDescription
                return
            }
            usesBrowserFallback = true
        }
        let cards = await engine.loadCards(query.url)
        guard current == generation, !Task.isCancelled else { return }
        if case .failed(let message) = engine.state {
            loadError = message
            return
        }

        // A wall means the same thing whichever session we asked under: nothing
        // more to scroll for, and a login is the accurate next step.
        let walled = engine.state == .loginWall
        if walled {
            usesBrowserFallback = true
            Logger.discover.info("login wall on the browse feed")
        }
        isAnonymous = walled || session == .unauthed

        var collected = await nearby(cards).kept
        guard current == generation, !Task.isCancelled else { return }
        // Nothing is on screen during the first fill, so publish the first
        // usable page now and let any radius top-up append below it. Pull to
        // refresh deliberately keeps the old feed stable until the replacement
        // is complete.
        let publishesProgressively = listings.isEmpty
        if publishesProgressively, !collected.isEmpty {
            listings = collected
            Logger.discover.info("initial batch published: \(self.listings.count, privacy: .public) cards")
        }
        // The anonymous browser fallback stops at its initial page; the
        // direct feed uses the response cursor instead.
        if isAnonymous {
            reachedEnd = true
        } else if collected.count < Self.browseTarget {
            let wanted = Self.browseTarget - collected.count
            if publishesProgressively {
                loadingPlaceholderCount = min(Self.loadingReservation, wanted)
            }
            let harvest = await scrollForMore(
                wanted: wanted,
                publishAsHarvested: publishesProgressively
            )
            guard current == generation, !Task.isCancelled else { return }
            collected += harvest
            paginationPaused = harvest.count < wanted
            loadingPlaceholderCount = 0
        }
        if !publishesProgressively {
            // One replacement: a pull-to-refresh keeps the old cards exactly
            // where they are until the new feed is ready.
            listings = collected
        }
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from Marketplace, anon=\(self.isAnonymous, privacy: .public), end=\(self.reachedEnd, privacy: .public)")
    }

    /// Whether the user has moved the feed since the last batch landed.
    ///
    /// Gates card-based read-ahead. The visible footer can request a bounded
    /// top-up without a drag; scrolling rearms an attempt that used its budget.
    private var scrolledSinceLastTopUp = false

    /// How far down the feed the user has been, as an index into `listings`.
    ///
    /// Tracked because `.task` fires when the lazy stack *creates* a cell and
    /// never again, so the margin could otherwise only be tested at the moment
    /// a cell happens to be built. Remembering the depth is what lets a drag
    /// re-check it. Reset with the feed, never on append.
    private var deepestIndexSeen = -1

    /// Re-check even an armed drag after loading or filtering changes the feed.
    func noteScroll() {
        scrolledSinceLastTopUp = true
        Task { await topUpIfAtMargin() }
    }

    /// Records how far the user has reached, then asks whether that is far
    /// enough. Called from each card as it is built.
    func loadMoreIfNeeded(currentItem: Listing) async {
        guard let index = listings.firstIndex(where: { $0.id == currentItem.id }) else { return }
        deepestIndexSeen = max(deepestIndexSeen, index)
        await topUpIfAtMargin()
    }

    /// One bounded top-up for a reader approaching the end.
    private func topUpIfAtMargin() async {
        guard !reachedEnd, !isLoading, !isLoadingMore,
              loadError == nil,
              scrolledSinceLastTopUp,
              deepestIndexSeen >= listings.count - Self.prefetchMargin else { return }

        Logger.discover.info("""
            top-up: at \(self.deepestIndexSeen, privacy: .public) \
            of \(self.listings.count, privacy: .public)
            """)

        await performTopUp()
    }

    func loadMore() async {
        guard !paginationPaused, loadError == nil else { return }
        await performTopUp()
    }

    private func performTopUp() async {
        guard activeQuery != nil, !reachedEnd, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        paginationPaused = false
        loadingPlaceholderCount = Self.loadingReservation
        scrolledSinceLastTopUp = false

        let current = generation
        if graphQLPagination != nil {
            await loadMoreGraphQL(wanted: Self.browseTarget, generation: current)
        } else {
            let harvest = await scrollForMore(wanted: Self.browseTarget, publishAsHarvested: true)
            guard current == generation else { return }
            paginationPaused = harvest.count < Self.browseTarget
        }
        guard current == generation else { return }
        loadingPlaceholderCount = 0
        if Task.isCancelled, !reachedEnd { paginationPaused = true }
        isLoadingMore = false

        // A drag during the harvest is a queued request, not a no-op:
        // `noteScroll` can't start one while `isLoadingMore` is true, and a dry
        // harvest appends no cell whose `.task` could re-check the margin.
        if scrolledSinceLastTopUp, loadError == nil, !Task.isCancelled {
            await topUpIfAtMargin()
        }
    }

    /// Scrolls the feed a screen at a time, keeping what is inside the radius,
    /// until it has `wanted` of them or there is no point continuing.
    ///
    /// Harvests *between* scrolls because the desktop feed virtualises,
    /// recycling cards out of the DOM as they leave the viewport: a single read
    /// at the bottom returns the last window rather than the feed
    /// (`docs/logged-in-findings.md` §3).
    ///
    /// Every stop condition ends only this attempt; scrolling can
    /// retry from the current position. This is the browser pagination path.
    /// - Parameter publishAsHarvested: Publishes enough cards to replace the
    ///   reserved skeletons immediately, then coalesces later sparse windows
    ///   into complete grid rows. Refreshes instead collect in memory and
    ///   replace their existing grid once.
    @discardableResult
    private func scrollForMore(wanted: Int,
                               publishAsHarvested: Bool = false) async -> [Listing] {
        let current = generation
        var found: [Listing] = []
        var staged: [Listing] = []
        var dryScreens = 0
        var screens = 0

        harvest: while found.count < wanted,
                       dryScreens < Self.dryScreenBudget,
                       screens < Self.scrollBudget {
            screens += 1
            let outcome = await engine.scrollOnce()
            guard current == generation, !Task.isCancelled else { return found }
            switch outcome {
            case .advanced:
                break
            case .exhausted:
                Logger.discover.info("harvest reached the confirmed end on screen \(screens, privacy: .public)")
                break harvest
            case .indeterminate:
                Logger.discover.info("harvest paused after an inconclusive scroll on screen \(screens, privacy: .public)")
                break harvest
            }
            let cards = await engine.renderedCards()
            guard current == generation, !Task.isCancelled else { return found }
            let batch = await nearby(cards)
            guard current == generation, !Task.isCancelled else { return found }
            found += batch.kept
            if publishAsHarvested, !batch.kept.isEmpty {
                staged.append(contentsOf: batch.kept)

                // Replace whatever remains of the reserved row without waiting
                // for another WebView scroll.
                let reservedCount = min(loadingPlaceholderCount, staged.count)
                if reservedCount > 0 {
                    listings.append(contentsOf: staged.prefix(reservedCount))
                    staged.removeFirst(reservedCount)
                    loadingPlaceholderCount -= reservedCount
                }

                // Past the reserved row, grow the grid by whole rows so a
                // two-column layout never changes by half a row.
                let rowCount = staged.count - staged.count % Self.progressivePublishSize
                if rowCount > 0 {
                    listings.append(contentsOf: staged.prefix(rowCount))
                    staged.removeFirst(rowCount)
                }
            }
            // Only a screen that turned up something new and rejected all of it
            // counts against the area. See `dryScreenBudget`.
            if batch.newCards > 0 {
                dryScreens = batch.kept.isEmpty ? dryScreens + 1 : 0
            }
        }

        // Do not strand a final odd card merely for layout symmetry.
        if publishAsHarvested, !staged.isEmpty {
            listings.append(contentsOf: staged)
        }

        let reason: String
        if found.count >= wanted {
            reason = "target"
        } else if dryScreens >= Self.dryScreenBudget {
            reason = "dry budget"
        } else if screens >= Self.scrollBudget {
            reason = "scroll budget"
        } else {
            reason = "no movement"
        }
        Logger.discover.info("harvest: \(found.count, privacy: .public) kept over \(screens, privacy: .public) screens, dry \(dryScreens, privacy: .public), stopped for \(reason, privacy: .public), retryable")
        return found
    }

    private func requestFeedPage(_ query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        let client = filledUnder == .authed ? authenticated : anonymous
        let task = Task { try await client.page(for: query, cursor: cursor) }
        graphQLRequest = task
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func loadMoreGraphQL(wanted: Int, generation current: Int) async {
        guard let query = activeQuery else { return }
        loadError = nil
        paginationPaused = false
        var added = 0
        let started = ContinuousClock.now
        var pages = 0
        for _ in 0..<Self.graphQLPageBudget {
            // Finish an in-flight request/geocode, but do not start another past the budget.
            if pages > 0, started.duration(to: .now) >= paginationTimeBudget { break }
            guard let pagination = graphQLPagination, pagination.hasNextPage else { break }
            do {
                pages += 1
                let pageStarted = ContinuousClock.now
                let page = try await requestFeedPage(query, cursor: pagination.cursor)
                guard current == generation, !Task.isCancelled else { return }
                var next = pagination
                let payload = try next.accept(page)
                let batch = await nearby(payload: payload)
                guard current == generation, !Task.isCancelled else { return }
                graphQLPagination = next
                reachedEnd = !next.hasNextPage
                publish(batch.kept, started: pageStarted)
                added += batch.kept.count
                loadingPlaceholderCount = max(0, loadingPlaceholderCount - batch.kept.count)
                if reachedEnd || added >= wanted { break }
            } catch {
                guard current == generation, !Task.isCancelled else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                if (error as? GraphQLFeedError)?.permitsBrowserFallback == true {
                    graphQLPagination = nil
                    usesBrowserFallback = true
                    let cards = await engine.loadCards(query.url)
                    guard current == generation, !Task.isCancelled else { return }
                    if case .failed(let message) = engine.state {
                        loadError = message
                        return
                    }
                    let batch = await nearby(cards)
                    guard current == generation, !Task.isCancelled else { return }
                    listings.append(contentsOf: batch.kept)
                    reachedEnd = isAnonymous
                    paginationPaused = !reachedEnd
                } else {
                    loadError = error.localizedDescription
                }
                return
            }
        }
        paginationPaused = !reachedEnd && added < wanted
        let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
        Logger.discover.info("top-up: pages=\(pages, privacy: .public) kept=\(added, privacy: .public) elapsed_ms=\(elapsed, privacy: .public) paused=\(self.paginationPaused, privacy: .public) end=\(self.reachedEnd, privacy: .public)")
    }

    func retryLoadingMore() async {
        guard !isLoading, !isLoadingMore, !reachedEnd else { return }
        if graphQLPagination == nil, loadError != nil {
            if let query = activeQuery { await loadIfNeeded(citySlug: query.citySlug, force: true) }
            return
        }
        loadError = nil
        await performTopUp()
    }

    private func publish(_ cards: [Listing], replacing: Bool = false, started: ContinuousClock.Instant) {
        if replacing { listings = cards } else if !cards.isEmpty { listings.append(contentsOf: cards) }
        let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
        Logger.discover.info("cards published: count=\(cards.count, privacy: .public) replace=\(replacing, privacy: .public) request_to_publish_ms=\(elapsed, privacy: .public)")
    }

    private func nearby(payload: [PayloadListing]) async -> (kept: [Listing], newCards: Int) {
        let current = generation
        var seen = browseSeen
        let parsed = payload.enumerated().compactMap { index, item -> Listing? in
            guard !item.isShippingOnly else { return nil }
            let listing = item.makeListing(cardIndex: index)
            guard seen.insert(listing.id).inserted else { return nil }
            return listing
        }
        let result = await withinRadius(parsed)
        guard current == generation, !Task.isCancelled else { return ([], 0) }
        browseSeen = seen
        return result
    }

    private func withinRadius(_ parsed: [Listing]) async -> (kept: [Listing], newCards: Int) {
        let started = ContinuousClock.now
        await distances.resolveAll(parsed.map(\.locationText))
        let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
        Logger.discover.info("distance resolution: cards=\(parsed.count, privacy: .public) geocode_ms=\(elapsed, privacy: .public)")
        let kept = parsed.filter { listing in
            guard let km = distances.distanceKM(for: listing.locationText,
                                                coordinate: distances.enrichedCoordinate(for: listing)) else { return false }
            return km <= Double(radiusKM)
        }
        return (kept, parsed.count)
    }

    /// Rendered cards, minus everything this feed shouldn't carry: duplicates,
    /// shipping-only listings, and anything outside the user's radius.
    ///
    /// The radius is applied here rather than left to the view, unlike every
    /// other list in the app. Facebook aims this feed, and it wanders — 20 cards
    /// across 11 cities on one measured load. Filtering downstream would page in
    /// twenty and show four, with no way for the fill to know to keep going.
    /// - Returns: what survived, and how many listings were new to this fill at
    ///   all. The caller needs both to tell "this area has run out" from "we are
    ///   re-reading the window the fill already took" — see `scrollForMore`.
    private func nearby(_ cards: [DesktopRawCard]) async -> (kept: [Listing], newCards: Int) {
        let current = generation
        var seen = browseSeen
        var parsed: [Listing] = []
        var unparsed = 0, ships = 0, dupes = 0
        var sample: DesktopRawCard?
        for (index, card) in cards.enumerated() {
            guard let listing = DesktopCardParser.parse(card, cardIndex: index) else {
                unparsed += 1
                // A count says a selector matched nothing; the sample says why.
                // Twice this project concluded "no data" from a selector that
                // was pointing at the wrong thing (`docs/probe-checklist.md` §2).
                if sample == nil { sample = card }
                continue
            }
            // The browse feed has no delivery filter to ask for, so this is the
            // only thing keeping shipping listings out.
            guard listing.badgeText != "Ships" else {
                ships += 1
                continue
            }
            guard seen.insert(listing.id).inserted else {
                dupes += 1
                continue
            }
            parsed.append(listing)
        }
        // Counted separately because "no new cards" has four causes here —
        // nothing rendered, nothing parsed, every id already taken, everything
        // too far — and they are indistinguishable downstream.
        let tally = "\(cards.count) raw, \(unparsed) unparsed, \(ships) ships, \(dupes) dupes"
        if let sample {
            Logger.discover.info("rejected card: id=\(sample.id, privacy: .public) label=[\(sample.label.prefix(90), privacy: .public)] img=\(!sample.imageURL.isEmpty, privacy: .public) text=[\(sample.text.replacingOccurrences(of: "\n", with: " ").prefix(90), privacy: .public)]")
        }
        guard !parsed.isEmpty else {
            Logger.discover.info("batch: \(tally, privacy: .public), 0 new")
            return ([], 0)
        }

        let result = await withinRadius(parsed)
        guard current == generation, !Task.isCancelled else { return ([], 0) }
        browseSeen = seen
        Logger.discover.info("batch: \(tally, privacy: .public), \(parsed.count, privacy: .public) new, \(result.kept.count, privacy: .public) in radius")
        return result
    }

    /// Drops the "already filled" flag without touching what's on screen, for a
    /// change of city. The cards stay up until the next fill replaces them —
    /// blanking the screen the moment a preference changes is worse than stale.
    func markStale() {
        generation += 1
        graphQLRequest?.cancel()
        hasLoaded = false
        isLoading = false
        isLoadingMore = false
        paginationPaused = false
        graphQLPagination = nil
        loadingPlaceholderCount = 0
        reachedEnd = true
    }

    /// What the section header says the feed is. Carries the app's only
    /// disclosure of the distance filter, so it names the radius.
    var caption: String {
        let place = prefs.locationName ?? "you"
        return "Facebook Marketplace, within \(SearchQuery.kilometresToMiles(radiusKM)) mi of \(place)"
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
