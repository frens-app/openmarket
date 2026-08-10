import Foundation
import WebKit
import os

/// The home screen's feed. **Two of them, and which one you get depends on
/// whether you are signed in.**
///
/// Signed in, this browses Facebook's own Marketplace feed for the user's place
/// — the default Discover screen, scrolled — and filters it to the radius the
/// user set. Signed out, it runs a few of the user's own recent searches and
/// mixes the results.
///
/// **The split is the design, not a fallback.** Facebook's feed was tried once
/// before, logged out, and removed: three loads of the identical URL in one
/// session gave 0 of 5 top cards in common between the first and second, 17 of
/// 20 between the second and third, and a fourth that reverted to the first's
/// contents. The geography swung with it, from 9-of-20 in San Francisco to an
/// East Bay spread reaching Napa and Antioch, 50 mi out. It read as a couple of
/// cached popularity pools being alternated — which is about all it could be,
/// since an anonymous session gives Facebook an IP, a cookie, and nothing else
/// to rank with.
///
/// An account changes that input completely. Facebook is ranking against a real
/// history, which is more than this app can assemble out of search terms on the
/// device, and the feed scrolls indefinitely instead of stopping at three
/// searches' worth of cards. So the signed-in user gets the real thing, and the
/// signed-out user gets the local substitute — which is also the honest place
/// for a nudge to sign in, since signing in visibly improves the screen.
///
/// **The searches, for the signed-out half.** Recent searches are the one strong
/// statement of interest anyone makes here, so this runs a few and mixes the
/// results. Before there is any history the seeds are the interests picked
/// during onboarding (`Interest`, `OnboardingView`) — that is what the required
/// three-interest step is for. What it loses is novelty: it cannot show you
/// something in a category you have never asked about or picked.
///
/// **Its own engines**, one per search, for the reason `ComparableSearch` has
/// one: sharing the browse tab's would mean the home feed and the user's first
/// search taking turns navigating one webview. One each means the searches
/// overlap instead of queueing, so a fill is about as long as its slowest page
/// rather than the sum of three. No extra request budget either — `RequestPacer`
/// is a shared actor and still spaces the starts. The browse feed needs only the
/// first of them: it is one page, scrolled.
///
/// **A fill publishes once, when all of it is in.** The grid used to arrive in
/// three instalments and reflow twice under whoever was reading it. Cards moving
/// out from under a thumb is the one thing a feed must not do, and staging the
/// wait made it look longer than it was. Pagination is exempt — it appends below
/// what is already on screen, which moves nothing.
///
/// **Session-scoped, and nothing is written to disk.** The feed survives moving
/// between tabs and opening listings, and is rebuilt when the app is launched
/// again, when the user pulls to refresh, or when the session changes — that
/// last one because the session decides which of the two feeds this even is.
@MainActor
final class DiscoverFeed: ObservableObject {
    /// Which feed is on screen. Published because the screen's footer differs:
    /// a search-seeded feed ends in an offer to sign in, and the browse feed
    /// ends when the area runs out.
    enum Mode: Equatable {
        /// Facebook's own Marketplace feed, scrolled. Signed in.
        case browse
        /// The user's recent searches and interests, re-run and mixed.
        case searches
    }

    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    /// Scrolling the browse feed for more, with cards already on screen.
    @Published private(set) var isLoadingMore = false
    @Published private(set) var mode: Mode = .searches
    /// Whether there is any point scrolling further. Always true for the
    /// search-seeded feed, which is a fixed set of cards by construction.
    @Published private(set) var reachedEnd = false
    /// What this feed was built from, so the screen can say so. A feed
    /// assembled out of someone's history should admit which parts of it.
    @Published private(set) var seeds: [Seed] = []

    /// One search behind the feed, and where it came from.
    ///
    /// The origin is carried rather than inferred because it changes what the
    /// screen can honestly claim: "from your searches for lamp · desk" is a
    /// statement about the user's own history, and on a new install — where
    /// there is no history — the same sentence would be a lie about a list they
    /// picked off a menu thirty seconds ago.
    struct Seed: Equatable, Identifiable {
        enum Origin: Equatable { case search, interest }

        /// What gets searched.
        let term: String
        /// What the screen prints. Differs from `term` for interests, whose
        /// label is a category and whose term is what a listing might say.
        let label: String
        let origin: Origin

        var id: String { "\(origin)-\(term)" }
    }

    /// How many searches one fill runs. Three is a judgement, not a
    /// measurement: enough for the mix to feel like more than one topic,
    /// few enough that a fill is three page loads rather than a crawl.
    static let searchCount = 3
    /// How many cards to keep from each. Taken *after* shuffling the search's
    /// results, so this is a random sample of what came back rather than its
    /// top ten — otherwise Discover would be the first rows of three searches,
    /// which the user could have got by running them.
    static let perSearch = 10

    /// How many in-radius cards the browse feed tries to have in hand before it
    /// publishes, and how many each top-up aims to add.
    ///
    /// It has to be a target rather than a page count because the two numbers
    /// are not related: Facebook's feed reaches wherever it feels like reaching,
    /// and one measured browse load returned 20 cards across 11 cities, of which
    /// a 6 mi radius kept 9. Paging once and showing what survived would make a
    /// half-empty screen look like the whole of what's nearby.
    static let browseTarget = 12
    /// How many screens one harvest may scroll in total, and how many of those
    /// may turn up new listings that are *all* too far before it gives up.
    ///
    /// The first is a time bound — a screen costs ~0.9s of settling. The second
    /// is the end-of-area test, and it counts a very specific thing: screens
    /// that produced new listings, none of which were close enough. A screen
    /// that produced no new listings at all is **not** counted, because it is
    /// not evidence of anything.
    ///
    /// That distinction is the whole of it. The feed virtualises, and a fill has
    /// already taken every card in the DOM, so the first several screens of a
    /// top-up re-read cards we have seen and legitimately yield nothing.
    /// Counting those as dry ended the feed after 2644px of a 6650px document —
    /// measured, signed in, with the feed still happily paginating.
    static let scrollBudget = 14
    static let dryScreenLimit = 4

    /// How many cards from the end a top-up starts.
    ///
    /// Ten is roughly two screens of a two-column grid, and it is chosen against
    /// the cost of the fetch rather than the length of the feed: a top-up is a
    /// webview scrolled a screen at a time at ~0.9s a screen, so a trigger three
    /// cards from the bottom guarantees the spinner is seen. Two screens of
    /// runway is enough for a normal scroll to arrive after the cards do.
    ///
    /// This is not a read-ahead cache. Nothing is fetched that the user was not
    /// already scrolling towards, and see `scrolledSinceLastTopUp` for what
    /// stops the margin from turning into a treadmill.
    static let prefetchMargin = 10

    /// One engine per search, so the searches can run at the same time.
    ///
    /// They can't share one. An engine is a single `WKWebView` with a single
    /// in-flight navigation, and the markup fallback reads whatever document is
    /// currently loaded in it — three concurrent searches through one engine
    /// would be three navigations fighting over one page and reading each
    /// other's cards.
    ///
    /// The cost is two more hidden webviews resident for the app's lifetime.
    /// Worth it: a fill was three page loads end to end, and the screen has
    /// nothing to show until it finishes, so that time was the entire wait on
    /// the home screen. Concurrent, it is roughly one load. No extra request
    /// budget either — `RequestPacer` is shared and still spaces the starts.
    private let engines: [DesktopFeedEngine]
    private let prefs: Preferences
    private let distances: DistanceResolver
    private var hasLoaded = false
    /// Which session the current cards were fetched under, so a sign-in or a
    /// sign-out rebuilds the feed rather than leaving the wrong one up. Not the
    /// same question as "has it loaded": the session decides *which feed this
    /// is*, so a stale answer here is a screen that belongs to somebody else.
    private var filledUnder: BrowserSession?
    /// Listing ids already taken from the browse feed this fill.
    ///
    /// Held across scrolls rather than recomputed, because the desktop feed
    /// virtualises: every harvest returns the cards currently in the DOM, which
    /// overlaps heavily with the last one.
    private var browseSeen = Set<String>()

    /// All of them have to be in the view hierarchy for WebKit to render them —
    /// see `RootView`. Same constraint as every other engine.
    var webViews: [WKWebView] { engines.map(\.webView) }

    init(engines: [DesktopFeedEngine]? = nil,
         prefs: Preferences = .shared,
         distances: DistanceResolver = .shared) {
        self.engines = engines ?? (0..<Self.searchCount).map { _ in DesktopFeedEngine() }
        self.prefs = prefs
        self.distances = distances
    }

    /// Fills once per launch. `force` is the pull-to-refresh path.
    ///
    /// It also refills when the session has changed since the last fill, which
    /// is not the same kind of trigger as the others: signing in doesn't make
    /// the feed *stale*, it makes it the wrong feed entirely.
    ///
    /// Note what is *not* a trigger: running a search. Recent searches seed the
    /// signed-out feed, so every search would otherwise invalidate the screen
    /// the user is about to come back to — they'd return from a search to one
    /// that had thrown itself away and was reloading. The new term is picked up
    /// by the next launch, or by a pull.
    func loadIfNeeded(citySlug: String, force: Bool = false) async {
        guard !isLoading else { return }
        // Read from the cookie store rather than taken from the caller. The
        // session is what picks the feed, and `ListingStore.session` is set by
        // an async check that may not have landed yet on the launch this screen
        // fills on — starting the wrong feed and marking it done would leave a
        // signed-in user looking at the signed-out one until they relaunched.
        let session: BrowserSession = await SessionState.isSignedIn() ? .authed : .unauthed
        // Re-checked after the await: this is a `@MainActor` method, and an
        // await lets the next caller in. `RequestPacer` learned the same lesson
        // the expensive way.
        guard !isLoading, force || !hasLoaded || session != filledUnder else { return }

        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
            filledUnder = session
        }

        reachedEnd = false
        deepestIndexSeen = -1
        mode = session == .authed ? .browse : .searches
        switch mode {
        case .browse: await fillFromMarketplace(citySlug: citySlug)
        case .searches: await fillFromSearches(citySlug: citySlug)
        }
    }

    /// Signed in: Facebook's own Marketplace feed for this place, cut to the
    /// user's radius.
    ///
    /// One engine and one page — this is a scroll, not three searches — so the
    /// other two sit idle for as long as the session lasts. Cheaper than it
    /// looks: they are already resident for the app's lifetime, and a sign-out
    /// puts them straight back to work.
    private func fillFromMarketplace(citySlug: String) async {
        guard let engine = engines.first else { return }
        seeds = []
        browseSeen = []

        let query = SearchQuery(kind: .browse, radiusKM: prefs.radiusKM,
                                citySlug: citySlug, coordinate: nil)
        let cards = await engine.loadCards(query.url)

        // A wall on the feed of a session we believe is signed in means the
        // cookies outlived whatever Facebook does with them. Fall back to the
        // signed-out feed rather than showing an empty screen and blaming the
        // neighbourhood for it — and take its footer with it, since "log in"
        // is the accurate next step for a session that has stopped working.
        if engine.state == .loginWall {
            Logger.discover.info("login wall on the browse feed — falling back to searches")
            mode = .searches
            await fillFromSearches(citySlug: citySlug)
            return
        }

        var collected = await nearby(cards).kept
        // Only if the first screen didn't already carry enough. A fill that can
        // publish immediately should, since this is the screen the app opens on.
        if collected.count < Self.browseTarget {
            let harvest = await scrollForMore(engine, wanted: Self.browseTarget - collected.count)
            collected += harvest.cards
            reachedEnd = harvest.exhausted
        }
        // One assignment, as with the search path: a pull-to-refresh keeps the
        // old cards exactly where they are until the new feed is ready.
        listings = collected
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from Marketplace, end=\(self.reachedEnd, privacy: .public)")
    }

    /// Signed out: the user's own recent searches, re-run and mixed.
    private func fillFromSearches(citySlug: String) async {
        let seeds = Self.seeds(recent: prefs.recentSearches, interests: prefs.chosenInterests)
        self.seeds = seeds
        // A fixed set of cards — there is no page two of three searches — so
        // this feed is at its end the moment it lands.
        reachedEnd = true

        // All searches at once, one engine each, and nothing is published until
        // every one of them is back.
        //
        // This used to run them one after another and republish after each, so
        // the grid arrived in three instalments and reflowed twice under
        // whoever was already reading it. Cards moved out from under a thumb —
        // which is the one thing a feed must not do — and it made the wait
        // *look* longer than it was by drawing attention to each stage of it.
        //
        // `Task {}` inherits this actor, so the three bodies interleave at their
        // awaits rather than running truly in parallel: the page loads overlap,
        // which is where the time goes, and nothing touches shared state
        // concurrently.
        let tasks = zip(seeds, engines).map { seed, engine in
            Task { await self.batch(for: seed.term, using: engine, citySlug: citySlug) }
        }
        var buckets: [[Listing]] = []
        for task in tasks {
            buckets.append(await task.value)
        }
        let mixed = Self.interleave(buckets)
        // Every place geocoded before the feed is published, so the distance
        // filter has already run by the time anything is drawn and the grid
        // can't shrink underneath a reader (`DistanceResolver.resolveAll`).
        // Part of the same fill for the same reason the searches are: this
        // screen shows nothing until all of it is ready.
        await distances.resolveAll(mixed.map(\.locationText))
        // Replaced in one assignment, which is also what keeps a pull-to-refresh
        // honest: the old cards stay exactly where they are until the whole new
        // feed is ready to take their place.
        listings = mixed
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from \(seeds.count, privacy: .public) searches")
    }

    /// Whether the user has moved the feed since the last batch landed.
    ///
    /// The gate on the read-ahead, and the reason a two-screen margin doesn't
    /// become an automatic crawl down Facebook's entire feed. `prefetchMargin`
    /// alone would re-arm the instant a batch arrived — the card that triggered
    /// it is still within ten of the new end — so the feed would page forever
    /// under a screen nobody is touching. Requiring a fresh drag per batch keeps
    /// §7.3's pacing rule intact: one page ahead, and only for someone still
    /// reading. A finger already dragging when a batch lands re-arms it
    /// immediately, which is correct — that is a fast scroller, not a treadmill.
    private var scrolledSinceLastTopUp = false

    /// How far down the feed the user has been, as an index into `listings`.
    ///
    /// Tracked because a card announces itself exactly once: `.task` fires when
    /// the lazy stack *creates* a cell and never again, so the margin can only
    /// be tested at the moment a cell happens to be built — which is not the
    /// moment the answer changes. Remembering the depth makes it testable
    /// whenever, which is what lets a drag re-check it. Reset with the feed,
    /// never on append: a top-up lands below everything already scrolled past.
    private var deepestIndexSeen = -1

    /// Called when the user drags the feed. See `scrolledSinceLastTopUp`.
    ///
    /// Arming re-checks the margin, and that re-check is the whole of the bug
    /// that made this gate look broken. The card that triggers top-up N+1 is
    /// built *the instant top-up N lands* — three cards into a batch of twelve,
    /// well inside the lazy stack's build-ahead — and at that instant the gate
    /// has just closed. It announced itself to a closed gate, and a cell is only
    /// built once, so it never announced itself again: the feed stopped paging
    /// for good. Re-arming while already armed is a no-op, so a drag firing this
    /// continuously still costs one check.
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

    /// More of Facebook's feed, about two screens from the bottom.
    ///
    /// Only the browse feed has a bottom worth reaching for. The search-seeded
    /// one is a fixed sample of three searches, so there is nothing to fetch.
    private func topUpIfAtMargin() async {
        guard mode == .browse, !reachedEnd, !isLoading, !isLoadingMore,
              scrolledSinceLastTopUp,
              let engine = engines.first,
              deepestIndexSeen >= listings.count - Self.prefetchMargin else { return }

        isLoadingMore = true
        // Spent here rather than on completion: the next batch has to be earned
        // by scrolling through this one, and the scrolling done to reach the
        // trigger has already been spent reaching it.
        scrolledSinceLastTopUp = false
        defer { isLoadingMore = false }
        Logger.discover.info("""
            top-up: at \(self.deepestIndexSeen, privacy: .public) \
            of \(self.listings.count, privacy: .public)
            """)

        let harvest = await scrollForMore(engine, wanted: Self.browseTarget)
        // Appended, never reassigned. New cards land below everything already
        // on screen, so nothing moves under whoever is reading.
        listings.append(contentsOf: harvest.cards)
        reachedEnd = harvest.exhausted
    }

    /// Scrolls the browse feed a screen at a time, keeping what is inside the
    /// radius, until it has `wanted` of them or there is no point continuing.
    ///
    /// Harvesting *between* scrolls rather than once at the end is not
    /// defensive: the desktop feed virtualises, recycling cards out of the DOM
    /// as they leave the viewport, so a single read at the bottom returns the
    /// last window rather than the feed (`docs/logged-in-findings.md` §3).
    ///
    /// `exhausted` means "stop asking", and it has two causes worth telling
    /// apart in the log but not in the UI: the document stopped growing, which
    /// is the literal end of the feed, or several screens in a row carried
    /// nothing within the radius, which is the end of the part of it that this
    /// app is for. Running out of scroll budget is neither — it is just this
    /// call's turn ending, and the next one picks up where it left off.
    private func scrollForMore(_ engine: DesktopFeedEngine,
                               wanted: Int) async -> (cards: [Listing], exhausted: Bool) {
        var found: [Listing] = []
        var dryScreens = 0
        var screens = 0

        while found.count < wanted, dryScreens < Self.dryScreenLimit, screens < Self.scrollBudget {
            screens += 1
            guard await engine.scrollOnce() else {
                Logger.discover.info("browse feed stopped growing after \(screens, privacy: .public) screens")
                return (found, true)
            }
            let batch = await nearby(await engine.renderedCards())
            found += batch.kept
            // Only a screen that turned up something new and rejected all of it
            // counts against the area. Re-reading cards the fill already took
            // says nothing about how much is out there.
            if batch.newCards > 0 {
                dryScreens = batch.kept.isEmpty ? dryScreens + 1 : 0
            }
        }

        let exhausted = dryScreens >= Self.dryScreenLimit
        Logger.discover.info("harvest: \(found.count, privacy: .public) kept over \(screens, privacy: .public) screens, dry \(dryScreens, privacy: .public), exhausted \(exhausted, privacy: .public)")
        return (found, exhausted)
    }

    /// Rendered cards, minus everything this feed shouldn't carry: duplicates,
    /// shipping-only listings, and anything outside the user's radius.
    ///
    /// **The radius is applied here rather than left to the view**, which is the
    /// difference between this feed and every other list in the app. Everywhere
    /// else the app fetches a page and the view hides what's too far; that works
    /// when the page is a search the user aimed at their own city. Facebook's
    /// feed is aimed by Facebook, and it wanders — 20 cards across 11 cities on
    /// one measured load. Filtering downstream of the fetch would page in twenty
    /// and show four, with no way for the fill to know it should keep going.
    /// Knowing it here is what lets a fill scroll until it has enough.
    ///
    /// Listings whose distance isn't known are **kept**, same rule as the grid:
    /// geocoding is asynchronous and lossy, and filtering on missing data hides
    /// listings for being unrecognised rather than for being far away.
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
                // What a rejected card actually looked like. A count of
                // failures says a selector matched nothing; the sample says
                // *why*, and this project has twice concluded "no data" from a
                // selector that was simply pointing at the wrong thing
                // (`docs/probe-checklist.md` §2).
                if sample == nil { sample = card }
                continue
            }
            // A local marketplace's home screen isn't a shipping catalogue. The
            // browse feed has no delivery filter to ask for, so this is the only
            // thing keeping them out.
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
        // Every stage counted separately. "No new cards" has four different
        // causes here — nothing rendered, labels not hydrated so nothing parsed,
        // every id already taken, everything too far — and they are
        // indistinguishable downstream while looking identical to the user.
        // Lumping the middle two together already cost one wrong diagnosis.
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
                // **Unknown distance is dropped here**, which is the opposite of
                // the rule everywhere else in the app. Everywhere else the list
                // is a search Facebook already localised, so an unresolved place
                // is probably nearby and hiding it would punish a card for being
                // unrecognised. This feed is not localised in any comparable
                // sense — it reaches across state lines, and a signed-in Seattle
                // feed served Vancouver WA, Bellingham, Wilsonville OR and a
                // cardboard cutout in Citrus Heights, California — so here an
                // unresolved place is far more likely to be far away.
                //
                // Safe to drop rather than defer because `resolveAll` above has
                // already had its turn: this runs after geocoding, not during,
                // so the card never enters the feed and nothing vanishes from
                // under a reader later.
                return false
            }
            return km <= Double(prefs.radiusKM)
        }
        Logger.discover.info("batch: \(tally, privacy: .public), \(parsed.count, privacy: .public) new, \(kept.count, privacy: .public) in radius")
        return (kept, parsed.count)
    }

    /// Drops the "already filled" flag without touching what's on screen.
    ///
    /// For a change that makes the current feed answer the wrong question —
    /// editing interests in Settings, and nothing else so far. The cards stay
    /// up until the next fill replaces them, because blanking a screen the
    /// moment a preference changes is a worse answer than a stale one.
    func markStale() { hasLoaded = false }

    /// What to search for: the user's own recent terms first, topped up from
    /// the interests they chose during onboarding.
    ///
    /// That order is the whole design. A search is the strongest statement of
    /// intent anyone makes in this app and it is about *now*; an interest is a
    /// standing statement made once, and its job is to answer the question "what
    /// should the first screen be" for someone who has not searched yet. So
    /// interests fill the gap and recede as the history grows — a user with
    /// three recent searches never sees an interest-seeded row again until they
    /// clear their history.
    ///
    /// Interests are shuffled because there are usually more than three of them
    /// and the array is in the order they were tapped: taking the first three
    /// every launch would make the last-picked interests decorative.
    static func seeds(recent: [String], interests: [Interest]) -> [Seed] {
        var out: [Seed] = []
        func add(_ seed: Seed) {
            let term = seed.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty, out.count < searchCount,
                  !out.contains(where: { $0.term.caseInsensitiveCompare(term) == .orderedSame }) else { return }
            out.append(seed)
        }
        recent.forEach { add(Seed(term: $0, label: $0, origin: .search)) }
        interests.shuffled().forEach {
            add(Seed(term: $0.term, label: $0.label, origin: .interest))
        }
        return out
    }

    /// What the section header says it was built from — or nil when there is
    /// nothing to describe yet.
    ///
    /// Load-bearing, not decoration: a shuffled feed with no stated basis is
    /// indistinguishable from a random one, which is exactly the complaint that
    /// got the previous version of this screen deleted.
    ///
    /// The browse feed states its *radius* rather than its basis, because the
    /// basis is "Facebook's feed" and the radius is the one thing this app did
    /// to it. It also carries the only remaining disclosure of the distance
    /// filter, now that the footer counting what it removed is gone — a caption
    /// beside the heading is where someone who scrolls until something catches
    /// their eye will actually read it, which the footer never was.
    var caption: String? {
        if mode == .browse {
            let place = prefs.locationName ?? "you"
            guard prefs.radiusKM > 0 else { return "Facebook Marketplace, near \(place)" }
            return "Facebook Marketplace, within \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi of \(place)"
        }
        guard !seeds.isEmpty else { return nil }
        let names = seeds.map(\.label).joined(separator: " · ")
        switch (seeds.contains { $0.origin == .search }, seeds.contains { $0.origin == .interest }) {
        case (true, false): return "From your searches for \(names)"
        case (false, true): return "From your interests: \(names)"
        default: return "From your searches and interests: \(names)"
        }
    }

    /// One search's contribution: a random sample of its results.
    ///
    /// Takes its engine rather than reaching for a shared one, because the
    /// markup fallback below reads the document that engine is *currently*
    /// showing — the one thing that would go wrong if these ran concurrently
    /// through one webview.
    ///
    /// Cross-search dedupe is not done here any more. It can't be: the searches
    /// no longer finish in a defined order, so a set threaded through them would
    /// decide which of two identical cards survives by whichever page happened
    /// to load first. `interleave` does it instead, in seed order, where the
    /// answer is the same every time.
    private func batch(for term: String,
                       using engine: DesktopFeedEngine,
                       citySlug: String) async -> [Listing] {
        let payload = await engine.load(query(for: term, citySlug: citySlug))
        var parsed = payload.enumerated().map { index, item in item.makeListing(cardIndex: index) }
        // Same fallback as everywhere else: a page served entirely client-side
        // renders cards with no embedded listing block behind them, and the
        // markup carries everything a card needs.
        if parsed.isEmpty {
            parsed = await engine.renderedCards().enumerated()
                .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }
        }

        // Ships-only cards are not what a local marketplace's home screen is
        // for. Only the markup path sets this badge, so it catches the tail
        // rather than everything — the query's delivery filter is what does the
        // real work when the user has one set.
        let kept = parsed.filter { $0.badgeText != "Ships" }
        return Array(kept.shuffled().prefix(Self.perSearch))
    }

    /// The same query a search for this term would build, filters and all.
    ///
    /// Deliberately the user's own filters rather than a neutral set: this feed
    /// claims to be built from what they search for, and a Discover that
    /// quietly ignored their delivery method or price range would be showing
    /// them results their own search wouldn't.
    private func query(for term: String, citySlug: String) -> SearchQuery {
        SearchQuery(
            kind: .search(term),
            // Sent for shape only; no surface filters on it logged out, and
            // signed in the account's own setting wins (`docs/filter-parameters.md`
            // §3, §11). Distance is applied on-device.
            radiusKM: prefs.radiusKM == 0 ? 40 : prefs.radiusKM,
            citySlug: citySlug,
            coordinate: nil,
            sort: prefs.sort,
            delivery: prefs.delivery,
            conditions: prefs.conditions,
            minPrice: prefs.minPrice,
            maxPrice: prefs.maxPrice
        )
    }

    /// Round-robin across the searches, so the mix is visible from the first
    /// row rather than being three blocks stacked on each other. Each bucket is
    /// already shuffled, so this is a mixed sample and not an interleaved
    /// ranking.
    ///
    /// Also where a listing found by two searches is dropped — first occurrence
    /// wins, and "first" is by seed order, so the result doesn't depend on which
    /// page finished loading first.
    static func interleave(_ buckets: [[Listing]]) -> [Listing] {
        var out: [Listing] = []
        var seen = Set<String>()
        let depth = buckets.map(\.count).max() ?? 0
        for index in 0..<depth {
            for bucket in buckets where index < bucket.count {
                let listing = bucket[index]
                guard seen.insert(listing.id).inserted else { continue }
                out.append(listing)
            }
        }
        return out
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
