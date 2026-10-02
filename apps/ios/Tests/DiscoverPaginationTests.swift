import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class DiscoverPaginationTests: XCTestCase {
    func testDiscoverStaysLocalWithDisabledWideDefaultAndTighterSearchRadii() async {
        let cases: [(Int?, Int, [String])] = [
            (0, 32, ["near", "mid"]),
            (161, 32, ["near", "mid"]),
            (nil, 16, ["near"]),
            (8, 8, ["near"])
        ]
        for (selected, expectedRadius, expectedTitles) in cases {
            let client = DiscoverStub([
                .success(page([card("near"), card("mid", city: "Mid"), card("regional", city: "Regional")], cursor: "A")),
                .success(page([card("distant-next", city: "Regional")], cursor: nil))
            ])
            let discover = makeDiscover(client, radiusKM: selected)
            await discover.loadIfNeeded(citySlug: "sanfrancisco")

            XCTAssertEqual(discover.radiusKM, expectedRadius)
            XCTAssertEqual(discover.listings.map(\.title), expectedTitles)
            XCTAssertTrue(discover.caption.contains("within \(SearchQuery.kilometresToMiles(expectedRadius)) mi"))
            let queries = await client.queries
            XCTAssertEqual(queries.map(\.radiusKM), [expectedRadius, expectedRadius])
            XCTAssertTrue(discover.reachedEnd)
        }
    }

    func testAutomaticTopUpContinuesThroughEmptyShippingDistantAndDuplicatePages() async {
        let initial = page((0..<12).map { card("initial-\($0)") }, cursor: "A")
        let client = DiscoverStub([
            .success(initial),
            .success(page([], cursor: "B")),
            .success(page([card("shipping", shipping: true)], cursor: "C")),
            .success(page([card("distant", city: "Far")], cursor: "D")),
            .success(page(initial.listings, cursor: "E")),
            .success(page([card("one")], cursor: "F")),
            .success(page((0..<11).map { card("next-\($0)") }, cursor: "G"))
        ])
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        await discover.loadMore()

        XCTAssertEqual(discover.listings.count, 24)
        XCTAssertNil(discover.loadError)
        XCTAssertFalse(discover.paginationPaused)
        XCTAssertFalse(discover.reachedEnd)
        XCTAssertFalse(discover.isLoadingMore)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B", "C", "D", "E", "F"])
    }

    func testSparseInitialFillContinuesWithoutAnyScroll() async {
        let client = DiscoverStub([
            .success(page([], cursor: "A")),
            .success(page([card("far", city: "Far")], cursor: "B")),
            .success(page([], cursor: "C")),
            .success(page([card("shipping", shipping: true)], cursor: "D")),
            .success(page((0..<12).map { card("near-\($0)") }, cursor: "E"))
        ])
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")

        XCTAssertEqual(discover.listings.count, 12)
        XCTAssertFalse(discover.paginationPaused)
        XCTAssertNil(discover.loadError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors.count, 5)
    }

    func testBudgetPauseRetainsPartialCardsAndResumesOnScroll() async {
        var responses: [Result<GraphQLFeedPage, GraphQLFeedError>] = [
            .success(page((0..<12).map { card("initial-\($0)") }, cursor: "A"))
        ]
        for index in 1...DiscoverFeed.graphQLPageBudget {
            responses.append(.success(page(index == 1 ? [card("partial")] : [], cursor: "P\(index)")))
        }
        responses.append(.success(page([card("last")], cursor: nil)))
        let client = DiscoverStub(responses)
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        await discover.loadMore()

        XCTAssertEqual(discover.listings.count, 13)
        XCTAssertTrue(discover.paginationPaused)
        XCTAssertFalse(discover.reachedEnd)
        XCTAssertNil(discover.loadError)
        await discover.loadMore()
        await discover.loadMoreIfNeeded(currentItem: discover.listings.last!)
        let pausedCursors = await client.cursors
        XCTAssertEqual(pausedCursors.count, 1 + DiscoverFeed.graphQLPageBudget)

        discover.noteScroll()
        await discover.loadMoreIfNeeded(currentItem: discover.listings.last!)
        XCTAssertEqual(discover.listings.count, 14)
        XCTAssertFalse(discover.paginationPaused)
        XCTAssertTrue(discover.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors.last!, "P\(DiscoverFeed.graphQLPageBudget)")
    }

    func testTimeBudgetStopsBeforeStartingAnotherPage() async {
        let client = DiscoverStub([
            .success(page((0..<12).map { card("initial-\($0)") }, cursor: "A")),
            .success(page([card("partial")], cursor: "B")),
            .success(page([card("later")], cursor: nil))
        ])
        let discover = makeDiscover(client, timeBudget: .zero)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        await discover.loadMore()

        XCTAssertTrue(discover.paginationPaused)
        XCTAssertEqual(discover.listings.count, 13)
        XCTAssertNil(discover.loadError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testEmptyBudgetIsRetryableRatherThanAnErrorOrEnd() async {
        let client = DiscoverStub((0...DiscoverFeed.graphQLPageBudget).map {
            .success(page([], cursor: "P\($0)"))
        })
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")

        XCTAssertTrue(discover.listings.isEmpty)
        XCTAssertTrue(discover.paginationPaused)
        XCTAssertFalse(discover.reachedEnd)
        XCTAssertNil(discover.loadError)
        await discover.loadMore()
        let cursors = await client.cursors
        XCTAssertEqual(cursors.count, 1 + DiscoverFeed.graphQLPageBudget)
    }

    func testServerEndStopsEvenWhenEveryCardIsFiltered() async {
        let client = DiscoverStub([
            .success(page([], cursor: "A")),
            .success(page([card("far", city: "Far")], cursor: nil))
        ])
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        await discover.loadMore()
        await discover.retryLoadingMore()

        XCTAssertTrue(discover.reachedEnd)
        XCTAssertFalse(discover.paginationPaused)
        XCTAssertNil(discover.loadError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testRequestErrorNeedsExplicitRetryAndPreservesCursor() async {
        let client = DiscoverStub([
            .success(page((0..<12).map { card("initial-\($0)") }, cursor: "A")),
            .failure(.blocked),
            .success(page([card("after-retry")], cursor: nil))
        ])
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        await discover.loadMore()
        XCTAssertNotNil(discover.loadError)
        XCTAssertFalse(discover.paginationPaused)
        await discover.loadMore()
        let beforeRetry = await client.cursors
        XCTAssertEqual(beforeRetry, [nil, "A"])

        await discover.retryLoadingMore()
        XCTAssertNil(discover.loadError)
        XCTAssertTrue(discover.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "A"])
    }

    func testRefreshResetsPauseAndStartsWithoutOldCursor() async {
        let client = DiscoverStub([
            .success(page([], cursor: "A")),
            .success(page([], cursor: "B")),
            .success(page([card("replacement")], cursor: nil))
        ])
        let discover = makeDiscover(client, timeBudget: .zero)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertTrue(discover.paginationPaused)
        await discover.loadIfNeeded(citySlug: "sanfrancisco", force: true)

        XCTAssertFalse(discover.paginationPaused)
        XCTAssertEqual(discover.listings.map(\.title), ["replacement"])
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", nil])
    }

    func testRefreshDiscardsSuspendedTopUpAndConcurrentDemandDoesNotDuplicateIt() async {
        let client = DiscoverSuspendedStub(initial: page((0..<12).map { card("initial-\($0)") }, cursor: "A"),
                                           replacement: page([card("replacement")], cursor: nil))
        let discover = makeDiscover(client)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        let topUp = Task { await discover.loadMore() }
        await client.waitUntilSuspended()
        await discover.loadMore()
        await discover.retryLoadingMore()
        let beforeRefresh = await client.cursors
        XCTAssertEqual(beforeRefresh, [nil, "A"])
        await discover.loadIfNeeded(citySlug: "sanfrancisco", force: true)
        await client.finish(page([card("stale")], cursor: "B"))
        await topUp.value

        XCTAssertEqual(discover.listings.map(\.title), ["replacement"])
        XCTAssertTrue(discover.reachedEnd)
        XCTAssertFalse(discover.paginationPaused)
        XCTAssertFalse(discover.isLoadingMore)
    }

    private func makeDiscover(_ client: any GraphQLFeedLoading,
                              timeBudget: Duration = .seconds(8),
                              radiusKM: Int? = 8) -> DiscoverFeed {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["Near, CA": [37.7793, -122.419], "Far, CA": [34.05, -118.24],
                      "Mid, CA": [37.995, -122.419], "Regional, CA": [38.23, -122.419]], forKey: "placeCoordinates")
        let prefs = Preferences(defaults: defaults)
        let point = CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.419)
        prefs.setResolvedPlace(.init(name: "San Francisco", segment: "sanfrancisco",
                                     coordinate: point, origin: .searchedCity))
        if let radiusKM { prefs.radiusKM = radiusKM }
        let distances = DistanceResolver(defaults: defaults)
        distances.setUserLocation(point)
        return DiscoverFeed(prefs: prefs, distances: distances, anonymous: client,
                            paginationTimeBudget: timeBudget, currentSession: { .unauthed })
    }

    private func card(_ id: String, city: String = "Near", shipping: Bool = false) -> PayloadListing {
        PayloadListing(id: id, title: id, creationTime: nil, priceAmount: "20", priceFormatted: "$20",
                       strikethroughFormatted: nil, photoURL: nil, photoID: nil, city: city, state: "CA",
                       cityPageID: nil, deliveryTypes: shipping ? ["SHIPPING_ONSITE"] : ["IN_PERSON"],
                       isSold: nil, isLive: nil, categoryID: nil, createdWithSellerApp: nil)
    }

    private func page(_ cards: [PayloadListing], cursor: String?) -> GraphQLFeedPage {
        .init(listings: cards, endCursor: cursor, hasNextPage: cursor != nil)
    }
}

private actor DiscoverStub: GraphQLFeedLoading {
    var responses: [Result<GraphQLFeedPage, GraphQLFeedError>]
    private(set) var cursors: [String?] = []
    private(set) var queries: [SearchQuery] = []

    init(_ responses: [Result<GraphQLFeedPage, GraphQLFeedError>]) { self.responses = responses }

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        cursors.append(cursor)
        queries.append(query)
        guard !responses.isEmpty else { throw GraphQLFeedError.blocked }
        return try responses.removeFirst().get()
    }
}

private actor DiscoverSuspendedStub: GraphQLFeedLoading {
    let initial: GraphQLFeedPage
    let replacement: GraphQLFeedPage
    private(set) var cursors: [String?] = []
    private var pending: CheckedContinuation<GraphQLFeedPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?

    init(initial: GraphQLFeedPage, replacement: GraphQLFeedPage) {
        self.initial = initial
        self.replacement = replacement
    }

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        cursors.append(cursor)
        if cursors.count == 1 { return initial }
        if cursors.count == 2 {
            return await withCheckedContinuation {
                pending = $0
                waiter?.resume()
                waiter = nil
            }
        }
        return replacement
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ page: GraphQLFeedPage) {
        pending?.resume(returning: page)
        pending = nil
    }
}
