import Foundation
import WebKit
import os

extension Logger {
    static let desktop = Logger(subsystem: "lol.frens.openmarket", category: "desktop")
}

/// Search on the desktop surface, reading the GraphQL payload Facebook embeds
/// in the page it already serves.
///
/// This is the primary search path (`docs/decision-desktop-primary.md`). It
/// exists rather than extending `FeedEngine` because almost nothing is shared:
/// desktop has real listing anchors, an embedded payload, working filters and a
/// hard result cap, where WebLite has none of those and paginates forever. One
/// engine pretending to be both would be a pile of branches.
///
/// Three properties of this surface shape the design:
///
/// * **The payload covers only the first ~15 cards.** Everything past the first
///   server-rendered page is markup, signed in or out. Cards therefore come back
///   in two grades and callers must handle both — see `PayloadCoverage`.
/// * **Results are capped without a session** at 15, behind a login overlay that
///   allows exactly one dismissal. Signed in, the feed scrolls indefinitely.
/// * **The feed virtualises.** Cards are recycled out of the DOM as they leave
///   the viewport, so pagination has to harvest as it goes rather than scroll to
///   the end and read once.
@MainActor
final class DesktopFeedEngine: NSObject, ObservableObject, WKNavigationDelegate {
    enum LoadState: Equatable {
        case idle, loading, ready, loginWall, failed(String)
    }

    /// How much of the result set arrived with structured data behind it.
    ///
    /// Reported rather than inferred because "this card has no payload" and
    /// "extraction failed" look identical downstream and are not the same
    /// problem — the first is expected past card 15, the second is a bug.
    struct PayloadCoverage: Equatable {
        var rendered: Int
        var withPayload: Int
        var isSuspicious: Bool { rendered > 0 && withPayload == 0 }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var coverage = PayloadCoverage(rendered: 0, withPayload: 0)

    let webView: WKWebView

    /// Which session this engine is running under.
    ///
    /// **A `var`, and it must be kept current** — `ListingStore.setSession`
    /// owns that. It used to be a `let` fixed at init, which quietly disabled
    /// the only thing it is read for: the engine is constructed with the
    /// `.authed` default before anyone has asked whether there is a session, so
    /// `canLoadMore` below was permanently true and a signed-out grid
    /// paginated into the login overlay on every scroll.
    ///
    /// It selects nothing — `BrowserSession.dataStore` is one process-wide
    /// store either way — so this is a label describing the world, and a label
    /// that never updates is just a wrong one.
    var session: BrowserSession
    private let pacer: RequestPacer
    /// Resumed when WebKit commits the new document, not when every image and
    /// third-party resource has finished. The data we need is in the document
    /// well before `didFinish` on both browse and search pages.
    private var commitContinuation: CheckedContinuation<Void, Never>?

    /// Defaults to `.unauthed`, deliberately.
    ///
    /// This is the value in force between construction and the first
    /// `setSession`, i.e. before anything has read the cookie jar, and the two
    /// wrong guesses are not equally wrong. Guessing signed-in paginates
    /// against a wall; guessing signed-out declines to paginate for a few
    /// hundred milliseconds and then corrects itself. Only one of those is
    /// visible to the user.
    init(session: BrowserSession = .unauthed, pacer: RequestPacer = .shared) {
        self.session = session
        self.pacer = pacer
        let config = WKWebViewConfiguration.make()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                            configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Surface.desktop.userAgent
        webView.scrollView.showsVerticalScrollIndicator = false
    }

    // MARK: - Loading

    func load(_ query: SearchQuery) async -> [PayloadListing] {
        guard await pacer.waitForSlot() else {
            state = .failed("Paused — too many requests. Try again shortly.")
            return []
        }
        state = .loading
        Logger.desktop.info("loading \(query.url.absoluteString, privacy: .public)")
        await navigate(to: query.url)
        // Both values hydrate independently after the document commits. Reading
        // them together avoids adding the location pill's wait to the payload's
        // wait on every search.
        async let payloadRead = harvest()
        async let locationRead = readLocation()
        let (payload, located) = await (payloadRead, locationRead)
        // Logged on every search, because a refused place is otherwise
        // invisible: the grid fills with a healthy-looking set of listings for
        // a city nobody asked for.
        Logger.desktop.info("location: \(located.summary, privacy: .public)")
        return payload
    }

    /// Loads a page whose cards are markup only, returning the moment any of
    /// them render.
    ///
    /// The browse feed is that page: `/marketplace/<place>/` embeds no usable
    /// listing payload — 6 `"listing"` blocks against 20 rendered cards, none
    /// of them carrying a title, price or photo (`docs/embedded-payload.md`
    /// §8). Putting it through `load` would spend the full 20-second harvest
    /// timeout waiting for something that is never coming, on the screen the
    /// app opens with.
    ///
    /// So this polls the DOM instead of the payload, and everything it returns
    /// is markup-grade by construction — no exact timestamps, no delivery
    /// types, no sold state. Cards are enriched when one is opened.
    func loadCards(_ url: URL, timeout: Duration = .seconds(20)) async -> [DesktopRawCard] {
        guard await pacer.waitForSlot() else {
            state = .failed("Paused — too many requests. Try again shortly.")
            return []
        }
        state = .loading
        Logger.desktop.info("loading cards from \(url.absoluteString, privacy: .public)")
        await navigate(to: url)

        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let cards = await renderedCards()
            if !cards.isEmpty {
                state = .ready
                coverage = PayloadCoverage(rendered: cards.count, withPayload: 0)
                await pacer.recordSuccess()
                Logger.desktop.info("\(cards.count, privacy: .public) markup cards")
                return cards
            }
            // Only once nothing has rendered — a wall is the one explanation
            // for an empty feed that isn't "still loading", and it needs a
            // different answer from the caller.
            if await evaluate(DesktopScripts.detectLoginWall) == "wall" {
                state = .loginWall
                Logger.desktop.info("login wall on browse")
                return []
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Empty is not a failure here. A browse feed with nothing in it is a
        // real answer — see `DiscoverFeed`, which says so rather than drawing
        // an error over a screen that simply has nothing nearby.
        state = .ready
        Logger.desktop.info("no markup cards before timeout")
        return []
    }

    /// Polls for the payload as soon as the new document commits rather than
    /// waiting on `didFinish`.
    ///
    /// On item pages the payload is readable ~0.9s into a ~1.85s load, so
    /// waiting for the document to finish spends roughly half the time on
    /// images and third-party chrome nobody is going to look at. Search pages
    /// behave the same way.
    private func harvest(timeout: Duration = .seconds(20)) async -> [PayloadListing] {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var last: [PayloadListing] = []

        while ContinuousClock.now < deadline {
            guard let json = await evaluate(DesktopScripts.extractSearchPayload),
                  let result = decode(json) else {
                try? await Task.sleep(for: .milliseconds(120))
                continue
            }

            if result.loginWall {
                state = .loginWall
                Logger.desktop.info("login wall on search")
                return []
            }

            coverage = PayloadCoverage(rendered: result.renderedCount,
                                       withPayload: result.payloadCount)
            last = result.listings

            // Done as soon as the payload matches what's on screen, or as soon
            // as there is a payload at all and the page has stopped growing.
            if !result.listings.isEmpty {
                state = .ready
                await pacer.recordSuccess()
                Logger.desktop.info("payload \(result.payloadCount)/\(result.renderedCount) cards")
                return result.listings
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        // Cards on screen but no payload parsed used to be reported to the user
        // as "Couldn't read these results." That was wrong twice over.
        //
        // It isn't a failure: the caller reads the rendered cards from the DOM
        // straight afterwards (`ListingStore.search` → `renderedCards()`), and
        // those parse fine from their aria-labels. The listings arrive; only
        // the richer fields — timestamps, delivery types, price drops — don't.
        // Declaring `.failed` meant `ResultsView` drew an error over a result
        // set the app had successfully collected.
        //
        // And it isn't necessarily *suspicious*. Facebook does not always embed
        // the payload; a page served entirely client-side renders cards with no
        // `"listing":{` block anywhere in the document. Same signature as a
        // broken extractor, different cause, and only one of them is a bug.
        //
        // So it degrades rather than fails, and says so in the log where the
        // coverage numbers are — a real extractor break shows up there as this
        // line on *every* search rather than an occasional one.
        if coverage.isSuspicious {
            Logger.desktop.error("degraded: \(self.coverage.rendered) cards rendered, no payload — falling back to markup")
        }
        state = .ready
        return last
    }

    private struct PayloadResult: Decodable {
        let listings: [PayloadListing]
        let renderedIDs: [String]
        let renderedCount: Int
        let payloadCount: Int
        let loginWall: Bool
    }

    private func decode(_ json: String) -> PayloadResult? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PayloadResult.self, from: data)
    }

    // MARK: - Pagination

    /// Whether scrolling can produce more results.
    ///
    /// Signed out this is false after the first page: the login overlay is up
    /// from load, pins the document at ~600px, and allows exactly one dismissal
    /// — after which it returns as a modal with no close control at all. The 24
    /// extra cards that one dismissal buys carry no payload, so they are no
    /// better than the mobile feed's and not worth the traffic.
    var canLoadMore: Bool { session == .authed }

    /// Every card currently rendered, payload or not.
    ///
    /// Called repeatedly *during* a scroll rather than once at the end, because
    /// the desktop feed virtualises: cards are recycled out of the DOM as they
    /// leave the viewport, so a single read at the bottom returns the last
    /// window rather than the feed.
    func renderedCards() async -> [DesktopRawCard] {
        guard let json = await evaluate(DesktopScripts.extractRenderedCards),
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(RenderedResult.self, from: data)
        else { return [] }
        return result.cards
    }

    private struct RenderedResult: Decodable {
        let cards: [DesktopRawCard]
        let count: Int
    }

    /// Where this page actually is, from both instruments: the place segment in
    /// the URL and the pill the page rendered.
    ///
    /// Cheap enough to call after every load, and worth it — an unrecognised
    /// place is not an error, it is a full page of the wrong city's listings
    /// (`docs/location-targeting.md` §2), and this is the only thing that
    /// distinguishes it.
    /// - Parameter pillTimeout: how long to wait for the pill to appear. The
    ///   URL half is available immediately; the pill is rendered by the page's
    ///   own scripts and lands *after* the payload this engine harvests, so a
    ///   single read taken the moment listings are extractable finds nothing.
    ///   Zero makes this a one-shot read of whatever is on screen now.
    func readLocation(pillTimeout: Duration = .milliseconds(2500)) async -> DesktopPageLocation {
        let deadline = ContinuousClock.now.advanced(by: pillTimeout)
        var latest = DesktopPageLocation(urlPlace: MarketplaceURLPlace.parse(webView.url), pill: nil)

        repeat {
            guard let json = await evaluate(DesktopScripts.extractLocationPill),
                  let data = json.data(using: .utf8),
                  let result = try? JSONDecoder().decode(PillResult.self, from: data)
            else { break }

            // Prefer the URL the page ended on over the one we asked for:
            // Facebook rewrites the path *during* the load, and the webview's
            // own property can still hold the pre-redirect value.
            let settled = result.href.flatMap(URL.init(string:))
                .map(MarketplaceURLPlace.parse) ?? latest.urlPlace
            latest = DesktopPageLocation(
                urlPlace: settled,
                pill: result.pill.map(DesktopLocationPill.init(rawPillText:))
            )
            if latest.pill != nil { return latest }

            // Nothing yet. Say what the page did offer, so an empty result is
            // traceable to a selector rather than assumed to be a missing pill.
            Logger.desktop.debug("pill: none yet, \(result.candidates.count) candidates")
            try? await Task.sleep(for: .milliseconds(250))
        } while ContinuousClock.now < deadline

        return latest
    }

    private struct PillResult: Decodable {
        let pill: String?
        let source: String?
        let candidates: [String]
        let href: String?
    }

    /// Scrolls one screen and reports whether there is any point scrolling
    /// again.
    ///
    /// Deliberately one screen at a time with a harvest between: the caller has
    /// to read the DOM before the cards it just loaded are recycled back out.
    ///
    /// **This drives an element, not the webview.** It used to move
    /// `webView.scrollView.contentOffset`, which on this surface does nothing at
    /// all: desktop Marketplace lays its feed out inside an `overflow-y: auto`
    /// div and leaves the document exactly one viewport tall, so
    /// `contentSize.height - bounds.height` is zero and the old implementation
    /// returned `false` on its very first call — every time, on both the browse
    /// feed and search results.
    ///
    /// That made pagination a no-op wherever it ran. It went unnoticed for a
    /// long time because `canLoadMore` is false without a session, so the only
    /// code paths that ever called this were signed-in ones, and the app has
    /// been developed signed out. Measured logged out at 1280x900:
    /// `document.documentElement.scrollHeight` 900, `window.innerHeight` 900,
    /// feed container 900 over 3102.
    /// **The test is whether we advanced, not whether the document grew.**
    ///
    /// Document height is not a usable signal on this feed. The recycler
    /// collapses content above the viewport as well as below it, so
    /// `scrollHeight` oscillates while paging *forward* — measured signed in:
    /// 8515, 4711, 5043, 6330, 6854, 7954, 6748, 4247, all while scrolling down
    /// through cards that kept arriving. Worse, a shrink can clamp the scroll
    /// position *backwards* (3800 → 3469), which an earlier version of this read
    /// as the end of the feed and reported to the user as an exhausted
    /// neighbourhood.
    ///
    /// Advancing is unambiguous: either the scroll position ended higher than it
    /// started, or new cards appeared. A clamp gets one retry, because the
    /// recycler re-expands a moment later and the second attempt goes through.
    ///
    /// Settling is adaptive. The old implementation slept 900 ms after every
    /// screen whether React had recycled the card window in 150 ms or 850 ms.
    /// Two unchanged readings are enough once the rendered listing ids change,
    /// or while the new viewport is still inside content already rendered by
    /// the page. 900 ms remains the ceiling at the end of that runway, where a
    /// network-backed scroll really can take that long.
    @discardableResult
    func scrollOnce() async -> Bool {
        for attempt in 0..<2 {
            guard let step = await feedScroll(DesktopScripts.scrollFeedStep) else { return false }
            let settleStarted = ContinuousClock.now
            guard let after = await waitForScrollToSettle(after: step) else { return false }
            let settleMS = Int(settleStarted.duration(to: .now) / .milliseconds(1))

            let reached = max(step.top, after.top)
            let advanced = reached > step.from
            let gainedCards = after.cards > step.fromCards
            if advanced || gainedCards {
                Logger.desktop.info("scroll: \(step.from, privacy: .public)->\(reached, privacy: .public) of \(after.scrollHeight, privacy: .public), cards \(step.fromCards, privacy: .public)->\(after.cards, privacy: .public), settled \(settleMS, privacy: .public)ms, isDocument \(after.isDocument, privacy: .public)")
                return true
            }
            if attempt == 0 {
                Logger.desktop.debug("scroll: clamped at \(step.from, privacy: .public), retrying")
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        Logger.desktop.info("scroll: no further movement")
        return false
    }

    private static let scrollSettlePoll = Duration.milliseconds(50)
    private static let scrollSettleCeiling = Duration.milliseconds(900)
    private static let stableScrollReads = 2

    /// Waits for the virtualised card window, not an arbitrary timer.
    ///
    /// A changed signature says React has mounted a different window. While the
    /// viewport is still within the document's rendered runway, stable geometry
    /// is also enough: waiting for ids to change there made every ordinary
    /// Search scroll pay the full network ceiling. At the end of that runway
    /// there may be no signature change until Facebook answers, so 900 ms stays
    /// the hard fallback.
    private func waitForScrollToSettle(after step: FeedScroll) async -> FeedScroll? {
        let deadline = ContinuousClock.now.advanced(by: Self.scrollSettleCeiling)
        var previous = step
        var stableReads = 0

        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.scrollSettlePoll)
            guard let current = await feedScroll(DesktopScripts.readFeedScroll) else { return nil }

            let windowChanged = current.signature != step.fromSignature
                || current.cards != step.fromCards
            let hasRenderedRunway = current.top + current.clientHeight
                < current.scrollHeight - 1
            let unchanged = current.top == previous.top
                && current.cards == previous.cards
                && current.signature == previous.signature
            stableReads = (windowChanged || hasRenderedRunway) && unchanged
                ? stableReads + 1
                : 0
            previous = current

            if stableReads >= Self.stableScrollReads { return current }
        }
        return previous
    }

    /// One reading of whatever is scrolling the feed.
    private struct FeedScroll: Decodable {
        var top = 0
        var scrollHeight = 0
        var clientHeight = 0
        var cards = 0
        var signature = ""
        var isDocument = false
        var moved = 0
        /// Where the scroll started, for the step script. Zero on a plain read.
        var from = 0
        /// The rendered window before the step, for adaptive settling.
        var fromCards = 0
        var fromSignature = ""
    }

    /// One reading, or nil with a reason in the log.
    ///
    /// The reason is the point. This returned a bare `nil` on any failure, and
    /// `scrollOnce` reads nil as "can't scroll" — which is indistinguishable
    /// from the end of the feed and produced exactly that message to the user.
    /// A fractional `moved` value failing to decode into an `Int` cost an
    /// afternoon precisely because it looked like a feed that had run out.
    private func feedScroll(_ script: String) async -> FeedScroll? {
        guard let json = await evaluate(script), let data = json.data(using: .utf8) else {
            Logger.desktop.error("scroll: script returned nothing")
            return nil
        }
        do {
            return try JSONDecoder().decode(FeedScroll.self, from: data)
        } catch {
            Logger.desktop.error("scroll: undecodable — \(json.prefix(160), privacy: .public)")
            return nil
        }
    }

    // MARK: - The login overlay

    /// Dismisses the "See more on Facebook" overlay if it offers a way out.
    ///
    /// Logged out there is exactly **one** free dismissal per page load: it
    /// unlocks the document (600px → 2340px) and scrolling then paginates
    /// 15 → 39, after which the overlay returns as a different modal with no
    /// close control at all — Escape and backdrop clicks are both no-ops.
    ///
    /// Not worth using for depth, because cards 16–39 carry no payload and are
    /// therefore no better than mobile's. Kept for the case where the overlay
    /// is merely covering the first 15.
    @discardableResult
    func dismissOverlayIfPresent() async -> Bool {
        let result = await evaluate(Self.dismissOverlayJS)
        return result?.contains("dismissed") ?? false
    }

    private static let dismissOverlayJS = """
    (function(){
      var dialogs = document.querySelectorAll('[role="dialog"]');
      for (var i = 0; i < dialogs.length; i++) {
        var buttons = dialogs[i].querySelectorAll('[aria-label], [role="button"]');
        for (var j = 0; j < buttons.length; j++) {
          var label = (buttons[j].getAttribute('aria-label') || buttons[j].innerText || '').trim();
          if (label === 'Close' || label === 'Not now') {
            buttons[j].click();
            return 'dismissed';
          }
        }
      }
      return 'none';
    })()
    """

    // MARK: - Plumbing

    private func navigate(to url: URL) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            commitContinuation = cont
            webView.load(URLRequest(url: url))
        }
    }

    private func resumeCommittedNavigation() {
        commitContinuation?.resume()
        commitContinuation = nil
    }

    func evaluate(_ script: String) async -> String? {
        do {
            let result = try await webView.evaluateJavaScript(script)
            return result as? String
        } catch {
            return nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        Task { @MainActor in
            self.resumeCommittedNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Fallback for unusual navigation paths where WebKit does not send
            // the expected commit callback.
            self.resumeCommittedNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.resumeCommittedNavigation()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.state = .failed(error.localizedDescription)
            self.resumeCommittedNavigation()
        }
    }
}
