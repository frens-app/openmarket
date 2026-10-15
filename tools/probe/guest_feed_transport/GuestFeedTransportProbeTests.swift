import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

// Opt-in network experiment. Copy into apps/ios/Tests only for an explicit run.
// At most 22 feed requests, no retries, plus two browser document loads.
// Public SF fixture coordinates; no account cookies or raw payloads are saved.
// Run xcodegen, then xcodebuild test with
// -only-testing:OpenMarketTests/GuestFeedTransportProbeTests. Remove the test
// copy and regenerate afterward. GUEST_TRANSPORT lines contain JSON results.
@MainActor
final class GuestFeedTransportProbeTests: XCTestCase {
    private let pacer = RequestPacer(nextGap: { 1 })
    private var preparedSurface: String?
    private var currentDocumentIDs: [String: String] = [:]

    func testGuestTransportComparison() async throws {
        executionTimeAllowance = 720
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let webConfiguration = WKWebViewConfiguration.make()
        webConfiguration.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900),
                                configuration: webConfiguration)
        browser.customUserAgent = Surface.desktop.userAgent
        let host = UIViewController()
        let window = UIWindow(frame: browser.frame)
        window.rootViewController = host
        host.view.addSubview(browser)
        window.makeKeyAndVisible()
        defer { browser.stopLoading(); window.isHidden = true }

        emit(["phase": "setup", "idle_timeout_s": 15, "total_timeout_s": 25,
              "radius_km": 16, "latitude": 37.7793, "longitude": -122.419,
              "max_explicit_feed_requests": 22, "retries": 0,
              "document_source": "browser_metadata_for_both_transports"])
        for round in 1...3 {
            let query = SearchQuery(kind: .browse, radiusKM: 16, citySlug: "sanfrancisco",
                                    coordinate: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.419))
            if round == 1 { _ = try await prepare(query, browser: browser) }
            let order = round == 2 ? ["webview", "http"] : ["http", "webview"]
            for transport in order {
                try await runChain(query, round: round, transport: transport, pages: 3,
                                   session: session, browser: browser)
            }
        }
        let search = SearchQuery(kind: .search("desk"), radiusKM: 16, citySlug: "sanfrancisco",
                                 coordinate: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.419))
        _ = try await prepare(search, browser: browser)
        for transport in ["webview", "http"] {
            try await runChain(search, round: 1, transport: transport, pages: 2,
                               session: session, browser: browser)
        }
        emit(["phase": "finished"])
    }

    private func runChain(_ query: SearchQuery, round: Int, transport: String, pages: Int,
                          session: URLSession, browser: WKWebView) async throws {
        let surface = query.kind == .browse ? "browse" : "search"
        var pagination = GraphQLFeedPagination()
        var startupMS = 0
        if transport == "webview" {
            do { startupMS = try await prepare(query, browser: browser) }
            catch {
                emit(["phase": "bootstrap_failure", "surface": surface, "round": round,
                      "transport": transport, "error": String(describing: error)])
                if (error as? GraphQLFeedError) == .blocked { throw error }
                return
            }
        }
        for pageIndex in 0..<pages {
            guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
            var request = try AnonymousFeedClient.request(for: query, cursor: pagination.cursor)
            let originalFields = formFields(request)
            let documentID = try XCTUnwrap(currentDocumentIDs[surface])
            let body = String(decoding: request.httpBody!, as: UTF8.self)
            request.httpBody = Data(body.replacingOccurrences(of: "doc_id=" + originalFields["doc_id"]!,
                                                            with: "doc_id=" + documentID).utf8)
            let fields = formFields(request)
            let started = ContinuousClock.now
            var row: [String: Any] = ["phase": "page", "surface": surface, "round": round,
                                      "transport": transport, "page": pageIndex,
                                      "startup_ms": pageIndex == 0 ? startupMS : 0,
                                      "document_id": documentID]
            let data: Data
            do {
                if transport == "http" {
                    let (body, response) = try await session.data(for: request)
                    data = body
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    row["status"] = status
                    if status == 403 || status == 429 { throw GraphQLFeedError.blocked }
                    guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
                } else {
                    try await assertGuest(browser)
                    guard let envelope = try await browser.callAsyncJavaScript(Self.fetchScript,
                        arguments: ["operationName": fields["fb_api_req_friendly_name"]!,
                                    "variables": fields["variables"]!, "expectedDocumentID": fields["doc_id"]!],
                        in: nil, contentWorld: .page) as? [String: Any] else {
                        throw GraphQLFeedError.invalidResponse
                    }
                    for key in ["status", "headers_ms", "max_chunk_gap_ms", "received_bytes",
                                "document_matches_http", "guest", "failure"] {
                        if let value = envelope[key] { row[key] = value }
                    }
                    let status = envelope["status"] as? Int ?? 0
                    if status == 403 || status == 429 { throw GraphQLFeedError.blocked }
                    if envelope["failure"] != nil {
                        row["request_ms"] = milliseconds(since: started)
                        row["success"] = false
                        emit(row)
                        return
                    }
                    guard (200..<300).contains(status), let text = envelope["text"] as? String else {
                        throw GraphQLFeedError.invalidResponse
                    }
                    data = Data(text.utf8)
                }
                row["request_ms"] = milliseconds(since: started)
                row["bytes"] = data.count
                for (key, value) in responseShape(data, browse: query.kind == .browse) { row[key] = value }
                let decoded = try GraphQLFeedDecoder.decode(data, kind: query.kind)
                let cards = try pagination.accept(decoded)
                row["success"] = true
                row["listings"] = decoded.listings.count
                row["new_listings"] = cards.count
                row["has_next_page"] = decoded.hasNextPage
                row["valid_cursor"] = !decoded.hasNextPage || !(decoded.endCursor ?? "").isEmpty
                emit(row)
                if !decoded.hasNextPage { return }
            } catch {
                row["request_ms"] = milliseconds(since: started)
                row["success"] = false
                row["error"] = error is URLError ? "url_error" : String(describing: error)
                row["error_code"] = (error as NSError).code
                emit(row)
                if (error as? GraphQLFeedError) == .blocked {
                    await pacer.recordBlock()
                    throw error
                }
                return
            }
        }
    }

    private func prepare(_ query: SearchQuery, browser: WKWebView) async throws -> Int {
        let surface = query.kind == .browse ? "browse" : "search"
        let fields = formFields(try AnonymousFeedClient.request(for: query, cursor: nil))
        let operation = fields["fb_api_req_friendly_name"]!
        if preparedSurface == surface { try await assertGuest(browser); return 0 }
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        let started = ContinuousClock.now
        var request = URLRequest(url: query.url)
        request.timeoutInterval = 20
        browser.load(request)
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var lastState: [String: Any] = [:]
        while ContinuousClock.now < deadline {
            if let state = try? await browser.callAsyncJavaScript(Self.readinessScript,
                arguments: ["operationName": operation], in: nil, contentWorld: .page) as? [String: Any] {
                lastState = state
                if state["ready"] as? Bool == true {
                    try await assertGuest(browser)
                    let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
                    let documentID = try XCTUnwrap(state["document_id"] as? String)
                    currentDocumentIDs[surface] = documentID
                    preparedSurface = surface
                    let elapsed = milliseconds(since: started)
                    emit(["phase": "bootstrap", "surface": surface, "startup_ms": elapsed,
                          "guest": true, "cookie_names": cookies.map(\.name).sorted(),
                          "browser_document_id": documentID, "production_document_id": fields["doc_id"]!,
                          "document_matches_production": documentID == fields["doc_id"]])
                    return elapsed
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        browser.stopLoading()
        emit(["phase": "bootstrap_state", "surface": surface, "state": lastState,
              "startup_ms": milliseconds(since: started)])
        throw URLError(.timedOut)
    }

    private func assertGuest(_ browser: WKWebView) async throws {
        let cookies = await browser.configuration.websiteDataStore.httpCookieStore.allCookies()
        guard !cookies.contains(where: { $0.name == "c_user" || $0.name == "xs" }) else {
            throw GraphQLFeedError.sessionChanged
        }
    }

    private func formFields(_ request: URLRequest) -> [String: String] {
        let form = String(decoding: request.httpBody!, as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: (URLComponents(string: "?" + form)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
    }

    private func responseShape(_ data: Data, browse: Bool) -> [String: Any] {
        var text = String(decoding: data, as: UTF8.self)
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        let records = text.split(whereSeparator: \.isNewline).compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        var hasInfo = false
        var errorCodes: [Int] = []
        for record in records {
            let body = record["data"] as? [String: Any] ?? [:]
            let connection = browse ? body["marketplace_home_feed"] as? [String: Any]
                : (body["marketplace_search"] as? [String: Any])?["feed_units"] as? [String: Any]
            if connection?["page_info"] is [String: Any] || body["page_info"] is [String: Any] { hasInfo = true }
            if let code = record["error"] as? Int { errorCodes.append(code) }
            errorCodes += (record["errors"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? Int }
        }
        return ["records": records.count, "has_page_info": hasInfo, "graphql_error_codes": errorCodes,
                "last_is_final": (records.last?["extensions"] as? [String: Any])?["is_final"] ?? NSNull()]
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }

    private func emit(_ row: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        print("GUEST_TRANSPORT " + String(decoding: data, as: UTF8.self))
    }

    private static let readinessScript = #"""
    const state = {ready: false, origin_ok: location.origin === 'https://www.facebook.com'};
    try {
        state.guest = String(require('CurrentUserInitialData').USER_ID) === '0';
        const op = require(operationName + '.graphql').params;
        state.operation_ok = op.name === operationName && op.operationKind === 'query';
        state.document_id = String(op.id);
        state.params_available = typeof require('getAsyncParams') === 'function';
        state.ready = state.origin_ok && state.guest && state.operation_ok && !!op.id && state.params_available;
    } catch (_) {}
    return state;
    """#

    private static let fetchScript = #"""
    const summary = {}, started = performance.now();
    if (location.origin !== 'https://www.facebook.com') return {failure:'origin'};
    let fields;
    try {
        const actor = String(require('CurrentUserInitialData').USER_ID);
        summary.guest = actor === '0';
        if (!summary.guest) return {...summary, failure:'session'};
        const op = require(operationName + '.graphql').params;
        if (op.name !== operationName || op.operationKind !== 'query' || !op.id) return {failure:'operation'};
        summary.document_matches_http = String(op.id) === expectedDocumentID;
        if (!summary.document_matches_http) return {...summary, failure:'document_mismatch'};
        const params = require('getAsyncParams')('POST');
        if (params.__user != null && String(params.__user) !== '0') return {failure:'session'};
        fields = new URLSearchParams(params);
        fields.set('__user','0'); fields.set('av','0');
        fields.set('fb_api_caller_class','RelayModern');
        fields.set('fb_api_req_friendly_name',operationName);
        fields.set('doc_id',String(op.id)); fields.set('variables',variables); fields.set('server_timestamps','true');
    } catch (_) { return {failure:'context'}; }
    const controller = new AbortController();
    let failure = 'network', idle, bytes = 0, lastChunk = started, maxGap = 0;
    const total = setTimeout(() => { failure = 'total_timeout'; controller.abort(); }, 25000);
    const armIdle = () => {
        clearTimeout(idle);
        idle = setTimeout(() => { failure = 'idle_timeout'; controller.abort(); }, 15000);
    };
    armIdle();
    try {
        const response = await fetch('/api/graphql/', {
            method:'POST', credentials:'same-origin', body:fields, signal:controller.signal,
            headers: {'Accept':'application/json'}
        });
        summary.status = response.status;
        summary.headers_ms = Math.round(performance.now() - started);
        if (!response.ok) return summary;
        armIdle();
        const reader = response.body.getReader(), decoder = new TextDecoder();
        let text = '';
        while (true) {
            const {value, done} = await reader.read();
            if (done) break;
            const now = performance.now();
            maxGap = Math.max(maxGap, now - lastChunk); lastChunk = now;
            armIdle(); bytes += value.byteLength;
            if (bytes > 5000000) { controller.abort(); return {...summary, failure:'size'}; }
            text += decoder.decode(value, {stream:true});
        }
        text += decoder.decode();
        return {...summary, text, received_bytes:bytes, max_chunk_gap_ms:Math.round(maxGap)};
    } catch (_) {
        return {...summary, failure, received_bytes:bytes, max_chunk_gap_ms:Math.round(maxGap)};
    } finally { clearTimeout(total); clearTimeout(idle); }
    """#
}
