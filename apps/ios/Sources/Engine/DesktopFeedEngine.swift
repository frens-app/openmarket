import Foundation
import WebKit
import os

extension Logger {
    static let desktop = Logger(subsystem: "lol.frens.openmarket", category: "desktop")
}

/// Search on the desktop surface, reading the GraphQL payload Facebook embeds
/// in the page it already serves.
///
/// The primary search path (`docs/decision-desktop-primary.md`). Separate from
/// `FeedEngine` because almost nothing is shared: desktop has real listing
/// anchors, an embedded payload, working filters and a hard result cap, where
/// WebLite has none of those and paginates forever.
///
/// Three properties of this surface shape the design:
///
/// * **The payload covers only the first ~15 cards.** Everything past the first
///   server-rendered page is markup, signed in or out — see `PayloadCoverage`.
/// * **Results are capped without a session** at 15, behind a login overlay that
///   allows exactly one dismissal. Signed in, the feed scrolls indefinitely.
/// * **The feed virtualises.** Cards are recycled out of the DOM as they leave
///   the viewport, so pagination has to harvest as it goes.
@MainActor
final class DesktopFeedEngine: NSObject, ObservableObject, WKNavigationDelegate {
    enum LoadState: Equatable {
        case idle, loading, ready, loginWall, failed(String)
    }

    /// What one pagination step proved. `exhausted` is kept apart from
    /// `indeterminate` so a script failure or a recycler clamp can't put a
    /// confident end message under a feed that has more to give.
    enum ScrollOutcome: Equatable {
        case advanced
        case exhausted
        case indeterminate
    }

    /// How much of the result set arrived with structured data behind it.
    /// Reported rather than inferred: "no payload on this card" is expected past
    /// card 15, "extraction failed" is a bug, and they look identical downstream.
    struct PayloadCoverage: Equatable {
        var rendered: Int
        var withPayload: Int
        var isSuspicious: Bool { rendered > 0 && withPayload == 0 }
    }

    @Published private(set) var state: LoadState = .idle
    @Published private(set) var coverage = PayloadCoverage(rendered: 0, withPayload: 0)

    let webView: WKWebView

    /// Which session this engine is running under. Must be kept current by
    /// `ListingStore.setSession` — `canLoadMore` is the only reader, and a stale
    /// value has a signed-out grid paginating into the login overlay. It selects
    /// nothing: `BrowserSession.dataStore` is one process-wide store either way.
    var session: BrowserSession
    private let pacer: RequestPacer
    /// Resumed when WebKit commits the new document, not when every image and
    /// third-party resource has finished. The data we need is in the document
    /// well before `didFinish` on both browse and search pages.
    private var commitContinuation: CheckedContinuation<Void, Never>?
    /// The load `commitContinuation` belongs to, so that a callback for a
    /// superseded navigation can be told apart from the one we are waiting on.
    /// See `resumeCommittedNavigation(for:)`.
    private var pendingNavigation: WKNavigation?

    /// Defaults to `.unauthed`: this holds between construction and the first
    /// `setSession`, and the two wrong guesses are not equally wrong. Guessing
    /// signed-in paginates against a wall; guessing signed-out declines to
    /// paginate for a few hundred milliseconds and then corrects itself.
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
        // Logged every search: a refused place is otherwise invisible, since the
        // grid fills with healthy-looking listings for a city nobody asked for.
        Logger.desktop.info("location: \(located.summary, privacy: .public)")
        return payload
    }

    /// Loads a page whose cards are markup only, returning the moment any of
    /// them render.
    ///
    /// The browse feed is that page: `/marketplace/<place>/` embeds no usable
    /// listing payload — 6 `"listing"` blocks against 20 rendered cards, none
    /// carrying a title, price or photo (`docs/embedded-payload.md` §8). Through
    /// `load` it would spend the full 20-second harvest timeout on the screen
    /// the app opens with.
    ///
    /// So this polls the DOM, and everything it returns is markup-grade: no
    /// exact timestamps, delivery types or sold state. Cards are enriched when
    /// one is opened.
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
            // Only once nothing has rendered: a wall is the one explanation for
            // an empty feed that isn't "still loading".
            if await evaluate(DesktopScripts.detectLoginWall) == "wall" {
                state = .loginWall
                Logger.desktop.info("login wall on browse")
                return []
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        // Empty is not a failure: a browse feed with nothing in it is a real
        // answer, and `DiscoverFeed` says so rather than drawing an error.
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

        // Cards on screen but no payload degrades rather than fails: the caller
        // reads the rendered cards from the DOM straight afterwards and those
        // parse fine from their aria-labels — only the richer fields are
        // missing. Facebook also doesn't always embed the payload, so this has
        // the same signature as a broken extractor with a different cause. The
        // log is what tells them apart: a real break appears on *every* search.
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

    /// Every card currently rendered, payload or not. Call it repeatedly
    /// *during* a scroll: the feed virtualises, so a single read at the bottom
    /// returns the last window rather than the feed.
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
    /// the URL and the pill the page rendered. Worth calling after every load —
    /// an unrecognised place is not an error but a full page of the wrong city's
    /// listings (`docs/location-targeting.md` §2), and this is the only signal.
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
    /// again. One screen at a time with a harvest between: the caller has to
    /// read the DOM before the cards it just loaded are recycled back out.
    ///
    /// **This drives an element, not the webview.** Desktop Marketplace lays the
    /// feed out inside an `overflow-y: auto` div and leaves the document exactly
    /// one viewport tall, so `webView.scrollView` has nothing to scroll — at
    /// 1280x900, `documentElement.scrollHeight` 900 over a feed container of
    /// 3102.
    ///
    /// **The test is whether we advanced, not whether the document grew.** The
    /// recycler collapses content above the viewport as well as below, so
    /// `scrollHeight` oscillates while paging forward — 8515, 4711, 5043, 6330,
    /// 6854, 7954, 6748, 4247 measured signed in, all while cards kept arriving.
    /// A shrink can also clamp the scroll position backwards (3800 → 3469),
    /// which reads as the end of a feed that has plenty left. So a clamp gets
    /// one retry: the recycler re-expands and the second attempt goes through.
    ///
    /// Settling is adaptive — see `waitForScrollToSettle`.
    @discardableResult
    func scrollOnce() async -> ScrollOutcome {
        var stalledReading: FeedScroll?
        for attempt in 0..<2 {
            guard let step = await feedScroll(DesktopScripts.scrollFeedStep) else {
                return .indeterminate
            }
            let settleStarted = ContinuousClock.now
            guard let after = await waitForScrollToSettle(after: step) else {
                return .indeterminate
            }
            let settleMS = Int(settleStarted.duration(to: .now) / .milliseconds(1))

            let reached = max(step.top, after.top)
            let advanced = reached > step.from
            let gainedCards = after.cards > step.fromCards
            // A virtualised window commonly replaces N cards with N different
            // cards. Count that as progress even though the cardinality did not
            // change and a recycler clamp may have left `scrollTop` stationary.
            let changedWindow = !after.signature.isEmpty
                && after.signature != step.fromSignature
            if advanced || gainedCards || changedWindow {
                Logger.desktop.info("scroll: \(step.from, privacy: .public)->\(reached, privacy: .public) of \(after.scrollHeight, privacy: .public), cards \(step.fromCards, privacy: .public)->\(after.cards, privacy: .public), settled \(settleMS, privacy: .public)ms, isDocument \(after.isDocument, privacy: .public)")
                return .advanced
            }
            stalledReading = after
            if attempt == 0 {
                Logger.desktop.debug("scroll: clamped at \(step.from, privacy: .public), retrying")
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        guard let stalledReading else { return .indeterminate }
        return await confirmEndOfFeed(from: stalledReading)
    }

    private static let scrollSettlePoll = Duration.milliseconds(50)
    private static let scrollSettleCeiling = Duration.milliseconds(900)
    private static let stableScrollReads = 2
    private static let endConfirmationPoll = Duration.milliseconds(200)
    private static let endConfirmationWindow = Duration.seconds(2)

    /// Turns a stalled scroll into an end state only when the feed remains at a
    /// valid bottom with unchanged geometry and cards for an additional window.
    ///
    /// The extra wait is paid only once, at the apparent end. If React mounts a
    /// new card window during it, that is progress and the caller harvests it.
    /// If the recycler changes geometry or the script stops decoding, the answer
    /// remains unknown and a later user drag is free to retry.
    private func confirmEndOfFeed(from candidate: FeedScroll) async -> ScrollOutcome {
        guard candidate.isAtBottom else {
            Logger.desktop.info("scroll: stalled away from bottom, retryable")
            return .indeterminate
        }

        let deadline = ContinuousClock.now.advanced(by: Self.endConfirmationWindow)
        var previous = candidate
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: Self.endConfirmationPoll)
            guard let current = await feedScroll(DesktopScripts.readFeedScroll) else {
                return .indeterminate
            }

            let gainedCards = current.cards > candidate.cards
            let changedWindow = !current.signature.isEmpty
                && current.signature != candidate.signature
            if gainedCards || changedWindow {
                Logger.desktop.info("scroll: feed advanced during end confirmation")
                return .advanced
            }

            let geometryChanged = current.top != previous.top
                || current.scrollHeight != previous.scrollHeight
                || current.clientHeight != previous.clientHeight
                || current.cards != previous.cards
            guard !geometryChanged, current.isAtBottom else {
                Logger.desktop.info("scroll: end geometry changed, retryable")
                return .indeterminate
            }
            previous = current
        }

        Logger.desktop.info("scroll: confirmed end at \(previous.top, privacy: .public) of \(previous.scrollHeight, privacy: .public), \(previous.cards, privacy: .public) cards")
        return .exhausted
    }

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

        var isAtBottom: Bool {
            top + clientHeight >= scrollHeight - 1
        }
    }

    /// One reading, or nil with a reason in the log. The reason matters:
    /// `scrollOnce` reads nil as "can't scroll", which is indistinguishable from
    /// the end of the feed, so a decode failure otherwise reaches the user as an
    /// exhausted neighbourhood.
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
    /// Logged out there is exactly one free dismissal per page load: it unlocks
    /// the document (600px → 2340px) and scrolling paginates 15 → 39, after
    /// which the overlay returns with no close control at all. Not worth using
    /// for depth — cards 16–39 carry no payload — but kept for the case where
    /// the overlay is merely covering the first 15.
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
            pendingNavigation = webView.load(URLRequest(url: url))
        }
    }

    /// Resumes `navigate`, but only for the load it is actually waiting on.
    ///
    /// The callback that arrives is not always for the navigation in hand. Since
    /// `navigate` returns at `didCommit`, a caller can start its next load while
    /// the previous page is still pulling images; `webView.load` cancels that
    /// one, and its terminal callback lands *after* the next continuation is
    /// installed. Resuming on it returns `navigate` before the new document has
    /// committed, and the caller harvests the previous search's payload —
    /// complete, plausible, and about the wrong query.
    ///
    /// A nil navigation is accepted rather than ignored: WebKit omits it on
    /// some paths, and a continuation nobody resumes hangs the caller forever.
    private func resumeCommittedNavigation(for navigation: WKNavigation?) {
        guard isCurrent(navigation) else { return }
        commitContinuation?.resume()
        commitContinuation = nil
        pendingNavigation = nil
    }

    private func isCurrent(_ navigation: WKNavigation?) -> Bool {
        guard let pendingNavigation, let navigation else { return true }
        return navigation === pendingNavigation
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
            self.resumeCommittedNavigation(for: navigation)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Fallback for unusual navigation paths where WebKit does not send
            // the expected commit callback.
            self.resumeCommittedNavigation(for: navigation)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.fail(navigation, error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.fail(navigation, error)
        }
    }

    /// A superseded load fails by definition — `webView.load` cancels whatever
    /// was in flight — so its error describes the load we walked away from, and
    /// recording it would put the engine in `.failed` over nothing.
    private func fail(_ navigation: WKNavigation?, _ error: Error) {
        guard isCurrent(navigation) else { return }
        state = .failed(error.localizedDescription)
        resumeCommittedNavigation(for: navigation)
    }
}
