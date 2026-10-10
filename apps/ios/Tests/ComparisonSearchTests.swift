import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class ComparisonSearchTests: XCTestCase {

    func testComparisonAdsDoNotChangeFeedTotals() async throws {
        let ads = FilterTotals.shared.ads
        let nonLocal = FilterTotals.shared.nonLocalListings
        var response = try page(ids: ["1"], sold: [false])
        response.filteredAdCount = 7
        let search = ComparableSearch(client: ComparisonFeedStub(pages: [response]))
        let result = await search.comparables(to: "desk", citySlug: "sanfrancisco",
                                             radiusKM: 40, coordinate: point)
        XCTAssertEqual(try result.get().count, 1)
        XCTAssertEqual(FilterTotals.shared.ads, ads)
        XCTAssertEqual(FilterTotals.shared.nonLocalListings, nonLocal)
    }
    private let point = CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.419)

    func testSearchPairOverlapsAndNeverExceedsPoolCapacity() async throws {
        let client = ComparisonFeedStub(delay: .milliseconds(150))
        let pool = MarketCheckPool(searches: (0..<2).map { _ in
            ComparableSearch(client: client)
        })
        async let first = pool.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        async let second = pool.comparables(to: "chair", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        let pairs = await [first, second]
        for pair in pairs {
            XCTAssertEqual(try pair.active.result.get().count, 1)
            XCTAssertEqual(try pair.sold.result.get().count, 1)
        }
        let peak = await client.peak
        let calls = await client.queries
        XCTAssertEqual(peak, 2, "Independent searches must overlap, bounded by the two engines")
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.filter { $0.age == .month && $0.availability == .unavailable }.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.coordinate?.latitude == point.latitude && $0.delivery == .localPickup })
        XCTAssertTrue(pool.hasFreeSearch)
    }

    func testSoldFailureDoesNotDiscardActiveResultsOrLeakEngine() async throws {
        let client = ComparisonFeedStub(failSold: true)
        let pool = MarketCheckPool(searches: [ComparableSearch(client: client)])
        let pair = await pool.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        XCTAssertEqual(try pair.active.result.get().count, 1)
        XCTAssertThrowsError(try pair.sold.result.get())
        XCTAssertTrue(pool.hasFreeSearch)
    }

    func testSoldSearchExcludesPendingAndUnknownStatus() async throws {
        let client = ComparisonFeedStub(pages: [try page(ids: ["100000001", "100000002", "100000003"], sold: [true, false, nil])])
        let search = ComparableSearch(client: client)
        let result = await search.soldComparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        XCTAssertEqual(try result.get().map(\.listing.itemURL?.marketplaceItemID), ["100000001"])
    }

    func testAnonymousTransportRecoversEmptyAdvancingPageWithoutNavigating() async throws {
        let client = ComparisonFeedStub(pages: [
            GraphQLFeedPage(listings: [], endCursor: "A", hasNextPage: true),
            try page(ids: ["1"], sold: [false])
        ])
        let search = ComparableSearch(client: client)
        let result = await search.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        XCTAssertEqual(try result.get().count, 1)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
        XCTAssertNil(search.webView.url, "Successful anonymous queries need no browser warmup")
        XCTAssertFalse(search.webView.configuration.websiteDataStore.isPersistent)
        let cookies = await search.webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        XCTAssertTrue(cookies.isEmpty, "Fallback must not inherit the browsing account's cookies")
    }

    func testBlockAndVerifiedEmptyNeverNavigateBrowser() async throws {
        for error in [GraphQLFeedError.blocked, .paused, .sessionChanged] {
            let engine = DesktopFeedEngine()
            let client = ComparisonFeedStub(error: error)
            let search = ComparableSearch(engine: engine, client: client)
            let result = await search.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
            XCTAssertThrowsError(try result.get())
            XCTAssertEqual(engine.state, .idle)
        }
        let client = ComparisonFeedStub(pages: [.init(listings: [], endCursor: nil, hasNextPage: false)])
        let engine = DesktopFeedEngine()
        let search = ComparableSearch(engine: engine, client: client)
        let result = await search.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 40, coordinate: point)
        guard case .failure(.nothingFound) = result else { return XCTFail("Expected a verified empty market") }
        XCTAssertEqual(engine.state, .idle)
    }

    func testUTCDateWindowMatchesBrowserAndRollsOverAtMidnight() throws {
        let midnight = Date(timeIntervalSince1970: 20728 * 86400)
        let values = try XCTUnwrap(AnonymousFeedClient.creationDays(age: .month, now: midnight)).split(separator: ";")
        XCTAssertEqual(values.count, 31)
        XCTAssertEqual(values.first, "20728")
        XCTAssertEqual(values.last, "20698")
        XCTAssertEqual(AnonymousFeedClient.creationDays(age: .day, now: midnight.addingTimeInterval(-1)), "20727;20726")
        XCTAssertEqual(AnonymousFeedClient.creationDays(age: .day, now: midnight.addingTimeInterval(86399)), "20728;20727")
        XCTAssertNil(AnonymousFeedClient.creationDays(age: .any, now: midnight))
        let query = SearchQuery(kind: .search("desk"), radiusKM: 40, citySlug: "sanfrancisco", coordinate: point,
                                delivery: .localPickup, age: .month, availability: .unavailable)
        let request = try AnonymousFeedClient.request(for: query, cursor: nil, now: midnight)
        let form = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let serialized = try XCTUnwrap(URLComponents(string: "?" + form)?.queryItems?.first { $0.name == "variables" }?.value)
        let variables = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
        let params = try XCTUnwrap(variables["params"] as? [String: Any])
        let browse = try XCTUnwrap(params["browse_request_params"] as? [String: Any])
        XCTAssertEqual(browse["commerce_search_and_rp_ctime_days"] as? String, values.joined(separator: ";"))
        XCTAssertEqual(browse["commerce_search_and_rp_available"] as? Bool, false)
        XCTAssertEqual(browse["commerce_search_and_rp_in_stock_v2"] as? String, "")
    }

    func testRenderedCardsCanFallBackWithoutWaitingForPayloadTimeout() async throws {
        let engine = DesktopFeedEngine(pacer: RequestPacer())
        engine.webView.loadHTMLString("<html><body><a href='/marketplace/item/100000001/'>Desk $20</a></body></html>",
                                      baseURL: URL(string: "https://www.facebook.com"))
        let start = ContinuousClock.now
        let payload = await engine.harvest(timeout: .seconds(4), markupGrace: .milliseconds(100))
        XCTAssertTrue(payload.isEmpty)
        XCTAssertGreaterThan(engine.coverage.rendered, 0)
        XCTAssertLessThan(start.duration(to: .now), .seconds(3), "Rendered evidence should bypass the payload timeout")
        let locationStart = ContinuousClock.now
        _ = await engine.readLocation(pillTimeout: .zero)
        XCTAssertLessThan(locationStart.duration(to: .now), .seconds(1), "Missing diagnostic pill must not stall comparison")
    }

    private func page(ids: [String], sold: [Bool?]) throws -> GraphQLFeedPage {
        let listings = zip(ids, sold).map { id, status -> [String: Any] in
            ["node": ["listing": ["id": id, "marketplace_listing_title": "Desk", "is_sold": status as Any? ?? NSNull()]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["data": ["marketplace_search": ["feed_units": [
            "edges": listings, "page_info": ["has_next_page": false]
        ]]]])
        return try GraphQLFeedDecoder.decode(data, kind: .search("desk"))
    }
}

private actor ComparisonFeedStub: GraphQLFeedLoading {
    var queries: [SearchQuery] = []
    var cursors: [String?] = []
    var peak = 0
    private var inFlight = 0
    private let delay: Duration
    private let failSold: Bool
    private let error: GraphQLFeedError?
    private var pages: [GraphQLFeedPage]?

    init(delay: Duration = .zero, failSold: Bool = false, error: GraphQLFeedError? = nil, pages: [GraphQLFeedPage]? = nil) {
        self.delay = delay
        self.failSold = failSold
        self.error = error
        self.pages = pages
    }

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        queries.append(query)
        cursors.append(cursor)
        inFlight += 1
        peak = max(peak, inFlight)
        defer { inFlight -= 1 }
        try await Task.sleep(for: delay)
        if let error { throw error }
        if failSold && query.availability == .unavailable { throw GraphQLFeedError.blocked }
        if pages != nil { return pages!.removeFirst() }
        let raw = #"{"data":{"marketplace_search":{"feed_units":{"edges":[{"node":{"listing":{"id":"1","marketplace_listing_title":"Desk","is_sold":true}}}],"page_info":{"has_next_page":false}}}}}"#
        return try GraphQLFeedDecoder.decode(Data(raw.utf8), kind: query.kind)
    }
}

final class RequestPacerTests: XCTestCase {
    func testConcurrentReservationsRemainSpaced() async {
        let pacer = RequestPacer(nextGap: { 0.1 })
        let start = ContinuousClock.now
        let departures = await withTaskGroup(of: Duration.self, returning: [Duration].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    let allowed = await pacer.waitForSlot()
                    XCTAssertTrue(allowed)
                    return start.duration(to: .now)
                }
            }
            var times: [Duration] = []
            for await time in group { times.append(time) }
            return times.sorted()
        }
        for (a, b) in zip(departures, departures.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, .milliseconds(80))
        }
    }

    func testBlockDuringReservedWaitPreventsDeparture() async {
        let pacer = RequestPacer(nextGap: { 0.3 })
        _ = await pacer.waitForSlot()
        let waiting = Task { await pacer.waitForSlot() }
        try? await Task.sleep(for: .milliseconds(30))
        await pacer.recordBlock()
        let allowed = await waiting.value
        XCTAssertFalse(allowed)
    }

    func testCancelledReservationDoesNotSendRequest() async {
        let pacer = RequestPacer(nextGap: { 0.3 })
        _ = await pacer.waitForSlot()
        let waiting = Task { await pacer.waitForSlot() }
        try? await Task.sleep(for: .milliseconds(30))
        waiting.cancel()
        let allowed = await waiting.value
        XCTAssertFalse(allowed)
    }
}
