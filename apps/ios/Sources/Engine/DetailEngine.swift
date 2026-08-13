import Foundation
import WebKit
import os

extension Logger {
    static let detail = Logger(subsystem: "lol.frens.openmarket", category: "detail")
}

/// Webview B — the fallback path to an item page, plus the session cache.
///
/// Not the usual path: tapping a card lands `FeedEngine` on the item page with
/// the full document already in its DOM, and loading it a second time here costs
/// ~4.4s of a ~6.5s tap for nothing. What remains is the route for cards the tap
/// can't reach — resolve the id by searching the desktop surface, then load the
/// page — and the cache both paths write into.
///
/// Detail pages are ordinary documents: description, condition, posted date,
/// photos and location all render logged out (seller identity does not).
@MainActor
final class DetailEngine: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView
    private let metrics: MetricsReporter
    private let pacer: RequestPacer


    /// The desktop surface is used here, not the mobile one. It caps search
    /// results at 15 with no pagination — irrelevant for a lookup — but unlike
    /// mobile it exposes real `/marketplace/item/{id}` anchors, which is the
    /// only reliable way to learn a listing's canonical URL. Its detail pages
    /// are also the richer ones.
    /// Item pages are loaded with the *mobile* UA: it is the only surface that
    /// publishes the seller's name, join date and rating. `resolveItemURL` still
    /// needs the desktop UA, which is why the agent is set per load, not once.
    static let mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"

    static let desktopUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/18.7 Safari/605.1.15"

    let session: BrowserSession

    /// Shares a store with the feed engine rather than getting its own, so a
    /// detail load reuses the scripts, stylesheets and fonts the search page in
    /// the next webview just downloaded — and, signed in, the session cookies,
    /// without which the page has no seller data to render.
    init(session: BrowserSession = .authed,
         metrics: MetricsReporter = LocalMetrics.shared,
         pacer: RequestPacer = .shared) {
        self.session = session
        self.metrics = metrics
        self.pacer = pacer
        let config = WKWebViewConfiguration.make()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 900), configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Self.desktopUserAgent
        blocker = Task { await Self.makeMediaBlocker() }
    }

    private var blocker: Task<WKContentRuleList?, Never>?
    private var blockerInstalled = false

    /// Stops this webview downloading media it will never display.
    ///
    /// The detail webview is offscreen and exists only to be read: the photos
    /// the user actually sees are fetched independently by `AsyncImage` from the
    /// URLs extracted here. So every image byte this page pulls is spent twice
    /// and shown once — and an item page carries 20-plus of them at full size.
    ///
    /// Blocking the *requests* leaves the `<img>` elements and their `src`
    /// attributes untouched, which is all the extractor reads, so the gallery is
    /// still recovered in full.
    private static func makeMediaBlocker() async -> WKContentRuleList? {
        let rules = """
        [{"trigger":{"url-filter":".*","resource-type":["image","media","font"]},
          "action":{"type":"block"}}]
        """
        return await withCheckedContinuation { continuation in
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "marketplace-no-media",
                encodedContentRuleList: rules
            ) { list, error in
                if let error {
                    Logger.detail.error("blocker compile failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: list)
            }
        }
    }

    private func installBlockerIfNeeded() async {
        guard !blockerInstalled else { return }
        blockerInstalled = true
        if let list = await blocker?.value {
            webView.configuration.userContentController.add(list)
            Logger.detail.info("media blocker installed")
        }
    }

    // MARK: - Resolving a listing's canonical URL

    /// Finds the item URL by searching the desktop surface for the listing's
    /// own title and matching the result back against its price and title.
    ///
    /// Last resort, not the main path. Tapping the card in the hidden feed
    /// does work — `FeedEngine.openItem` clicks it and the feed lands on the
    /// item page — so this runs only when there is no cached `itemURL` and the
    /// tap produced nothing, e.g. a card index gone stale under the feed. It
    /// costs one page load and a fuzzy title match, which is why it is the
    /// fallback rather than the mechanism.
    ///
    /// The fuzzy match could be retired: a listing's fbcdn filename segment is
    /// identical on both surfaces, so the desktop result can be joined to the
    /// mobile card exactly. See docs/surface-strategy.md §5a — and note the
    /// key is the *filename* segment, not the payload's
    /// `primary_listing_photo.id`, which is a different number.
    func resolveItemURL(for listing: Listing, citySlug: String?) async -> URL? {
        guard let title = listing.title, !title.isEmpty else { return nil }
        guard await pacer.waitForSlot() else { return nil }

        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"
        components.path = "/marketplace/\(citySlug ?? "sanfrancisco")/search/"
        components.queryItems = [URLQueryItem(name: "query", value: title)]
        guard let searchURL = components.url else { return nil }

        let started = Date()
        webView.customUserAgent = Self.desktopUserAgent
        await beginLoad(searchURL)

        guard let result = await poll(Self.itemLinksJS, as: ItemLinks.self,
                                      until: { !$0.items.isEmpty },
                                      timeout: .seconds(8)) else { return nil }

        guard let id = ItemMatcher.bestMatch(title: listing.title,
                                             priceText: listing.priceText,
                                             candidates: result.items) else {
            Logger.detail.info("no confident match for \(title, privacy: .public) among \(result.items.count)")
            return nil
        }
        await pacer.recordSuccess()
        Logger.detail.info("resolve ok in \(String(format: "%.2f", Date().timeIntervalSince(started)))s")
        return URL(string: "https://www.facebook.com/marketplace/item/\(id)/")
    }

    struct ItemCandidate: Decodable {
        let id: String
        let text: String
    }

    private struct ItemLinks: Decodable {
        let items: [ItemCandidate]
    }

    private static let itemLinksJS = """
    (function(){
      var links = Array.prototype.slice.call(document.querySelectorAll('a[href*="/marketplace/item/"]'));
      var seen = {}, out = [];
      links.forEach(function(a){
        var m = (a.getAttribute('href') || '').match(/marketplace\\/item\\/(\\d+)/);
        if (!m || seen[m[1]]) return;
        seen[m[1]] = 1;
        out.push({id: m[1], text: (a.textContent || '').slice(0, 200)});
      });
      return JSON.stringify({items: out});
    })()
    """

    /// Starts a load without waiting for it to finish, so `poll` can read the
    /// DOM the moment the content exists. `didFinish` on an item page waits for
    /// every photo to finish downloading, which is seconds after the
    /// description and the gallery URLs are already in the document.
    ///
    /// The outgoing document is marked first: a freshly loaded page won't carry
    /// the flag, which is how `poll` tells the new page from the old one
    /// without depending on URL matching that Facebook may rewrite.
    private func beginLoad(_ url: URL) async {
        _ = try? await webView.evaluateJavaScript("window.__mpStale = true")
        webView.load(URLRequest(url: url))
    }

    /// Evaluates `script` every `interval` until `isReady` accepts the decoded
    /// result, or `timeout` elapses — returning the last successful decode
    /// either way, so a partial read is still usable.
    ///
    /// This replaces a fixed `Task.sleep`, which was wrong in both directions:
    /// it burned the remainder of the wait on pages that hydrated early, and on
    /// slower ones it read a half-built DOM and reported failure for a page
    /// that would have loaded perfectly well a moment later.
    private func poll<T: Decodable>(_ script: String,
                                    as type: T.Type,
                                    until isReady: (T) -> Bool,
                                    timeout: Duration,
                                    // 40ms rather than 150ms: the poll is a
                                    // JavaScript call against an already-loaded
                                    // page, costing a millisecond or two, and
                                    // the old interval added up to a sixth of a
                                    // second of pure waiting to every open.
                                    interval: Duration = .milliseconds(40),
                                    firstReady: ((T) -> Bool)? = nil,
                                    onFirst: (@MainActor (T) -> Void)? = nil) async -> T? {
        // Yields null while the outgoing document is still in place, so a
        // half-navigated webview can never hand us the previous listing.
        let guarded = "(function(){ if (window.__mpStale) return null; return \(script); })()"
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var latest: T?
        var firedFirst = false
        while clock.now < deadline {
            if let json = try? await webView.evaluateJavaScript(guarded) as? String,
               let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(type, from: data) {
                latest = decoded
                if !firedFirst, firstReady?(decoded) == true {
                    firedFirst = true
                    onFirst?(decoded)
                }
                if isReady(decoded) { return decoded }
            }
            try? await Task.sleep(for: interval)
        }
        return latest
    }

    /// The preview is the screen; this only ever enhances it. Failure is
    /// quiet and the caller keeps showing what it already had.
    ///
    /// Deliberately uncached. Caching moved to `ListingCache`, which persists
    /// across launches — and every call that reaches here is now a *revalidation*,
    /// asked for precisely because the caller already has a cached copy and
    /// wants to know whether the price or the sold status has moved.
    /// `onPartial` fires as soon as the *text* is readable, which is well before
    /// the gallery is.
    ///
    /// Photos are not in the payload — measured: 25 rendered `<img>` against
    /// zero image URIs in the listing's own JSON — so they can only be read once
    /// the page has actually rendered them. Waiting for that before showing
    /// anything is what made an open feel like three seconds when the
    /// description was ready in well under one.
    func loadDetail(id: String, url: URL,
                    onPartial: @escaping @MainActor (ListingDetail) -> Void = { _ in }) async -> ListingDetail? {
        let started = Date()
        guard await pacer.waitForSlot() else { return nil }

        // The page must be the listing we asked for. A redirect, a wall, or
        // Marketplace's own landing page all render fine and would otherwise be
        // extracted as if they were the listing — that is how "Buy and sell in
        // your community on Marketplace" ended up as a description.
        let expectedID = url.marketplaceItemID

        await installBlockerIfNeeded()
        let slotAt = Date()
        // Desktop, not WebLite. Measured: the mobile item page spent 3.49s of a
        // 3.50s open just hydrating, because WebLite ships components and fills
        // them in afterwards, so there is nothing to read until it does. The
        // desktop page server-renders its data into the initial HTML, which is
        // readable roughly a second in. It is also the surface the grid now
        // uses, and — signed in — the only one carrying seller identity.
        webView.customUserAgent = Self.desktopUserAgent
        await beginLoad(url)
        let loadedAt = Date()

        // The description lands well before the gallery does, so requiring only
        // one of them returns a listing with no photos. Wait for both — `poll`
        // still hands back whatever it last saw if the gallery never arrives.
        // A login wall counts as ready: there's nothing more to wait for, and
        // polling the full ceiling would only delay the backoff.
        let script = expectedID.map(DesktopScripts.extractDetail(expectedID:))
            ?? WebLiteScripts.extractDetail
        var textAt: Date?
        guard let raw = await poll(script, as: RawDetail.self,
                                   until: { $0.loginWall || ($0.description != nil && !$0.photoURLs.isEmpty) },
                                   timeout: .seconds(8),
                                   firstReady: { $0.hasText },
                                   onFirst: { partial in
                                       textAt = Date()
                                       onPartial(partial.listingDetail)
                                   }) else {
            Logger.detail.warning("detail parse failed for \(url.absoluteString, privacy: .public)")
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        // Where the wait actually goes, so this is tuned against measurements
        // rather than intuition.
        Logger.detail.info("""
        detail split: pacer=\(String(format: "%.2f", slotAt.timeIntervalSince(started)))s \
        navigation=\(String(format: "%.2f", loadedAt.timeIntervalSince(slotAt)))s \
        text=\(textAt.map { String(format: "%.2f", $0.timeIntervalSince(loadedAt)) } ?? "n/a")s \
        photos=\(String(format: "%.2f", Date().timeIntervalSince(loadedAt)))s
        """)
        Logger.detail.info("detail ok: desc=\(raw.description != nil) photos=\(raw.photoURLs.count) cond=\(raw.conditionText != nil) sold=\(raw.isSold.map(String.init) ?? "nil", privacy: .public) pending=\(raw.isPending.map(String.init) ?? "nil", privacy: .public) coord=\(raw.latitude ?? "none", privacy: .public),\(raw.longitude ?? "none", privacy: .public) delivery=\(raw.deliveryTypes?.joined(separator: "+") ?? "nil", privacy: .public)")
        Logger.detail.info("seller: id=\(raw.sellerProfileID ?? "nil", privacy: .public) name=\(raw.sellerName ?? "nil", privacy: .public) rating=\(raw.sellerRatingText ?? "nil", privacy: .public) section=[\(raw.sellerSection ?? "nil", privacy: .public)]")

        // **The seller block lands after the readiness test is satisfied.**
        //
        // `until:` waits for the description and the gallery, and the seller
        // section renders later than both — so a perfectly good page was handed
        // back before Facebook had built it, and the extractor reported `none of
        // 1460 nodes` for a section that is there seconds later. That is the
        // whole bug: seller identity was never part of "ready", so whether it
        // appeared was a race the app always lost on a fast page.
        //
        // **Re-polling is the whole fix; there is deliberately no scroll here.**
        // One was written on the theory that the block is below the fold, and it
        // reported `moved: nothing` on the very page that produced a seller
        // 33 ms later — so it never did the work. It was then removed rather
        // than kept as insurance, because it is not free: this page keeps its
        // data in the rendered markup, so scrolling can unmount the nodes the
        // description and the `Listed …` line are read out of. A step that has
        // never helped and can cost fields is worse than no step.
        //
        // Deliberately *after* the caller already has text and photos on screen,
        // so it costs the user nothing they are waiting on, and conditional — a
        // page that already produced a seller, or a login wall, has nothing to
        // gain.
        var best = raw
        if best.sellerName == nil, best.sellerProfileID == nil, !best.loginWall {
            // **Merged, never swapped.** Taking the later snapshot wholesale
            // regressed the description: this read happens seconds later and
            // after a scroll, so any field that has degraded in the meantime —
            // a recycled description block, a `Listed …` line that now abuts a
            // button — replaced a perfectly good earlier one. The second read
            // exists to answer one question, so it may only contribute the
            // answer to that question.
            if let revealed = await poll(script, as: RawDetail.self,
                                         until: { $0.sellerName != nil || $0.sellerProfileID != nil },
                                         timeout: .seconds(3)),
               revealed.sellerName != nil || revealed.sellerProfileID != nil {
                best.sellerProfileID = revealed.sellerProfileID
                best.sellerName = revealed.sellerName
                best.sellerJoined = revealed.sellerJoined
                best.sellerRatingText = revealed.sellerRatingText
                best.sellerRatingCount = revealed.sellerRatingCount
                best.sellerIsHighlyRated = revealed.sellerIsHighlyRated
                best.sellerSection = revealed.sellerSection
            }
            Logger.detail.info("seller on re-poll: id=\(best.sellerProfileID ?? "still nil", privacy: .public) name=\(best.sellerName ?? "still nil", privacy: .public) desc=\(best.description != nil) section=[\(best.sellerSection ?? "nil", privacy: .public)]")
        }
        if !raw.matches(expectedID) {
            Logger.detail.warning("wrong page: wanted \(expectedID ?? "none", privacy: .public), got \(raw.itemId ?? "none", privacy: .public)")
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        if raw.loginWall {
            metrics.loginWallHit(surface: "detail")
            await pacer.recordBlock()
            metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: false)
            return nil
        }
        await pacer.recordSuccess()

        metrics.detailLatency(seconds: Date().timeIntervalSince(started), succeeded: true)
        return best.listingDetail
    }

    /// Facebook prints a seller's score as "4.8 (12)" — the star average and
    /// the number of ratings behind it, in one run of text.
    static func rating(from text: String?) -> Double? {
        guard let head = text?.split(separator: "(").first else { return nil }
        return Double(head.trimmingCharacters(in: .whitespaces))
    }

    static func ratingCount(from text: String?) -> Int? {
        guard let text, let open = text.firstIndex(of: "("),
              let close = text.firstIndex(of: ")"), open < close else { return nil }
        return Int(text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces))
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Logger.detail.warning("navigation failed: \(error.localizedDescription, privacy: .public)")
    }
}
