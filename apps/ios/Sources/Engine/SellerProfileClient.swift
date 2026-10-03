import Foundation
import WebKit

@MainActor
final class SellerProfileClient: NSObject, SellerInventoryLoading, WKNavigationDelegate {
    let webView: WKWebView
    private let pacer: RequestPacer
    private let currentActor: () async -> String?
    private var generation = UUID()
    private var actor: String?
    private var profile: SellerProfile?
    private var resolvedID: String?
    private var sellerPhotoURL: URL?
    private var filter: SellerListingFilter = .available
    private var cursor: String?
    private var cursors = Set<String>()
    private var hasMore = false
    private var navigationError: Error?
    private var pendingNavigation: WKNavigation?
    private var navigationCommitted = false

    init(pacer: RequestPacer = .shared, dataStore: WKWebsiteDataStore? = nil,
         webView: WKWebView? = nil,
         currentActor: @escaping () async -> String? = { await SessionState.facebookActor() }) {
        self.pacer = pacer
        self.currentActor = currentActor
        let configuration = WKWebViewConfiguration.make()
        if let dataStore { configuration.websiteDataStore = dataStore }
        self.webView = webView ?? WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        super.init()
        self.webView.customUserAgent = Surface.desktop.userAgent
        self.webView.navigationDelegate = self
    }

    func cancel() {
        generation = UUID()
        webView.stopLoading()
        pendingNavigation = nil
        navigationCommitted = false
    }

    func load(profile: SellerProfile, filter: SellerListingFilter) async throws -> SellerInventoryPage {
        cancel()
        let request = generation
        self.profile = profile
        self.filter = filter
        resolvedID = nil
        sellerPhotoURL = nil
        cursor = nil
        cursors = []
        hasMore = false
        actor = await currentActor()
        guard actor != nil else { throw SellerInventoryError.signInRequired }
        try await check(request)
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        try await check(request)
        navigationError = nil
        pendingNavigation = webView.load(URLRequest(url: profile.url))
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        while ContinuousClock.now < deadline {
            try await check(request)
            if let navigationError { throw navigationError }
            if webView.url?.path.hasPrefix("/login") == true { throw SellerInventoryError.signInRequired }
            // A same-URL reload retains the previous document until didCommit.
            // Fetching from it can fail as that document is replaced.
            if navigationCommitted, webView.url?.path == profile.url.path,
               let json = try? await webView.callAsyncJavaScript(Self.bootstrap,
                   arguments: ["sellerID": profile.id, "expectedActor": actor ?? "0"], in: nil, contentWorld: .page) as? String,
               let data = json.data(using: .utf8),
               let snapshot = try? JSONDecoder().decode(Bootstrap.self, from: data) {
                if snapshot.blocked {
                    await pacer.recordBlock()
                    throw GraphQLFeedError.blocked
                }
                if snapshot.unavailable { throw SellerInventoryError.unavailable }
                if snapshot.ready, let records = snapshot.records, let recordsData = records.data(using: .utf8) {
                    let page: SellerGraphQLPage
                    do { page = try SellerGraphQLDecoder.decode(recordsData, rootKey: "profile") }
                    catch GraphQLFeedError.invalidResponse {
                        // Initial edges precede deferred page_info.
                        try await Task.sleep(for: .milliseconds(250))
                        continue
                    }
                    try await check(request)
                    resolvedID = page.profileID
                    sellerPhotoURL = snapshot.photos?.first(where: { $0.id == page.profileID || $0.id == profile.id })
                        .flatMap { SellerProfile.validatedPhotoURL($0.uri) }
                    if filter == .available {
                        let result = try accept(page)
                        await pacer.recordSuccess()
                        return result
                    }
                    return try await fetch(cursor: nil, request: request)
                }
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SellerInventoryError.unsupported
    }

    func nextPage() async throws -> SellerInventoryPage {
        guard hasMore else { return SellerInventoryPage(items: [], hasMore: false) }
        return try await fetch(cursor: cursor, request: generation)
    }

    private func fetch(cursor: String?, request: UUID) async throws -> SellerInventoryPage {
        try await check(request)
        // Inventory refetch requires authentication even though Facebook's
        // public HTML can expose an initial page (see seller_profile probe).
        guard let actor else { throw SellerInventoryError.signInRequired }
        guard let resolvedID, let profile, webView.url?.path == profile.url.path else {
            throw GraphQLFeedError.invalidResponse
        }
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        try await check(request)
        let variables: [String: Any] = ["id": resolvedID, "count": 12, "cursor": cursor as Any? ?? NSNull(),
            "availabilities": filter == .available ? ["IN_STOCK"] : ["PENDING", "OUT_OF_STOCK"],
            "order": "CREATION_TIMESTAMP_DESC", "scale": 2, "search": NSNull()]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: variables), as: UTF8.self)
        do {
            let envelope = try await webView.callAsyncJavaScript(DetailGraphQLClient.fetchScript,
                arguments: ["operationName": "MarketplaceSellerProfileInventoryListPaginationQuery",
                    "documentID": "27189364780746738", "variables": encoded,
                    "expectedActor": actor, "requestID": UUID().uuidString], in: nil, contentWorld: .page)
            try await check(request)
            let data = try DetailGraphQLClient.decodeEnvelope(envelope)
            let page = try SellerGraphQLDecoder.decode(data, rootKey: "node", expectedID: resolvedID, unavailableInventory: filter == .unavailable)
            let result = try accept(page)
            await pacer.recordSuccess()
            return result
        } catch GraphQLFeedError.blocked {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
    }

    private func accept(_ page: SellerGraphQLPage) throws -> SellerInventoryPage {
        if page.hasMore {
            guard let next = page.cursor, !cursors.contains(next), next != cursor else {
                throw GraphQLFeedError.invalidResponse
            }
        }
        cursor = page.cursor
        if let cursor { cursors.insert(cursor) }
        hasMore = page.hasMore
        return SellerInventoryPage(items: page.items, hasMore: page.hasMore, sellerPhotoURL: sellerPhotoURL)
    }

    private func check(_ request: UUID) async throws {
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        guard actor == (await currentActor()) else { throw GraphQLFeedError.sessionChanged }
        guard request == generation else { throw CancellationError() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === pendingNavigation else { return }
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let navigation, navigation === pendingNavigation else { return }
        navigationCommitted = true
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let navigation, navigation === pendingNavigation else { return }
        if (error as NSError).code != NSURLErrorCancelled { navigationError = error }
    }

    private struct Bootstrap: Decodable {
        struct Photo: Decodable { let id: String; let uri: String? }
        let photos: [Photo]?
        let records: String?
        let ready: Bool
        let blocked: Bool
        let unavailable: Bool
    }

    static let bootstrap = #"""
    if (location.pathname !== '/marketplace/profile/' + sellerID + '/') return null;
    const results = [];
    const photos = [];
    let matchesRequest = false;
    function walk(x) {
        if (!x || typeof x !== 'object') return;
        if (x.queryName === 'MarketplaceSellerProfileInventoryQuery' && x.variables?.sellerID === sellerID) matchesRequest = true;
        const r = x.__bbox?.result;
        const user = r?.data?.user;
        if (user?.id) {
            const uri = user.commerce_profile_picture_with_fallback_160?.uri || user.profile_picture_160?.uri;
            if (uri) photos.push({id:user.id,uri});
        }
        if (r && (r.data?.profile?.marketplace_listing_sets ||
            (r.path?.[0] === 'profile' && r.path?.[1] === 'marketplace_listing_sets'))) results.push(r);
        for (const value of Object.values(x)) walk(value);
    }
    for (const script of document.querySelectorAll('script[type="application/json"]')) {
        try { walk(JSON.parse(script.textContent)); } catch (_) {}
    }
    let ready = false;
    try { ready = require('CurrentUserInitialData').USER_ID === expectedActor && !!require('getAsyncParams')('POST').fb_dtsg; } catch (_) {}
    const body = document.body?.innerText || '';
    return JSON.stringify({ready,photos,records: matchesRequest && results.length ? JSON.stringify(results) : null,
        blocked: /temporarily blocked|too many requests/i.test(body),
        unavailable: /This content isn't available|This page isn't available/i.test(body)});
    """#
}
