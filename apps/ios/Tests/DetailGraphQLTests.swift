import WebKit
import XCTest
@testable import OpenMarket

final class DetailDecoderTests: XCTestCase {
    func testCompleteFieldsAndSellerOnlyRatings() throws {
        let detail = try GraphQLDetailDecoder.core(detailFixture(), itemID: "123456789")
        XCTAssertEqual(detail.description, String(repeating: "Full description. ", count: 100))
        XCTAssertEqual(detail.conditionText, "Used - Good")
        XCTAssertEqual(detail.latitude, 37)
        XCTAssertEqual(detail.longitude, -122)
        XCTAssertEqual(detail.sellerProfileID, "987654321")
        XCTAssertEqual(detail.sellerJoined, "Joined Facebook in 2000")
        XCTAssertEqual(detail.sellerRating, 4.8)
        XCTAssertEqual(detail.sellerRatingCount, 12)
        XCTAssertEqual(detail.sellerIsHighlyRated, true)
        XCTAssertEqual(detail.isSold, false)
        XCTAssertEqual(detail.isPending, true)
        XCTAssertTrue(detail.fulfillment?.doorDropoff == true)
        XCTAssertNotNil(detail.postedText)
    }

    func testPrivateOrUnknownRatingsNeverDisplayEvenWhenNumbersExist() throws {
        for privacy: Any in [true, NSNull(), 0] {
            let detail = try GraphQLDetailDecoder.core(detailFixture(privacy: privacy), itemID: "123456789")
            XCTAssertNil(detail.sellerRating)
            XCTAssertNil(detail.sellerRatingCount)
            XCTAssertNotNil(detail.sellerName)
        }
    }

    func testMissingFieldsRemainUnknownAndCoordinatesRequireValidPair() throws {
        let data = try detailFixture(overrides: ["is_sold": NSNull(), "is_pending": 1, "delivery_types": NSNull(),
            "location": ["latitude": 120, "longitude": -122], "commerce_badges_info": ["source_summary": NSNull()],
            "marketplace_listing_seller": NSNull()])
        let detail = try GraphQLDetailDecoder.core(data, itemID: "123456789")
        XCTAssertNil(detail.isSold)
        XCTAssertNil(detail.isPending)
        XCTAssertNil(detail.fulfillment)
        XCTAssertNil(detail.latitude)
        XCTAssertNil(detail.longitude)
        XCTAssertNil(detail.sellerName)
        XCTAssertNil(detail.sellerIsHighlyRated)
    }

    func testWrongTargetAndNullTargetCannotBorrowRelatedListing() throws {
        XCTAssertThrowsError(try GraphQLDetailDecoder.core(detailFixture(id: "555555555"), itemID: "123456789"))
        let data = try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["marketplace_product_details_page": [
            "target": NSNull(), "related": ["id": "123456789", "redacted_description": ["text": "wrong"]]]]]])
        XCTAssertThrowsError(try GraphQLDetailDecoder.core(data, itemID: "123456789"))
    }

    func testMediaOnlyAcceptsOwnGalleryAndPreservesOrderWithoutDuplicates() throws {
        let photos = try GraphQLDetailDecoder.photos(mediaFixture(), itemID: "123456789")
        XCTAssertEqual(photos.map(\.absoluteString), ["https://example.com/one.jpg", "https://example.com/two.jpg"])
        XCTAssertThrowsError(try GraphQLDetailDecoder.photos(mediaFixture(id: "wrong"), itemID: "123456789"))
        XCTAssertThrowsError(try GraphQLDetailDecoder.photos(detailFixture(), itemID: "123456789"))
    }

    func testStreamedTargetPatchAndLateErrorsAreValidated() throws {
        let initial = try detailFixture()
        let patch = try JSONSerialization.data(withJSONObject: ["path": ["viewer", "marketplace_product_details_page", "target"],
                                                               "data": ["is_sold": true]])
        var stream = Data("for (;;);".utf8)
        stream.append(initial); stream.append(Data("\n".utf8)); stream.append(patch)
        XCTAssertEqual(try GraphQLDetailDecoder.core(stream, itemID: "123456789").isSold, true)
        stream.append(Data("\n{\"errors\":[{\"message\":\"Too many requests\"}]}".utf8))
        XCTAssertThrowsError(try GraphQLDetailDecoder.core(stream, itemID: "123456789")) {
            XCTAssertEqual($0 as? GraphQLFeedError, .blocked)
        }
        let unrelated = try JSONSerialization.data(withJSONObject: ["path": ["related"], "data": ["is_sold": true]])
        XCTAssertThrowsError(try GraphQLDetailDecoder.core(initial + Data("\n".utf8) + unrelated, itemID: "123456789"))
    }

    func testRequestCarriesCanonicalIDAndHasNoSessionCredentials() throws {
        for operation in DetailGraphQLOperation.allCases {
            let request = try operation.request(itemID: "123456789")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let fields = URLComponents(string: "?" + String(decoding: request.httpBody!, as: UTF8.self))!.queryItems!
            XCTAssertFalse(fields.contains { ["fb_dtsg", "lsd", "jazoest"].contains($0.name) })
            let vars = try JSONSerialization.jsonObject(with: Data(fields.first { $0.name == "variables" }!.value!.utf8)) as! [String: Any]
            XCTAssertEqual(vars["targetId"] as? String, "123456789")
        }
        XCTAssertThrowsError(try DetailGraphQLOperation.core.request(itemID: "p:photo"))
    }
}

@MainActor
final class DetailTransportTests: XCTestCase {
    private func client(actor: @escaping () async -> String? = { nil }) -> DetailGraphQLClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DetailURLProtocol.self]
        return DetailGraphQLClient(pacer: RequestPacer(nextGap: { 0.01 }), configuration: config, currentActor: actor)
    }

    func testCorePublishesBeforeGalleryAndCookiesNeverReturn() async throws {
        DetailURLProtocol.configure { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let core = detailRequestIsCore(request)
            return (200, core ? try! detailFixture() : try! mediaFixture(), core ? 0 : 0.15)
        }
        let client = client()
        var stages: [ListingDetail] = []
        let result = try await client.load(itemID: "123456789", actor: nil) { stages.append($0) }
        XCTAssertEqual(stages.count, 2)
        XCTAssertTrue(stages[0].photoURLs.isEmpty)
        XCTAssertEqual(stages[1].photoURLs.count, 2)
        XCTAssertEqual(result.photoURLs.count, 2)
        _ = try await client.load(itemID: "123456789", actor: nil)
        XCTAssertEqual(DetailURLProtocol.requestCount, 4)
    }

    func testSessionChangeRejectsRemainingStages() async throws {
        DetailURLProtocol.configure { request in
            let core = detailRequestIsCore(request)
            return (200, core ? try! detailFixture() : try! mediaFixture(), core ? 0 : 0.15)
        }
        var actor: String?
        let client = client { actor }
        var stages = 0
        do {
            _ = try await client.load(itemID: "123456789", actor: nil) { _ in stages += 1; actor = "new_account" }
            XCTFail("Expected account change")
        } catch { XCTAssertEqual(error as? GraphQLFeedError, .sessionChanged) }
        XCTAssertEqual(stages, 1)
    }

    func testAuthenticatedRequestWithoutPreparedBrowserNeverUsesGuestSession() async {
        DetailURLProtocol.configure { _ in XCTFail("No native request expected"); return (200, Data(), 0) }
        do {
            _ = try await client(actor: { "account" }).load(itemID: "123456789", actor: "account")
            XCTFail("Expected browser preparation fallback")
        } catch { XCTAssertEqual(error as? GraphQLFeedError, .unsupportedQuery) }
        XCTAssertEqual(DetailURLProtocol.requestCount, 0)
    }

    func testAuthenticatedFetchReusesPreparedFeedContextWithoutNavigation() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let browser = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 800), configuration: config)
        let core = String(decoding: try detailFixture(), as: UTF8.self)
        let media = String(decoding: try mediaFixture(), as: UTF8.self)
        let script = """
        <script>
        window.probeCalls = [];
        window.require = function(name) {
          if (name === 'CurrentUserInitialData') return {USER_ID:'test_actor'};
          if (name === 'getAsyncParams') return function() {return {__user:'test_actor',fb_dtsg:'test_token'};};
          throw new Error('Not loaded');
        };
        window.fetch = async function(url, options) {
          const fields = options.body;
          window.probeCalls.push({url, actor:fields.get('av'), credentials:options.credentials,
            target:JSON.parse(fields.get('variables')).targetId, token:fields.get('fb_dtsg')});
          return {ok:true,status:200,text:async () => JSON.stringify(fields.get('fb_api_req_friendly_name') === 'MarketplacePDPContainerQuery' ? \(core) : \(media))};
        };
        window.probeReady = true;
        </script>
        """
        browser.loadHTMLString(script, baseURL: URL(string: "https://www.facebook.com/marketplace/sanfrancisco/search/"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if (try? await browser.evaluateJavaScript("window.probeReady")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let before = browser.url
        let client = DetailGraphQLClient(pacer: RequestPacer(nextGap: { 0.01 }), webViews: { [browser] }, currentActor: { "test_actor" })
        let result = try await client.load(itemID: "123456789", actor: "test_actor")
        XCTAssertEqual(result.sellerName, "Example Seller")
        XCTAssertEqual(result.photoURLs.count, 2)
        XCTAssertEqual(browser.url, before)
        let calls = try await browser.evaluateJavaScript("window.probeCalls") as! [[String: Any]]
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertEqual(call["actor"] as? String, "test_actor")
            XCTAssertEqual(call["credentials"] as? String, "same-origin")
            XCTAssertEqual(call["target"] as? String, "123456789")
            XCTAssertEqual(call["token"] as? String, "test_token")
        }
    }

    func testBlockBacksOffAndCancellationPublishesNothing() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DetailURLProtocol.self]
        let pacer = RequestPacer(nextGap: { 0.2 })
        DetailURLProtocol.configure { _ in (429, Data(), 0) }
        let client = DetailGraphQLClient(pacer: pacer, configuration: config, currentActor: { nil })
        do { _ = try await client.load(itemID: "123456789", actor: nil); XCTFail("Expected block") }
        catch { XCTAssertEqual(error as? GraphQLFeedError, .blocked) }
        let allowed = await pacer.waitForSlot()
        XCTAssertFalse(allowed)
        XCTAssertEqual(DetailURLProtocol.requestCount, 1)

        DetailURLProtocol.configure { request in (200, detailRequestIsCore(request) ? try! detailFixture() : try! mediaFixture(), 0.3) }
        let cancellable = self.client()
        var stages = 0
        let task = Task { try await cancellable.load(itemID: "123456789", actor: nil) { _ in stages += 1 } }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch {}
        XCTAssertEqual(stages, 0)
    }

    func testAuthenticatedFailuresDoNotBecomeFallbackEligible() {
        for (envelope, error): ([String: Any], GraphQLFeedError) in [
            (["failure": "session"], .sessionChanged), (["status": 403], .blocked), (["status": 429], .blocked)
        ] {
            XCTAssertThrowsError(try DetailGraphQLClient.decodeEnvelope(envelope)) {
                XCTAssertEqual($0 as? GraphQLFeedError, error)
                XCTAssertFalse(error.permitsBrowserFallback)
            }
        }
        XCTAssertThrowsError(try DetailGraphQLClient.decodeEnvelope(["failure": "timeout"])) {
            XCTAssertEqual(($0 as? URLError)?.code, .timedOut)
        }
    }

    func testEngineRoutesByActorAndNeverNavigatesOnSuccessOrBlock() async {
        for actor in [nil, "account"] as [String?] {
            let stub = DetailStub()
            let engine = DetailEngine(graphQL: stub, actorProvider: { actor })
            let value = await engine.loadDetail(id: "p:photo", url: URL(string: "https://www.facebook.com/marketplace/item/123456789/")!)
            XCTAssertNotNil(value)
            XCTAssertEqual(stub.itemID, "123456789")
            XCTAssertEqual(stub.actor, actor)
            XCTAssertNil(engine.webView.url)
            XCTAssertEqual(engine.lastTransport, actor == nil ? "anonymous_graphql" : "authenticated_graphql")
        }
        for error in [GraphQLFeedError.blocked, .paused, .sessionChanged] {
            let stub = DetailStub(error: error)
            let engine = DetailEngine(graphQL: stub, actorProvider: { nil })
            let value = await engine.loadDetail(id: "p:photo", url: URL(string: "https://www.facebook.com/marketplace/item/123456789/")!)
            XCTAssertNil(value)
            XCTAssertNil(engine.webView.url)
        }
    }

    func testSupersededEngineRequestCannotPublish() async throws {
        let stub = DetailStub(delay: .milliseconds(120))
        let engine = DetailEngine(graphQL: stub, actorProvider: { nil })
        let url = URL(string: "https://www.facebook.com/marketplace/item/123456789/")!
        var firstStages = 0
        let first = Task { await engine.loadDetail(id: "old", url: url) { _ in firstStages += 1 } }
        try await Task.sleep(for: .milliseconds(20))
        let second = await engine.loadDetail(id: "new", url: url)
        let stale = await first.value
        XCTAssertNil(stale)
        XCTAssertNotNil(second)
        XCTAssertEqual(firstStages, 0)
    }
}

@MainActor
private final class DetailStub: GraphQLDetailLoading {
    var itemID: String?
    var actor: String?
    let error: GraphQLFeedError?
    let delay: Duration
    init(error: GraphQLFeedError? = nil, delay: Duration = .zero) { self.error = error; self.delay = delay }
    func load(itemID: String, actor: String?, onPartial: @escaping @MainActor (ListingDetail) -> Void) async throws -> ListingDetail {
        self.itemID = itemID; self.actor = actor
        if let error { throw error }
        try await Task.sleep(for: delay)
        let value = ListingDetail(description: "Detail")
        onPartial(value)
        return value
    }
}

private func detailFixture(id: String = "123456789", privacy: Any = false, overrides: [String: Any] = [:]) throws -> Data {
    var target: [String: Any] = [
        "id": id, "marketplace_listing_title": "Desk",
        "redacted_description": ["text": String(repeating: "Full description. ", count: 100)],
        "creation_time": 1700000000, "location_text": ["text": "San Francisco, CA"],
        "attribute_data": [["attribute_name": "Condition", "label": "Used - Good"]],
        "location": ["latitude": 37, "longitude": -122], "is_sold": false, "is_pending": true,
        "delivery_types": ["IN_PERSON", "DOOR_DROPOFF"],
        "commerce_badges_info": ["source_summary": "Highly rated on Marketplace"],
        "marketplace_listing_seller": ["id": "987654321", "name": "Example Seller", "join_time": 946684800,
            "marketplace_ratings_stats_by_role_v2": ["seller_ratings_are_private": privacy,
                "seller_stats": ["five_star_ratings_average": 4.8, "five_star_total_rating_count_by_role": 12],
                "seller_buyer_combined": ["five_star_ratings_average": 4.9, "five_star_total_rating_count_by_role": 99]]]
    ]
    target.merge(overrides) { _, new in new }
    return try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["marketplace_product_details_page": ["target": target]]]])
}

private func mediaFixture(id: String = "123456789") throws -> Data {
    let photos: [[String: Any]] = [
        ["id": "1", "image": ["uri": "https://example.com/one.jpg"]],
        ["id": "2", "image": ["uri": "https://example.com/two.jpg"]],
        ["id": "1", "image": ["uri": "https://example.com/one-other-size.jpg"]]
    ]
    return try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["marketplace_product_details_page": [
        "target": ["id": id, "listing_photos": photos],
        "related": ["listing_photos": [["id": "other", "image": ["uri": "https://example.com/wrong.jpg"]]]]]]]])
}

private func detailRequestIsCore(_ request: URLRequest) -> Bool {
    var data = request.httpBody ?? Data()
    if let stream = request.httpBodyStream {
        stream.open(); defer { stream.close() }
        var bytes = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&bytes, maxLength: bytes.count)
            if count <= 0 { break }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
    return String(decoding: data, as: UTF8.self).contains("MarketplacePDPContainerQuery")
}

private final class DetailURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, Data, TimeInterval)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var count = 0
    private var work: DispatchWorkItem?
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler!
        Self.count += 1
        Self.lock.unlock()
        let (status, data, delay) = handler(request)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.work?.isCancelled == false else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Set-Cookie": "probe=value; Path=/"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}
