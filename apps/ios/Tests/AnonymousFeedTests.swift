import CoreLocation
import XCTest
@testable import OpenMarket

final class AnonymousFeedDecoderTests: XCTestCase {
    func testBrowseTopPicksUseTheirSeparateFormattedPriceField() throws {
        let raw = #"{"data":{"marketplace_home_feed":{"edges":[{"node":{"marketplace_listings":[{"id":"101","marketplace_listing_title":"Plant","listing_price":{"amount":"20"},"formatted_price":{"text":"$20"}}]}}],"page_info":{"has_next_page":false}}}}"#
        let page = try GraphQLFeedDecoder.decode(Data(raw.utf8), kind: .browse)
        XCTAssertEqual(page.listings.first?.priceAmount, "20")
        XCTAssertEqual(page.listings.first?.makeListing(cardIndex: 0).priceText, "$20")
    }

    func testAuthenticatedAdPatchesAreIgnoredWithoutDroppingSearchListings() throws {
        let initial = #"{"data":{"marketplace_search":{"feed_units":{"edges":[{"node":{"listing":{"id":"101","marketplace_listing_title":"Plant"}}},{"node":{"__typename":"MarketplaceFeedAdStory","story":{}}}],"page_info":{"has_next_page":true,"end_cursor":"A"}}}}}"#
        let patch = #"{"path":["marketplace_search","feed_units","edges",1,"node","story","attachments",0,"media"],"data":{"instream_extra_config":null}}"#
        let page = try GraphQLFeedDecoder.decode(Data([initial, patch].joined(separator: "\n").utf8), kind: .search("plant"))
        XCTAssertEqual(page.listings.map(\.id), ["101"])
        XCTAssertTrue(page.hasNextPage)
        let wrongEdge = patch.replacingOccurrences(of: "\"edges\",1", with: "\"edges\",0")
        XCTAssertThrowsError(try GraphQLFeedDecoder.decode(Data([initial, wrongEdge].joined(separator: "\n").utf8), kind: .search("plant")))
    }

    func testAuthenticatedBrowseAdPatchCanFollowDeferredPageInfo() throws {
        let initial = #"{"data":{"marketplace_home_feed":{"edges":[{"node":{"marketplace_listings":[{"id":"101","marketplace_listing_title":"Plant"}]}}]}}}"#
        let ad = #"{"path":["marketplace_home_feed","edges",1],"data":{"node":{"__typename":"MarketplaceFeedAdStory","story":{}}}}"#
        let info = #"{"path":["marketplace_home_feed"],"data":{"page_info":{"has_next_page":true,"end_cursor":"A"}}}"#
        let patch = #"{"path":["marketplace_home_feed","edges",1,"node","story","attachments",0,"media"],"data":{"instream_extra_config":null}}"#
        let page = try GraphQLFeedDecoder.decode(Data([initial, ad, info, patch].joined(separator: "\n").utf8), kind: .browse)
        XCTAssertEqual(page.listings.map(\.id), ["101"])
        XCTAssertEqual(page.endCursor, "A")
    }

    func testSearchKeepsCanonicalIDAndUnknownStatus() throws {
        let page = try GraphQLFeedDecoder.decode(searchResponse(), kind: .search("desk"))
        let card = try XCTUnwrap(page.listings.first)
        XCTAssertEqual(card.id, "101")
        XCTAssertEqual(card.title, "Desk with \"drawers\"")
        XCTAssertEqual(card.creationTime, 1790817303)
        XCTAssertNil(card.isSold)
        XCTAssertTrue(card.deliveryTypes.isEmpty)
        XCTAssertEqual(card.makeListing(cardIndex: 0).itemURL?.absoluteString, "https://www.facebook.com/marketplace/item/101/")
        XCTAssertTrue(page.hasNextPage)
    }

    func testBrowseReadsStreamedEdgesInOrderAndCanonicalListingID() throws {
        let initial = #"{"data":{"marketplace_home_feed":{"edges":[{"node":{"marketplace_listings":[{"id":"101","marketplace_listing_title":"Desk","listing_price":{"amount":"20","formatted_amount":"$20"},"is_sold":false}]}}]}}}"#
        let edge = #"{"path":["marketplace_home_feed","edges",1],"data":{"node":{"__typename":"MarketplaceFeedGeneralListingObject","data":{"product_item_id":"999","title":"Chair","price":{"currency":"CAD","amount_with_offset":"12345"}},"listing":{"id":"202","creation_time":1790817303},"entity":{"location":{"reverse_geocode":{"city":"Toronto","state":"ON"}}},"photo":{"default_image":{"uri":"https://example.com/photo.jpg"}}}}}"#
        let last = #"{"path":["marketplace_home_feed"],"data":{"page_info":{"has_next_page":false,"end_cursor":null}},"extensions":{"is_final":true}}"#
        let page = try GraphQLFeedDecoder.decode(Data([initial, edge, last].joined(separator: "\n").utf8), kind: .browse)
        XCTAssertEqual(page.listings.map(\.id), ["101", "202"])
        XCTAssertEqual(page.listings[1].priceAmount, "123.45")
        XCTAssertEqual(page.listings[1].locationText, "Toronto, ON")
        XCTAssertNil(page.listings[1].isSold)
        XCTAssertFalse(page.hasNextPage)
        XCTAssertNil(page.endCursor)
    }

    func testPartialErrorsAndTruncatedStreamsAreNotAnEmptySuccess() {
        let responses = [
            #"{"data":{"marketplace_search":{"feed_units":{"edges":[],"page_info":{"has_next_page":false}}}},"errors":[{"message":"query changed"}]}"#,
            #"{"data":{"marketplace_home_feed":{"edges":[]}}}"#,
            #"{"data":null}"#,
            "<html>Log in</html>"
        ]
        for response in responses {
            XCTAssertThrowsError(try GraphQLFeedDecoder.decode(Data(response.utf8), kind: .browse))
        }
    }

    func testRateLimitGraphQLErrorIsNotEligibleForBrowserFallback() {
        let data = Data(#"{"errors":[{"message":"Too many requests"}],"data":null}"#.utf8)
        XCTAssertThrowsError(try GraphQLFeedDecoder.decode(data, kind: .browse)) {
            XCTAssertEqual($0 as? GraphQLFeedError, .blocked)
        }
        XCTAssertFalse(GraphQLFeedError.blocked.permitsBrowserFallback)
        XCTAssertFalse(GraphQLFeedError.paused.permitsBrowserFallback)
    }

    func testCursorDeduplicatesIDsAndRejectsCyclesWithoutAdvancing() throws {
        let card = try XCTUnwrap(GraphQLFeedDecoder.decode(searchResponse(), kind: .search("desk")).listings.first)
        var paging = GraphQLFeedPagination()
        XCTAssertEqual(try paging.accept(.init(listings: [card, card], endCursor: "A", hasNextPage: true)).count, 1)
        XCTAssertEqual(try paging.accept(.init(listings: [], endCursor: "B", hasNextPage: true)).count, 0)
        XCTAssertTrue(paging.hasNextPage)
        XCTAssertThrowsError(try paging.accept(.init(listings: [card], endCursor: "A", hasNextPage: true)))
        XCTAssertEqual(paging.cursor, "B")
        XCTAssertTrue(try paging.accept(.init(listings: [card], endCursor: nil, hasNextPage: false)).isEmpty)
        XCTAssertFalse(paging.hasNextPage)
    }

    func testRequestUsesCoordinateAndPreservesFiltersAndFormEscaping() throws {
        var query = testQuery("desk + chair & lamp")
        query.delivery = .localPickup
        query.sort = .priceLowest
        query.conditions = [.new, .usedGood]
        query.minPrice = 30
        query.maxPrice = 90
        let request = try AnonymousFeedClient.request(for: query, cursor: "a+b&c=d")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let fields = try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems)
        let serialized = try XCTUnwrap(fields.first { $0.name == "variables" }?.value)
        let vars = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(serialized.utf8)) as? [String: Any])
        let params = try XCTUnwrap(vars["params"] as? [String: Any])
        let browse = try XCTUnwrap(params["browse_request_params"] as? [String: Any])
        XCTAssertEqual(vars["cursor"] as? String, "a+b&c=d")
        XCTAssertEqual((params["bqf"] as? [String: Any])?["query"] as? String, "desk + chair & lamp")
        XCTAssertEqual((params["bqf"] as? [String: Any])?["callsite"] as? String, "COMMERCE_MKTPLACE_WWW")
        XCTAssertEqual(browse["filter_location_latitude"] as? Double, 40.706)
        XCTAssertEqual(browse["filter_price_lower_bound"] as? Int, 3000)
        XCTAssertEqual(browse["filter_price_upper_bound"] as? Int, 9000)
        XCTAssertEqual(browse["commerce_search_sort_by"] as? String, "PRICE_ASCEND")
        XCTAssertEqual(browse["commerce_search_and_rp_condition"] as? String, "new,used_good")
        XCTAssertEqual(browse["commerce_enable_shipping"] as? Bool, false)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(fields.contains { ["fb_dtsg", "lsd", "jazoest"].contains($0.name) })
    }

    func testUnsupportedQueryFallsBackRatherThanLosingFiltersOrGuessingLocation() {
        var query = testQuery()
        query.coordinate = nil
        XCTAssertThrowsError(try AnonymousFeedClient.request(for: query, cursor: nil))
        query = testQuery()
        query.kind = .category("Furniture")
        XCTAssertThrowsError(try AnonymousFeedClient.request(for: query, cursor: nil))
    }

    private func searchResponse() -> Data {
        Data(#"for (;;);{"data":{"marketplace_search":{"feed_units":{"edges":[{"node":{"listing":{"id":"101","marketplace_listing_title":"Desk with \"drawers\"","creation_time":1790817303,"listing_price":{"amount":"20","formatted_amount":"$20"}}}}],"page_info":{"end_cursor":"next","has_next_page":true}}}}}"#.utf8)
    }
}

@MainActor
final class AnonymousFeedStoreTests: XCTestCase {
    func testSignedInSearchUsesAuthenticatedGraphQLAndResetsCursorOnSignOut() async {
        let authenticated = StubFeed([.success(testPage(["101"], cursor: "auth-A")),
                                      .success(testPage(["202"], cursor: nil))])
        let anonymous = StubFeed([.success(testPage(["303"], cursor: nil))])
        let store = ListingStore(prefs: makePreferences(), cache: makeCache(), anonymous: anonymous,
                                 authenticated: authenticated)
        store.setSession(.authed)
        await store.run(testQuery())
        XCTAssertEqual(store.desktop.state, .idle)
        XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertEqual(store.listings.count, 2)
        let authCursors = await authenticated.cursors
        XCTAssertEqual(authCursors, [nil, "auth-A"])
        let guestBeforeSignOut = await anonymous.cursors
        XCTAssertTrue(guestBeforeSignOut.isEmpty)

        store.setSession(.unauthed)
        await store.run(testQuery())
        let guestCursors = await anonymous.cursors
        XCTAssertEqual(guestCursors, [nil])
        XCTAssertEqual(store.listings.map(\.title), ["303"])
    }

    func testSignedInBlockDoesNotRetryAnonymouslyOrThroughBrowser() async {
        let anonymous = StubFeed([])
        let authenticated = StubFeed([.failure(.blocked)])
        let store = ListingStore(prefs: makePreferences(), cache: makeCache(), anonymous: anonymous,
                                 authenticated: authenticated)
        store.setSession(.authed)
        await store.run(testQuery())
        XCTAssertEqual(store.desktop.state, .idle)
        XCTAssertNotNil(store.paginationError)
        let guestCursors = await anonymous.cursors
        XCTAssertTrue(guestCursors.isEmpty)
    }

    func testSignOutDiscardsAuthenticatedRequestCompletion() async {
        let authenticated = SuspendedFeed()
        let anonymous = StubFeed([.success(testPage(["303"], cursor: nil))])
        let store = ListingStore(prefs: makePreferences(), cache: makeCache(), anonymous: anonymous,
                                 authenticated: authenticated)
        store.setSession(.authed)
        let old = Task { await store.run(testQuery("old")) }
        await authenticated.waitUntilRequested()
        store.setSession(.unauthed)
        await store.run(testQuery("new"))
        await authenticated.finishOld()
        await old.value
        XCTAssertEqual(store.listings.map(\.title), ["303"])
        XCTAssertEqual(store.query?.displayName, "new")
        XCTAssertTrue(store.reachedEnd)
    }

    func testSignedInDiscoverUsesAuthenticatedGraphQL() async {
        let prefs = makePreferences()
        prefs.radiusKM = 0
        prefs.setResolvedPlace(.init(name: "New York", segment: "nyc",
                                     coordinate: testQuery().coordinate!, origin: .searchedCity))
        let authenticated = StubFeed([.success(testPage((100..<112).map(String.init), cursor: "auth-A")),
                                      .success(testPage(["202"], cursor: nil))])
        let anonymous = StubFeed([])
        let discover = DiscoverFeed(prefs: prefs, anonymous: anonymous, authenticated: authenticated,
                                     currentSession: { .authed })
        await discover.loadIfNeeded(citySlug: "nyc")
        XCTAssertFalse(discover.isAnonymous)
        XCTAssertFalse(discover.usesBrowserFallback)
        await discover.retryLoadingMore()
        XCTAssertEqual(discover.listings.count, 13)
        XCTAssertTrue(discover.reachedEnd)
        let authCursors = await authenticated.cursors
        XCTAssertEqual(authCursors, [nil, "auth-A"])
        let guestCursors = await anonymous.cursors
        XCTAssertTrue(guestCursors.isEmpty)
    }

    func testCachedCardVisibilitySurvivesLiveReplacement() async {
        let query = testQuery()
        let cache = makeCache()
        let cached = testPayload("101").makeListing(cardIndex: 0)
        cache.saveResults([cached], for: query, session: .unauthed)
        let client = CachedRefreshFeed()
        let store = ListingStore(prefs: makePreferences(), cache: cache, anonymous: client)
        let initial = Task { await store.run(query) }
        await client.waitUntilRequested()
        await store.loadMoreIfNeeded(currentItem: cached, hiddenAsViewed: [])
        await client.finishRefresh()
        await initial.value
        let initialRequests = await client.requests
        XCTAssertEqual(initialRequests, 1, "Appearance alone must not drain the feed")

        // SwiftUI retains this cell's identity, so no second appearance arrives.
        store.noteScroll(hiddenAsViewed: [])
        await waitForCards(2, in: store)
        XCTAssertEqual(store.listings.count, 2)
        XCTAssertTrue(store.reachedEnd)
    }

    func testDragDuringCachedRefreshIsHonoredAfterRefresh() async {
        let query = testQuery()
        let cache = makeCache()
        let cached = testPayload("101").makeListing(cardIndex: 0)
        cache.saveResults([cached], for: query, session: .unauthed)
        let client = CachedRefreshFeed()
        let store = ListingStore(prefs: makePreferences(), cache: cache, anonymous: client)
        let initial = Task { await store.run(query) }
        await client.waitUntilRequested()
        await store.loadMoreIfNeeded(currentItem: cached, hiddenAsViewed: [])
        store.noteScroll(hiddenAsViewed: [])
        await Task.yield()
        await client.finishRefresh()
        await initial.value
        await waitForCards(2, in: store)
        XCTAssertEqual(store.listings.count, 2)
        XCTAssertFalse(store.isLoadingMore)
    }

    func testCardCallbackUsesIdentityAfterItsContentsChange() async {
        let client = StubFeed([.success(testPage(["101"], cursor: "A")),
                               .success(testPage(["202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        var oldCard = store.listings[0]
        oldCard.capturedAt = .distantPast
        await store.loadMoreIfNeeded(currentItem: oldCard, hiddenAsViewed: [])
        store.noteScroll(hiddenAsViewed: [])
        await waitForCards(2, in: store)
        XCTAssertEqual(store.listings.count, 2)
    }

    private func waitForCards(_ count: Int, in store: ListingStore) async {
        for _ in 0..<100 {
            if store.listings.count >= count && !store.isLoadingMore { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testGuestSearchCanPageAndDoesNotRequireSignIn() async {
        let client = StubFeed([.success(testPage(["101"], cursor: "A")),
                               .success(testPage(["101", "202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        XCTAssertTrue(store.canLoadMore)
        XCTAssertFalse(store.requiresFacebookForMore)
        await store.loadMore()
        XCTAssertEqual(store.listings.compactMap(\.itemURL).map(\.lastPathComponent), ["101", "202"])
        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.canLoadMore)
        XCTAssertFalse(store.isLoadingMore)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testInitialSearchFollowsEmptyAdvancingPagesAutomatically() async {
        let client = StubFeed([.success(testPage([], cursor: "A")),
                               .success(testPage([], cursor: "B")),
                               .success(testPage(["202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        XCTAssertEqual(store.listings.count, 1)
        XCTAssertTrue(store.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B"])
        XCTAssertFalse(store.isLoadingFirstPage)
    }

    func testEmptySearchStopsAtConfirmedEnd() async {
        let client = StubFeed([.success(testPage([], cursor: "A")),
                               .success(testPage([], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.canLoadMore)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testInitialEmptyRecoveryIsBoundedAndCanResume() async {
        let client = StubFeed([.success(testPage([], cursor: "A")),
                               .success(testPage([], cursor: "B")),
                               .success(testPage([], cursor: "C")),
                               .success(testPage(["202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        let initialCursors = await client.cursors
        XCTAssertEqual(initialCursors, [nil, "A", "B"])
        XCTAssertTrue(store.canLoadMore)
        XCTAssertFalse(store.isLoadingFirstPage)
        await store.loadMore()
        XCTAssertEqual(store.listings.count, 1)
        XCTAssertTrue(store.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B", "C"])
    }

    func testInitialEmptyRecoveryStopsOnBlockAndPreservesCursor() async {
        let client = StubFeed([.success(testPage([], cursor: "A")), .failure(.blocked),
                               .success(testPage(["202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        XCTAssertNotNil(store.paginationError)
        XCTAssertEqual(store.desktop.state, .idle)
        XCTAssertTrue(store.canLoadMore)
        await store.retryLoadingMore()
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "A"])
        XCTAssertEqual(store.listings.count, 1)
        XCTAssertNil(store.paginationError)
    }

    func testRateLimitKeepsCardsAndCursorWithoutBrowserRetry() async {
        let client = StubFeed([.success(testPage(["101"], cursor: "A")), .failure(.blocked),
                               .success(testPage(["202"], cursor: nil))])
        let store = makeStore(client)
        await store.run(testQuery())
        await store.loadMore()
        XCTAssertEqual(store.listings.count, 1)
        XCTAssertFalse(store.reachedEnd)
        XCTAssertNotNil(store.paginationError)
        XCTAssertEqual(store.desktop.state, .idle)
        await store.retryLoadingMore()
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "A"])
        XCTAssertEqual(store.listings.count, 2)
    }

    func testNewSearchDiscardsOldCompletion() async {
        let client = SuspendedFeed()
        let store = makeStore(client)
        let first = Task { await store.run(testQuery("old")) }
        await client.waitUntilRequested()
        await store.run(testQuery("new"))
        await client.finishOld()
        await first.value
        XCTAssertEqual(store.listings.first?.title, "202")
        XCTAssertEqual(store.query?.displayName, "new")
        XCTAssertFalse(store.isLoadingFirstPage)
    }

    func testSessionChangeDiscardsAnonymousCompletion() async {
        let client = SuspendedFeed()
        let store = makeStore(client)
        let first = Task { await store.run(testQuery("old")) }
        await client.waitUntilRequested()
        store.setSession(.authed)
        await client.finishOld()
        await first.value
        XCTAssertTrue(store.listings.isEmpty)
        XCTAssertEqual(store.session, .authed)
    }

    func testCoordinateChangesInvalidateCachedSearch() {
        let cache = makeCache()
        let query = testQuery()
        cache.saveResults([testPayload("101").makeListing(cardIndex: 0)], for: query, session: .unauthed)
        XCTAssertNotNil(cache.results(for: query, session: .unauthed))
        var moved = query
        moved.coordinate = CLLocationCoordinate2D(latitude: 40.807, longitude: -73.962)
        XCTAssertNil(cache.results(for: moved, session: .unauthed))
        XCTAssertNil(cache.results(for: query, session: .authed))
    }

    func testGuestDiscoverPagesAndRetainsSignedOutIdentity() async {
        let prefs = makePreferences()
        prefs.radiusKM = 0
        prefs.setResolvedPlace(.init(name: "New York", segment: "nyc",
                                     coordinate: testQuery().coordinate!, origin: .searchedCity))
        let first = (100..<112).map(String.init)
        let client = StubFeed([.success(testPage(first, cursor: "A")),
                               .success(testPage(["202"], cursor: nil))])
        let discover = DiscoverFeed(prefs: prefs, anonymous: client, currentSession: { .unauthed })
        await discover.loadIfNeeded(citySlug: "nyc")
        XCTAssertTrue(discover.isAnonymous)
        XCTAssertFalse(discover.reachedEnd)
        XCTAssertFalse(discover.usesBrowserFallback)
        await discover.retryLoadingMore()
        XCTAssertEqual(discover.listings.count, 13)
        XCTAssertTrue(discover.reachedEnd)
        XCTAssertFalse(discover.isLoadingMore)
    }

    func testInvalidQueryResponseUsesBrowserFallback() async {
        let browserPacer = RequestPacer()
        await browserPacer.recordBlock()
        let desktop = DesktopFeedEngine(pacer: browserPacer)
        let client = StubFeed([.failure(.invalidResponse)])
        let store = ListingStore(desktop: desktop, prefs: makePreferences(), cache: makeCache(), anonymous: client)
        await store.run(testQuery())
        XCTAssertFalse(store.requiresFacebookForMore)
        XCTAssertNotNil(store.paginationError)
        if case .failed = desktop.state {} else { XCTFail("Expected the browser fallback to claim its request slot") }
        XCTAssertFalse(store.isLoadingFirstPage)
    }

    func testDiscoverRefreshDiscardsOldPage() async {
        let prefs = makePreferences()
        prefs.radiusKM = 0
        prefs.setResolvedPlace(.init(name: "New York", segment: "nyc",
                                     coordinate: testQuery().coordinate!, origin: .searchedCity))
        let client = SuspendedFeed()
        let discover = DiscoverFeed(prefs: prefs, anonymous: client, currentSession: { .unauthed })
        let first = Task { await discover.loadIfNeeded(citySlug: "nyc") }
        await client.waitUntilRequested()
        await discover.loadIfNeeded(citySlug: "nyc", force: true)
        await client.finishOld()
        await first.value
        XCTAssertEqual(discover.listings.map(\.title), ["202"])
        XCTAssertTrue(discover.reachedEnd)
        XCTAssertFalse(discover.isLoading)
    }

    private func makeStore(_ client: any GraphQLFeedLoading) -> ListingStore {
        ListingStore(prefs: makePreferences(), cache: makeCache(), anonymous: client)
    }

    private func makeCache() -> ListingCache {
        ListingCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                     isSaved: { _ in false })
    }

    private func makePreferences() -> Preferences {
        Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }
}

private actor StubFeed: GraphQLFeedLoading {
    var responses: [Result<GraphQLFeedPage, GraphQLFeedError>]
    private(set) var cursors: [String?] = []
    init(_ responses: [Result<GraphQLFeedPage, GraphQLFeedError>]) { self.responses = responses }
    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        cursors.append(cursor)
        guard !responses.isEmpty else { throw GraphQLFeedError.invalidResponse }
        return try responses.removeFirst().get()
    }
}

private actor CachedRefreshFeed: GraphQLFeedLoading {
    private(set) var requests = 0
    private var pending: CheckedContinuation<GraphQLFeedPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        requests += 1
        if requests == 1 {
            return await withCheckedContinuation {
                pending = $0
                waiter?.resume()
                waiter = nil
            }
        }
        return testPage(["202"], cursor: nil)
    }

    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finishRefresh() {
        pending?.resume(returning: testPage(["101"], cursor: "A"))
        pending = nil
    }
}

private actor SuspendedFeed: GraphQLFeedLoading {
    var requests = 0
    var pending: CheckedContinuation<GraphQLFeedPage, Never>?
    var waiter: CheckedContinuation<Void, Never>?
    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        requests += 1
        if query.displayName == "old" || (query.kind == .browse && requests == 1) {
            return await withCheckedContinuation {
                pending = $0
                waiter?.resume()
                waiter = nil
            }
        }
        return testPage(["202"], cursor: nil)
    }
    func waitUntilRequested() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishOld() { pending?.resume(returning: testPage(["101"], cursor: "old")); pending = nil }
}

private func testQuery(_ term: String = "desk") -> SearchQuery {
    SearchQuery(kind: .search(term), radiusKM: 65, citySlug: "nyc",
                coordinate: CLLocationCoordinate2D(latitude: 40.706, longitude: -74.009))
}

private func testPayload(_ id: String) -> PayloadListing {
    PayloadListing(id: id, title: id, creationTime: nil, priceAmount: "20", priceFormatted: "$20",
                   strikethroughFormatted: nil, photoURL: nil, photoID: nil, city: nil, state: nil,
                   cityPageID: nil, deliveryTypes: [], isSold: nil, isLive: nil, categoryID: nil,
                   createdWithSellerApp: nil)
}

private func testPage(_ ids: [String], cursor: String?) -> GraphQLFeedPage {
    GraphQLFeedPage(listings: ids.map(testPayload), endCursor: cursor, hasNextPage: cursor != nil)
}

final class AnonymousFeedHTTPTests: XCTestCase {
    func testHTTPRateLimitStopsFurtherNetworkRequests() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedURLProtocol.self]
        FeedURLProtocol.configure { request in (429, [:], Data()) }
        let client = AnonymousFeedClient(pacer: RequestPacer(), configuration: config)
        do { _ = try await client.page(for: testQuery(), cursor: nil); XCTFail("Expected block") }
        catch { XCTAssertEqual(error as? GraphQLFeedError, .blocked) }
        do { _ = try await client.page(for: testQuery(), cursor: nil); XCTFail("Expected backoff") }
        catch { XCTAssertEqual(error as? GraphQLFeedError, .paused) }
        XCTAssertEqual(FeedURLProtocol.requestCount, 1)
    }

    func testSetCookieDoesNotBecomeCredentialsOnNextPage() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FeedURLProtocol.self]
        FeedURLProtocol.configure { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            let raw = Data(#"{"data":{"marketplace_search":{"feed_units":{"edges":[],"page_info":{"has_next_page":true,"end_cursor":"next"}}}}}"#.utf8)
            return (200, ["Set-Cookie": "datr=test; Domain=.facebook.com; Path=/"], raw)
        }
        let client = AnonymousFeedClient(pacer: RequestPacer(), configuration: config)
        _ = try await client.page(for: testQuery(), cursor: nil)
        _ = try await client.page(for: testQuery(), cursor: "next")
        XCTAssertEqual(FeedURLProtocol.requestCount, 2)
    }
}

private final class FeedURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (Int, [String: String], Data)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var count = 0
    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    static func configure(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        count = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler!
        Self.count += 1
        Self.lock.unlock()
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
