import Foundation
import CoreLocation
import WebKit
import os

extension Logger {
    static let place = Logger(subsystem: "lol.frens.openmarket", category: "place")
}

/// The cheap location resolver available while there is no Facebook account
/// session to preserve.
///
/// Facebook's logged-out location dialog ultimately makes this single GraphQL
/// request to turn a coordinate into the path component Marketplace expects.
/// Calling it directly avoids loading Marketplace, opening the React dialog,
/// waiting for its map, applying, and loading the result again. The request is
/// deliberately cookie-free: it resolves a URL, but does not try to preserve
/// the dialog's more precise session-local coordinate. That precision is useful
/// to a signed-in session; for an anonymous session it is short-lived and not
/// worth the roughly fifteen-second UI round trip.
///
/// This is an internal Facebook operation and its document id can rotate. A
/// failure therefore means "use the picker", not "the location is invalid" —
/// `PlaceChooser` owns that fallback.
struct UnauthenticatedMarketplacePlaceResolver {
    private static let endpoint = URL(string: "https://www.facebook.com/api/graphql/")!
    private static let friendlyName = "MarketplaceBuyLocationDialogLocationUrlQuery"
    private static let documentID = "9608405655935574"

    private let pacer: RequestPacer

    init(pacer: RequestPacer = .shared) {
        self.pacer = pacer
    }

    func resolve(_ coordinate: CLLocationCoordinate2D,
                 name: String,
                 origin: ResolvedPlace.Origin) async
        -> Result<ResolvedPlace, MarketplacePlaceResolver.Failure> {
        guard !Task.isCancelled else { return .failure(.superseded) }
        guard await pacer.waitForSlot() else { return .failure(.paced) }
        guard !Task.isCancelled else { return .failure(.superseded) }

        let started = ContinuousClock.now
        guard let request = request(for: coordinate) else {
            return .failure(.unresolved)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Successful probes are ~80–200 ms. Do not let a rotating internal
        // operation add another long wait before the proven picker fallback.
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        do {
            let (body, response) = try await session.data(for: request)
            guard !Task.isCancelled else { return .failure(.superseded) }
            guard let http = response as? HTTPURLResponse else {
                return .failure(.unresolved)
            }
            if http.statusCode == 403 || http.statusCode == 429 {
                await pacer.recordBlock()
                Logger.place.error("anonymous direct resolve was blocked (HTTP \(http.statusCode, privacy: .public))")
                return .failure(.paced)
            }
            guard (200..<300).contains(http.statusCode),
                  let answer = decode(body),
                  let segment = safeSegment(answer.marketplaceVanityID) else {
                Logger.place.error("anonymous direct resolve returned no usable URL segment (HTTP \(http.statusCode, privacy: .public))")
                return .failure(.unresolved)
            }

            await pacer.recordSuccess()
            let elapsed = started.duration(to: .now)
            let milliseconds = elapsed.components.seconds * 1_000
                + elapsed.components.attoseconds / 1_000_000_000_000_000
            let browseURL = "https://www.facebook.com/marketplace/\(segment)/"
            Logger.place.info("anonymous direct resolve -> \(name, privacy: .public) [\(segment, privacy: .public)] in \(milliseconds, privacy: .public)ms")
            return .success(ResolvedPlace(name: name,
                                          segment: segment,
                                          coordinate: coordinate,
                                          origin: origin,
                                          browseURL: browseURL,
                                          verifiedAt: Date()))
        } catch is CancellationError {
            return .failure(.superseded)
        } catch {
            Logger.place.error("anonymous direct resolve failed: \(error.localizedDescription, privacy: .public)")
            return .failure(.unresolved)
        }
    }

    private func request(for coordinate: CLLocationCoordinate2D) -> URLRequest? {
        let variablesObject: [String: Any] = [
            "buy_location": [
                "latitude": coordinate.latitude,
                "longitude": coordinate.longitude
            ]
        ]
        guard JSONSerialization.isValidJSONObject(variablesObject),
              let variablesData = try? JSONSerialization.data(withJSONObject: variablesObject),
              let variables = String(data: variablesData, encoding: .utf8) else { return nil }

        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "__user", value: "0"),
            URLQueryItem(name: "__a", value: "1"),
            URLQueryItem(name: "__comet_req", value: "15"),
            URLQueryItem(name: "av", value: "0"),
            URLQueryItem(name: "fb_api_caller_class", value: "RelayModern"),
            URLQueryItem(name: "fb_api_req_friendly_name", value: Self.friendlyName),
            URLQueryItem(name: "server_timestamps", value: "true"),
            URLQueryItem(name: "variables", value: variables),
            URLQueryItem(name: "doc_id", value: Self.documentID)
        ]
        guard let body = form.percentEncodedQuery?.data(using: .utf8) else { return nil }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 2
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // A browser UA makes Facebook expect browser-page CSRF fields. This is
        // intentionally a native, token-free anonymous request instead.
        request.setValue("OpenMarket/0.0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func decode(_ body: Data) -> BuyLocation? {
        // Facebook sometimes protects JSON endpoints with this non-JSON prefix.
        let guardPrefix = Data("for (;;);".utf8)
        let json = body.starts(with: guardPrefix) ? Data(body.dropFirst(guardPrefix.count)) : body
        return try? JSONDecoder().decode(Response.self, from: json)
            .data?.viewer?.marketplaceFeedStories?.buyLocation
    }

    private func safeSegment(_ candidate: String) -> String? {
        guard !candidate.isEmpty,
              candidate.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte)
                      || (97...122).contains(byte) || byte == 45 || byte == 95
              }) else { return nil }
        return candidate
    }

    private struct Response: Decodable {
        let data: Payload?
    }

    private struct Payload: Decodable {
        let viewer: Viewer?
    }

    private struct Viewer: Decodable {
        let marketplaceFeedStories: FeedStories?

        enum CodingKeys: String, CodingKey {
            case marketplaceFeedStories = "marketplace_feed_stories"
        }
    }

    private struct FeedStories: Decodable {
        let buyLocation: BuyLocation?

        enum CodingKeys: String, CodingKey {
            case buyLocation = "buy_location"
        }
    }

    private struct BuyLocation: Decodable {
        let marketplaceVanityID: String

        enum CodingKeys: String, CodingKey {
            case marketplaceVanityID = "marketplace_vanity_id"
        }
    }
}

/// Turns a coordinate into a place Facebook recognises, by asking Facebook.
///
/// Named for what it does and where the answer comes from: the resolution is
/// Facebook's, performed in its own picker (`GeoPickerScripts`). The app
/// supplies a coordinate and reads back a place — it never derives a slug
/// itself, which is the whole point. Both user journeys are the same call:
///
/// * **"Use my location"** — the device's CoreLocation fix.
/// * **"Browse another city"** — a coordinate from Apple's search completer
///   (`AppleMapsCitySearch`), so the user can pick anywhere at all rather than
///   from a list somebody curated.
///
/// Runs on the app's shared store, **deliberately**, and this is the whole
/// reason it works.
///
/// It used to use a throwaway non-persistent store so the resolution touched
/// nothing. That looked tidy and quietly threw away most of what the ten-second
/// round-trip bought: Facebook keeps the fed coordinate in *session state* and
/// ranks results by proximity to it, so a resolution performed in a store that
/// is then discarded leaves the searches with a city slug and nothing else
/// (`docs/location.md` §5).
///
/// The cost is real and was accepted knowingly: for a signed-in user, the
/// coordinate is now associated with their Facebook session rather than an
/// anonymous one.
@MainActor
final class MarketplacePlaceResolver: NSObject, WKNavigationDelegate {
    enum Failure: Error, Equatable {
        /// The header pill wasn't there, so the dialog was never opened.
        case noPill
        /// The dialog opened but the centring arrow wasn't in it.
        case noArrow
        /// The arrow was clicked but never called the shim.
        case notAsked
        /// Facebook resolved to nothing usable — no place segment in the URL.
        case unresolved
        /// It resolved, but a fresh load of the resulting URL didn't come back
        /// naming that place. The characteristic failure of this whole area:
        /// the results look fine and are for somewhere else.
        case notConfirmed(shown: String?)
        /// The pacer refused the request — a backoff is in progress, or the
        /// session cap is spent. Nothing was changed.
        case paced
        /// The caller cancelled: the user asked for a different place before
        /// this one finished. Distinct from every failure above because nothing
        /// went wrong and nobody wants to be told about it — see
        /// `PlaceChooser.resolve`.
        case superseded
    }

    private let webView: WKWebView
    private var navContinuation: CheckedContinuation<Void, Never>?
    private let pacer: RequestPacer

    init(pacer: RequestPacer = .shared) {
        self.pacer = pacer
        let config = WKWebViewConfiguration.make()
        config.userContentController.addUserScript(
            WKUserScript(source: GeoPickerScripts.feeder,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false)
        )
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                            configuration: config)
        super.init()
        webView.navigationDelegate = self
        webView.customUserAgent = Surface.desktop.userAgent
    }

    /// Hands Facebook a coordinate and reports back what it called the place.
    ///
    /// Deliberately sequential with real waits rather than a single injected
    /// script: every step here is a React re-render that has to land before the
    /// next selector exists, and the picker's own network round-trip sits in
    /// the middle of it.
    ///
    /// **Cancellable at every step boundary.** The steps themselves can't be
    /// interrupted — a navigation or an `evaluateJavaScript` runs to
    /// completion — but a cancelled run stops between them and returns
    /// `.superseded` rather than spending the remaining eight-odd seconds
    /// producing an answer nobody is waiting for. That matters more than a
    /// saved round trip: a resolution leaves a coordinate in Facebook's session
    /// state, so a stale one still running when the next begins is the thing
    /// that makes two switches interfere.
    func resolve(_ coordinate: CLLocationCoordinate2D,
                 origin: ResolvedPlace.Origin) async -> Result<ResolvedPlace, Failure> {
        let started = Date()
        func mark(_ stage: String) {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            Logger.place.info("timing \(stage, privacy: .public) +\(ms, privacy: .public)ms")
        }

        guard await navigate(to: URL(string: "https://www.facebook.com/marketplace/")!) else {
            return .failure(Task.isCancelled ? .superseded : .paced)
        }
        mark("loaded")
        guard !Task.isCancelled else { return .failure(.superseded) }

        _ = await js(GeoPickerScripts.arm(latitude: coordinate.latitude,
                                          longitude: coordinate.longitude))

        guard await waitFor(GeoPickerScripts.pillPresent) else {
            guard !Task.isCancelled else { return .failure(.superseded) }
            Logger.place.error("resolve: no location pill")
            return .failure(.noPill)
        }
        let opened = await js(GeoPickerScripts.openDialog)
        Logger.place.info("opened dialog: \(opened, privacy: .public)")
        guard opened.contains("\"opened\":true") else {
            Logger.place.error("resolve: no location pill")
            return .failure(.noPill)
        }
        guard await waitFor(GeoPickerScripts.arrowPresent) else {
            guard !Task.isCancelled else { return .failure(.superseded) }
            let seen = await js(GeoPickerScripts.describeDialog)
            Logger.place.error("resolve: no centring arrow — \(seen, privacy: .public)")
            return .failure(.noArrow)
        }
        mark("dialog")
        guard !Task.isCancelled else { return .failure(.superseded) }

        _ = await js(GeoPickerScripts.armArrowLatch)
        let arrow = await js(GeoPickerScripts.clickArrow)
        guard arrow.contains("\"clicked\":true") else {
            Logger.place.error("resolve: no centring arrow")
            return .failure(.noArrow)
        }
        guard arrow.contains("\"called\":true") else {
            Logger.place.error("resolve: arrow did not ask for a position")
            return .failure(.notAsked)
        }
        mark("arrow")

        // Bounded, and proceeding anyway on timeout is safe: applying too early
        // commits the old place, and `confirm` catches exactly that. A slow
        // failure that reports itself beats a fast one that doesn't.
        _ = await waitFor(GeoPickerScripts.arrowSettled, timeout: .seconds(6))
        // The last point at which walking away is free. Past `apply`, Facebook's
        // session state has already moved, so a cancelled run still has to be
        // assumed to have changed something — which is exactly why the next
        // switch waits for this one to unwind before starting its own.
        guard !Task.isCancelled else { return .failure(.superseded) }
        _ = await js(GeoPickerScripts.snapshotURL)
        _ = await js(GeoPickerScripts.apply)
        _ = await waitFor(GeoPickerScripts.urlChanged)
        mark("applied")
        guard !Task.isCancelled else { return .failure(.superseded) }

        let result = await js(GeoPickerScripts.readResult)
        let url = value(in: result, key: "url").flatMap(URL.init(string:))
        let place = MarketplaceURLPlace.parse(url)
        guard let segment = place.segment, place.isExplicit else {
            Logger.place.error("resolve: unresolved — \(place.summaryDescription, privacy: .public)")
            return .failure(.unresolved)
        }
        // Provisional only. The pill here is read moments after Apply and
        // routinely still shows the *previous* place — resolving Oakland Park
        // from a San Francisco session read back "San Francisco" against the
        // new place's id. `confirm` replaces this with the name from its own
        // fresh, polled load.
        let name = value(in: result, key: "name") ?? segment.capitalized
        let browseURL = url?.absoluteString
        Logger.place.info("resolved \(coordinate.latitude, privacy: .public),\(coordinate.longitude, privacy: .public) -> \(name, privacy: .public) [\(segment, privacy: .public)]")

        // Applying is not the same as it having worked.
        defer { mark("confirmed") }
        return await confirm(ResolvedPlace(name: name, segment: segment,
                                           coordinate: coordinate, origin: origin,
                                           browseURL: browseURL))
    }

    /// Loads the resulting URL from scratch and checks that the page comes back
    /// naming the place we think we set.
    ///
    /// This is not belt-and-braces. A refused place doesn't error — Facebook
    /// rewrites the path and serves the IP-inferred city with a full, healthy
    /// result set (`docs/location.md` §3), so "it applied" and "it worked" are
    /// genuinely different claims and only one of them is worth storing.
    ///
    /// Deliberately a **fresh navigation** rather than reading the page still on
    /// screen. The post-Apply page was mutated client-side by React and would
    /// tell us what the picker believes; what matters is what the server does
    /// with this URL on a cold request, which is the request every later search
    /// will make.
    func confirm(_ place: ResolvedPlace) async -> Result<ResolvedPlace, Failure> {
        guard let target = place.browseURL.flatMap(URL.init(string:)) else {
            return .failure(.unresolved)
        }
        guard await navigate(to: target) else {
            return .failure(Task.isCancelled ? .superseded : .paced)
        }
        // The pill renders after the payload — measured at up to ~2.5 s — so a
        // single read here would report "no pill" for a page that has one.
        _ = await waitFor(GeoPickerScripts.pillPresent, timeout: .seconds(8))
        guard !Task.isCancelled else { return .failure(.superseded) }
        let located = await readLocation()
        Logger.place.info("confirm \(place.segment, privacy: .public): \(located.summary, privacy: .public)")

        // The **segment** is what gets checked, not the name.
        //
        // It is the thing every later search actually uses, and it is the thing
        // Facebook rewrites when it refuses a place. Comparing display names
        // instead produced false rejections: the name captured just after Apply
        // is often the previous place's, so a perfectly good change looked like
        // a mismatch and was thrown away.
        guard located.wasAccepted, located.urlPlace.segment == place.segment else {
            return .failure(.notConfirmed(shown: located.pill?.placeName))
        }
        var confirmed = place
        // Now the name can be trusted: this page was loaded cold and its pill
        // was polled for, so it describes the place actually in the URL.
        if let verified = located.pill?.placeName, !verified.isEmpty {
            confirmed.name = verified
        }
        confirmed.verifiedPill = located.pill?.rawPillText
        confirmed.verifiedAt = Date()
        return .success(confirmed)
    }

    /// Reads the URL's place and the rendered pill together, so a disagreement
    /// between them is visible rather than averaged away.
    private func readLocation() async -> DesktopPageLocation {
        let raw = await js(GeoPickerScripts.readResult)
        let url = value(in: raw, key: "url").flatMap(URL.init(string:))
        let pillText = value(in: raw, key: "pill")
        return DesktopPageLocation(urlPlace: MarketplaceURLPlace.parse(url),
                                   pill: pillText.map(DesktopLocationPill.init(rawPillText:)))
    }

    // MARK: - Plumbing

    private func flag(_ script: String, _ key: String) async -> Bool {
        await js(script).contains("\"\(key)\":true")
    }

    /// Polls a script until it reports `ready`, or gives up.
    ///
    /// Every wait in this file used to be a fixed sleep, which is the wrong
    /// instrument twice over: it costs the full duration on a fast run, and on
    /// a slow one it isn't enough — a measured run loaded the page in 4.2 s and
    /// still had no pill 4 s later, failing the whole resolution. Waiting for
    /// the actual condition is both quicker and steadier.
    private func waitFor(_ script: String,
                         timeout: Duration = .seconds(12),
                         every: Duration = .milliseconds(200)) async -> Bool {
        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        // Cancellation ends the poll rather than merely making every sleep
        // return instantly — `try?` swallows the cancellation error, so without
        // this the loop would spin flat out until the deadline, hammering the
        // webview on behalf of a switch the user has already replaced.
        while !Task.isCancelled, Date() < deadline {
            if await flag(script, "ready") { return true }
            try? await Task.sleep(for: every)
        }
        return false
    }

    private func value(in json: String, key: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object[key] as? String, !text.isEmpty else { return nil }
        return text
    }

    private func js(_ script: String) async -> String {
        let result = try? await webView.evaluateJavaScript(script)
        return (result as? String) ?? ""
    }

    /// Paced like every other request the app makes.
    ///
    /// A resolution is two page loads, and they used to go out entirely outside
    /// the pacer — invisible to the session cap and, worse, to the backoff
    /// ladder. Now that these requests carry the user's session they are the
    /// last ones that should be exempt.
    ///
    /// Returns false when the pacer refuses, which surfaces as a resolution
    /// failure rather than a silent partial run.
    @discardableResult
    private func navigate(to url: URL) async -> Bool {
        // Checked before the slot is claimed: a cancelled run shouldn't spend
        // one of the session's 300 requests on a page nobody will read.
        guard !Task.isCancelled else { return false }
        guard await pacer.waitForSlot() else {
            Logger.place.error("navigate: paced out")
            return false
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navContinuation = cont
            webView.load(URLRequest(url: url))
        }
        return true
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            navContinuation?.resume()
            navContinuation = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            navContinuation?.resume()
            navContinuation = nil
        }
    }
}

private extension MarketplaceURLPlace {
    /// For the log line, which needs a plain description of the refusal.
    var summaryDescription: String {
        switch self {
        case .citySlug(let s): "slug \(s)"
        case .placeID(let id): "place id \(id)"
        case .ipInferred: "IP-inferred (place refused)"
        case .refused: "refused"
        case .notAPlaceURL: "not a place URL"
        }
    }
}
