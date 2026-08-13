import Foundation
import WebKit
import os

/// Facebook's own Marketplace feed for the user's place, scrolled and cut to
/// the radius they set.
///
/// The session decides whether the feed scrolls. Signed in it pages
/// indefinitely; anonymous it is a single page, because Facebook serves ~20
/// cards to a session it doesn't recognise and then never loads more
/// (`docs/feasibility-2026-07-31.md` §9.1). Logged out it is a rotating
/// popularity pool rather than a recommendation, which is why the caption
/// claims only "what Facebook is showing near you" (`docs/discover.md` §3).
///
/// Owns its engine so the home feed and the user's first search don't take
/// turns navigating one webview. `RequestPacer` is a shared actor, so this
/// buys no extra request budget.
///
/// Session-scoped; nothing is written to disk. Rebuilt on launch, pull to
/// refresh, a city change, or a session change.
@MainActor
final class DiscoverFeed: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    /// Scrolling for more, with cards already on screen.
    @Published private(set) var isLoadingMore = false
    /// Slots reserved for the first row of the top-up currently being harvested.
    ///
    /// Each filtered WebView window can contain only one nearby card. Reducing
    /// this count as the first cards arrive lets them replace skeletons at the
    /// same grid positions. Refreshes do not reserve slots because their old
    /// grid stays up.
    @Published private(set) var loadingPlaceholderCount = 0
    /// Whether this session cannot scroll further.
    ///
    /// Only anonymous and login-walled sessions are terminal. A signed-in
    /// harvest that hits its dry-screen budget has learned nothing conclusive
    /// and stays retryable on the next user drag.
    @Published private(set) var reachedEnd = false
    /// Whether the cards on screen were fetched without a working account.
    ///
    /// Not the same question as "is the user signed in" — a session whose
    /// cookies have stopped working walls this page too, and the accurate next
    /// step there is also a login.
    @Published private(set) var isAnonymous = true

    /// How many in-radius cards a signed-in fill tries to have in hand before
    /// it finishes, and how many each top-up aims to add.
    ///
    /// A target rather than a page count: Facebook's feed reaches wherever it
    /// likes, and one measured load returned 20 cards across 11 cities of which
    /// a 6 mi radius kept 9.
    static let browseTarget = 12
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

    init(engine: DesktopFeedEngine? = nil,
         prefs: Preferences = .shared,
         distances: DistanceResolver = .shared) {
        self.engine = engine ?? DesktopFeedEngine()
        self.prefs = prefs
        self.distances = distances
    }

    /// Fills once per launch. `force` is the pull-to-refresh path. Also refills
    /// when the session changed, since signing in makes Facebook serve a
    /// different page.
    func loadIfNeeded(citySlug: String, force: Bool = false) async {
        guard !isLoading else { return }
        // From the cookie store rather than the caller: `ListingStore.session`
        // is set by an async check that may not have landed on the launch this
        // screen fills on.
        let session: BrowserSession = await SessionState.isSignedIn() ? .authed : .unauthed
        // Re-checked after the await — this is `@MainActor`, and an await lets
        // the next caller in.
        guard !isLoading, force || !hasLoaded || session != filledUnder else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
            filledUnder = session
        }

        reachedEnd = false
        deepestIndexSeen = -1
        let startedAt = Date()
        let isRefresh = hasLoaded
        await fill(citySlug: citySlug, session: session)

        // Here rather than in the view, which is too late to tell "empty"
        // from "walled". A handful per session at most: a launch, a refresh, a
        // change of city.
        Analytics.capture(.discoverLoaded, [
            "count": listings.count,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "is_anonymous": isAnonymous,
            "reached_end": reachedEnd,
            "is_refresh": isRefresh,
            "radius_km": prefs.radiusKM
        ])
    }

    /// Facebook's Marketplace feed for this place, cut to the user's radius.
    private func fill(citySlug: String, session: BrowserSession) async {
        browseSeen = []

        let query = SearchQuery(kind: .browse, radiusKM: prefs.radiusKM,
                                citySlug: citySlug, coordinate: nil)
        let cards = await engine.loadCards(query.url)

        // A wall means the same thing whichever session we asked under: nothing
        // more to scroll for, and a login is the accurate next step.
        let walled = engine.state == .loginWall
        if walled { Logger.discover.info("login wall on the browse feed") }
        isAnonymous = walled || session == .unauthed

        var collected = await nearby(cards).kept
        // Nothing is on screen during the first fill, so publish the first
        // usable page now and let any radius top-up append below it. Pull to
        // refresh deliberately keeps the old feed stable until the replacement
        // is complete.
        let publishesProgressively = listings.isEmpty
        if publishesProgressively, !collected.isEmpty {
            listings = collected
            Logger.discover.info("initial batch published: \(self.listings.count, privacy: .public) cards")
        }
        // Anonymous is one page. Scrolling it was measured at five screens that
        // advanced 0→2410px of a 3188px container with the card count stuck at
        // 20 the whole way — six seconds spent on nothing.
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
            collected += harvest
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
    /// The gate on the read-ahead. `prefetchMargin` alone would re-arm the
    /// instant a batch arrived — the card that triggered it is still within ten
    /// of the new end — so the feed would page forever under a screen nobody is
    /// touching. One fresh drag per batch keeps it to one page ahead, and only
    /// for someone still reading.
    private var scrolledSinceLastTopUp = false

    /// How far down the feed the user has been, as an index into `listings`.
    ///
    /// Tracked because `.task` fires when the lazy stack *creates* a cell and
    /// never again, so the margin could otherwise only be tested at the moment
    /// a cell happens to be built. Remembering the depth is what lets a drag
    /// re-check it. Reset with the feed, never on append.
    private var deepestIndexSeen = -1

    /// Called when the user drags the feed. See `scrolledSinceLastTopUp`.
    ///
    /// Arming re-checks the margin, which matters because the card that
    /// triggers top-up N+1 is built the instant top-up N lands — inside the
    /// lazy stack's build-ahead, when the gate has just closed. Without the
    /// re-check it announced itself once to a closed gate and the feed stopped
    /// paging for good. Re-arming while already armed is a no-op.
    func noteScroll() {
        guard !scrolledSinceLastTopUp else { return }
        scrolledSinceLastTopUp = true
        Task { await topUpIfAtMargin() }
    }

    /// Records how far the user has reached, then asks whether that is far
    /// enough. Called from each card as it is built.
    func loadMoreIfNeeded(currentItem: Listing) async {
        guard let index = listings.firstIndex(of: currentItem) else { return }
        deepestIndexSeen = max(deepestIndexSeen, index)
        await topUpIfAtMargin()
    }

    /// More of Facebook's feed, about two screens from the bottom. Never runs
    /// for an anonymous session — `fill` ends that feed where it lands.
    private func topUpIfAtMargin() async {
        guard !reachedEnd, !isLoading, !isLoadingMore,
              scrolledSinceLastTopUp,
              deepestIndexSeen >= listings.count - Self.prefetchMargin else { return }

        isLoadingMore = true
        loadingPlaceholderCount = Self.loadingReservation
        // Spent here rather than on completion: the next batch has to be earned
        // by scrolling through this one.
        scrolledSinceLastTopUp = false
        Logger.discover.info("""
            top-up: at \(self.deepestIndexSeen, privacy: .public) \
            of \(self.listings.count, privacy: .public)
            """)

        await scrollForMore(wanted: Self.browseTarget, publishAsHarvested: true)
        loadingPlaceholderCount = 0
        isLoadingMore = false

        // A drag during the harvest is a queued request, not a no-op:
        // `noteScroll` can't start one while `isLoadingMore` is true, and a dry
        // harvest appends no cell whose `.task` could re-check the margin.
        if scrolledSinceLastTopUp {
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
    /// Every stop condition ends only this attempt; the next user drag may try
    /// again from the current position. Anonymous feeds never enter this method.
    /// - Parameter publishAsHarvested: Publishes enough cards to replace the
    ///   reserved skeletons immediately, then coalesces later sparse windows
    ///   into complete grid rows. Refreshes instead collect in memory and
    ///   replace their existing grid once.
    @discardableResult
    private func scrollForMore(wanted: Int,
                               publishAsHarvested: Bool = false) async -> [Listing] {
        var found: [Listing] = []
        var staged: [Listing] = []
        var dryScreens = 0
        var screens = 0

        harvest: while found.count < wanted,
                       dryScreens < Self.dryScreenBudget,
                       screens < Self.scrollBudget {
            screens += 1
            switch await engine.scrollOnce() {
            case .advanced:
                break
            case .exhausted:
                Logger.discover.info("harvest reached the confirmed end on screen \(screens, privacy: .public)")
                break harvest
            case .indeterminate:
                Logger.discover.info("harvest paused after an inconclusive scroll on screen \(screens, privacy: .public)")
                break harvest
            }
            let batch = await nearby(await engine.renderedCards())
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
            guard browseSeen.insert(listing.id).inserted else {
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

        await distances.resolveAll(parsed.map(\.locationText))
        guard prefs.radiusKM > 0 else { return (parsed, parsed.count) }
        let kept = parsed.filter { listing in
            let coordinate = distances.enrichedCoordinate(for: listing)
            guard let km = distances.distanceKM(for: listing.locationText,
                                                coordinate: coordinate) else {
                // Unknown distance is dropped here, the opposite of the rule
                // elsewhere. Other lists are searches Facebook already
                // localised, so an unresolved place is probably nearby. This
                // feed reaches across state lines — a signed-in Seattle feed
                // served Bellingham, Wilsonville OR and Citrus Heights CA — so
                // an unresolved place is more likely far away. Safe to drop
                // rather than defer: `resolveAll` above has already run, so
                // nothing vanishes from under a reader later.
                return false
            }
            return km <= Double(prefs.radiusKM)
        }
        Logger.discover.info("batch: \(tally, privacy: .public), \(parsed.count, privacy: .public) new, \(kept.count, privacy: .public) in radius")
        return (kept, parsed.count)
    }

    /// Drops the "already filled" flag without touching what's on screen, for a
    /// change of city. The cards stay up until the next fill replaces them —
    /// blanking the screen the moment a preference changes is worse than stale.
    func markStale() { hasLoaded = false }

    /// What the section header says the feed is. Carries the app's only
    /// disclosure of the distance filter, so it names the radius.
    var caption: String {
        let place = prefs.locationName ?? "you"
        guard prefs.radiusKM > 0 else { return "Facebook Marketplace, near \(place)" }
        return "Facebook Marketplace, within \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi of \(place)"
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
