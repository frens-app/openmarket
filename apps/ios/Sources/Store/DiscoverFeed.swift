import Foundation
import WebKit
import os

/// The home screen's feed: Facebook's own Marketplace feed for the user's place
/// — the default Discover screen — scrolled, and cut to the radius the user set.
///
/// **One feed now, whether or not there is an account behind it.** There used
/// to be two, and the signed-out half re-ran up to three of the user's own
/// recent searches and mixed the results. It is gone, and what it cost is worth
/// stating: three page loads before anything could be drawn, a feed that could
/// only ever show categories the user had already asked about, and two extra
/// hidden webviews resident for the app's lifetime to keep those searches from
/// queueing behind each other. This is one page load, and it can show something
/// nobody thought to search for.
///
/// The one thing the session still decides is **whether the feed scrolls**.
/// Signed in it pages indefinitely and a fill keeps going until it has
/// `browseTarget` cards worth showing; anonymous it is a single page, because
/// Facebook serves ~20 cards to a session it doesn't recognise and then simply
/// never loads more (`docs/feasibility-2026-07-31.md` §9.1, measured again
/// here). That is one branch rather than two feeds, and it is the difference
/// between publishing in ~3s and spending another six on scrolls that return
/// the same twenty cards.
///
/// **What it gives up** is the case recorded in `docs/discover.md` §3, which
/// was measured and still stands: logged out, this feed is a rotating
/// popularity pool rather than a recommendation. Three loads of the identical
/// URL in one session gave 0 of 5 top cards in common between the first and
/// second, 17 of 20 between the second and third, and a fourth that reverted to
/// the first's contents; the geography swung with it, from 9-of-20 in San
/// Francisco to an East Bay spread reaching Napa and Antioch, 50 mi out. An
/// anonymous session gives Facebook an IP and a cookie to rank with, and that
/// is what ranking on an IP and a cookie looks like. Signed in it ranks against
/// a real history, which is the difference the offer at the bottom of the
/// screen describes.
///
/// So the honest summary of the signed-out feed is "what Facebook is showing
/// near you", which is what the caption says, and not a claim about the user.
///
/// **Its own engine**, for the reason `ComparableSearch` has one: sharing the
/// browse tab's would mean the home feed and the user's first search taking
/// turns navigating one webview. No extra request budget — `RequestPacer` is a
/// shared actor and still spaces the starts.
///
/// **A fill publishes once, when all of it is in.** Cards moving out from under
/// a thumb is the one thing a feed must not do. Pagination is exempt — it
/// appends below what is already on screen, which moves nothing.
///
/// **Session-scoped, and nothing is written to disk.** The feed survives moving
/// between tabs and opening listings, and is rebuilt when the app is launched
/// again, when the user pulls to refresh, when the city changes, or when the
/// session changes — that last one because an account changes what this page
/// serves, not just who is looking at it.
@MainActor
final class DiscoverFeed: ObservableObject {
    @Published private(set) var listings: [Listing] = []
    @Published private(set) var isLoading = false
    /// Scrolling for more, with cards already on screen.
    @Published private(set) var isLoadingMore = false
    /// Whether there is any point scrolling further.
    @Published private(set) var reachedEnd = false
    /// Whether the cards on screen were fetched without a working account.
    ///
    /// Published because the footer differs, and the difference is real rather
    /// than a nudge: the logged-out browse surface stops at ~24 cards (README's
    /// surface table) where a signed-in one has never been observed to stop, so
    /// "log in to keep scrolling" at the end of this feed is a description of
    /// what happens next. Not the same question as "is the user signed in" — a
    /// session whose cookies have stopped working walls this page, and the
    /// accurate next step there is also a login.
    @Published private(set) var isAnonymous = true

    /// How many in-radius cards a signed-in fill tries to have in hand before
    /// it publishes, and how many each top-up aims to add. An anonymous fill
    /// publishes whatever its one page carried.
    ///
    /// It has to be a target rather than a page count because the two numbers
    /// are not related: Facebook's feed reaches wherever it feels like reaching,
    /// and one measured load returned 20 cards across 11 cities, of which a
    /// 6 mi radius kept 9. Paging once and showing what survived would make a
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

    private let engine: DesktopFeedEngine
    private let prefs: Preferences
    private let distances: DistanceResolver
    private var hasLoaded = false
    /// Which session the current cards were fetched under, so a sign-in or a
    /// sign-out rebuilds the feed rather than leaving the wrong one up.
    ///
    /// Distinct from `isAnonymous`, which is what the footer reads: this one
    /// records the session we *asked* under, and a walled signed-in load sets
    /// only the other. Sharing one value would make every subsequent
    /// `loadIfNeeded` see a mismatch and refetch the wall.
    private var filledUnder: BrowserSession?
    /// Listing ids already taken this fill.
    ///
    /// Held across scrolls rather than recomputed, because the desktop feed
    /// virtualises: every harvest returns the cards currently in the DOM, which
    /// overlaps heavily with the last one.
    private var browseSeen = Set<String>()

    /// It has to be in the view hierarchy for WebKit to render it — see
    /// `RootView`. Same constraint as every other engine.
    var webViews: [WKWebView] { [engine.webView] }

    init(engine: DesktopFeedEngine? = nil,
         prefs: Preferences = .shared,
         distances: DistanceResolver = .shared) {
        self.engine = engine ?? DesktopFeedEngine()
        self.prefs = prefs
        self.distances = distances
    }

    /// Fills once per launch. `force` is the pull-to-refresh path.
    ///
    /// It also refills when the session has changed since the last fill, which
    /// is not the same kind of trigger as the others: signing in doesn't make
    /// the feed stale, it makes Facebook serve a different page.
    ///
    /// Note what is *not* a trigger: running a search. Nothing on this screen is
    /// built from search history any more, so a search has no bearing on it at
    /// all.
    func loadIfNeeded(citySlug: String, force: Bool = false) async {
        guard !isLoading else { return }
        // Read from the cookie store rather than taken from the caller.
        // `ListingStore.session` is set by an async check that may not have
        // landed yet on the launch this screen fills on, and this decides
        // whether the feed can paginate past ~24 cards and what its footer
        // says.
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
        await fill(citySlug: citySlug, session: session)
    }

    /// Facebook's Marketplace feed for this place, cut to the user's radius.
    private func fill(citySlug: String, session: BrowserSession) async {
        browseSeen = []

        let query = SearchQuery(kind: .browse, radiusKM: prefs.radiusKM,
                                citySlug: citySlug, coordinate: nil)
        let cards = await engine.loadCards(query.url)

        // A wall is the one explanation for an empty feed that isn't "nothing
        // nearby", and it means the same thing whichever session we asked
        // under: signed out it is Facebook declining to serve the page at all,
        // and signed in it is cookies that have outlived whatever Facebook does
        // with them. Either way there is nothing more to scroll for and a login
        // is the accurate next step, so the footer gets told.
        let walled = engine.state == .loginWall
        if walled { Logger.discover.info("login wall on the browse feed") }
        isAnonymous = walled || session == .unauthed

        var collected = await nearby(cards).kept
        // **Anonymous is one page, and that is the whole feed.** Facebook hands
        // a signed-out session about twenty cards and then stops — measured
        // here as five screens that advanced 0→2410px of a 3188px container
        // with the card count sitting at 20 the entire way, six seconds spent
        // on nothing. `docs/feasibility-2026-07-31.md` §9.1 says the same:
        // the page simply never loads more.
        //
        // So the scroll is what an account buys, and skipping it is most of
        // the reason this screen is quicker than the three searches it
        // replaced. The footer says so in as many words.
        if isAnonymous {
            reachedEnd = true
        } else if collected.count < Self.browseTarget {
            // Only if the first screen didn't already carry enough. A fill that
            // can publish immediately should, since this is the screen the app
            // opens on.
            let harvest = await scrollForMore(wanted: Self.browseTarget - collected.count)
            collected += harvest.cards
            reachedEnd = harvest.exhausted
        }
        // One assignment: a pull-to-refresh keeps the old cards exactly where
        // they are until the new feed is ready.
        listings = collected
        Logger.discover.info("\(self.listings.count, privacy: .public) cards from Marketplace, anon=\(self.isAnonymous, privacy: .public), end=\(self.reachedEnd, privacy: .public)")
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
    /// Never runs for an anonymous session: `fill` ends that feed where it
    /// lands, because there is nothing behind it to scroll to.
    private func topUpIfAtMargin() async {
        guard !reachedEnd, !isLoading, !isLoadingMore,
              scrolledSinceLastTopUp,
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

        let harvest = await scrollForMore(wanted: Self.browseTarget)
        // Appended, never reassigned. New cards land below everything already
        // on screen, so nothing moves under whoever is reading.
        listings.append(contentsOf: harvest.cards)
        reachedEnd = harvest.exhausted
    }

    /// Scrolls the feed a screen at a time, keeping what is inside the radius,
    /// until it has `wanted` of them or there is no point continuing.
    ///
    /// Harvesting *between* scrolls rather than once at the end is not
    /// defensive: the desktop feed virtualises, recycling cards out of the DOM
    /// as they leave the viewport, so a single read at the bottom returns the
    /// last window rather than the feed (`docs/logged-in-findings.md` §3).
    ///
    /// `exhausted` means "stop asking", and it has two causes worth telling
    /// apart in the log but not in the UI: the document stopped growing, which
    /// is the literal end of the feed — logged out, that is the ~24-card cap —
    /// or several screens in a row carried nothing within the radius, which is
    /// the end of the part of it that this app is for. Running out of scroll
    /// budget is neither — it is just this call's turn ending, and the next one
    /// picks up where it left off.
    private func scrollForMore(wanted: Int) async -> (cards: [Listing], exhausted: Bool) {
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
    /// For a change that makes the current feed answer the wrong question — a
    /// change of city, and nothing else. The cards stay up until the next fill
    /// replaces them, because blanking a screen the moment a preference changes
    /// is a worse answer than a stale one.
    func markStale() { hasLoaded = false }

    /// What the section header says the feed is.
    ///
    /// The basis is "Facebook's feed" and the radius is the one thing this app
    /// did to it, so the radius is what gets stated. It also carries the only
    /// remaining disclosure of the distance filter, now that the footer counting
    /// what it removed is gone — a caption beside the heading is where someone
    /// who scrolls until something catches their eye will actually read it,
    /// which the footer never was.
    var caption: String {
        let place = prefs.locationName ?? "you"
        guard prefs.radiusKM > 0 else { return "Facebook Marketplace, near \(place)" }
        return "Facebook Marketplace, within \(SearchQuery.kilometresToMiles(prefs.radiusKM)) mi of \(place)"
    }
}

extension Logger {
    static let discover = Logger(subsystem: "lol.frens.openmarket", category: "discover")
}
