import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class DiscoverPaginationTests: XCTestCase {

    func testCachedListingPointsOverrideCityCentersAcrossPages() async throws {
        let cache = makeCache()
        var nearby = card("nearby", city: "Far").makeListing(cardIndex: 0)
        nearby.detail = ListingDetail(latitude: 37.7793, longitude: -122.419)
        nearby.detailObservedAt = Date(timeIntervalSince1970: 123)
        cache.store(nearby)
        var distant = card("distant").makeListing(cardIndex: 1)
        distant.detail = ListingDetail(latitude: 34.05, longitude: -118.24)
        cache.store(distant)

        let client = DiscoverStub([
            .success(page([card("distant"), card("uncached-far", city: "Far")], cursor: "A")),
            .success(page([card("nearby", city: "Far"), card("uncached-near")], cursor: nil))
        ])
        let discover = makeDiscover(client, cache: cache)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")

        XCTAssertEqual(discover.listings.compactMap(\.title), ["nearby", "uncached-near"])
        let restored = try XCTUnwrap(discover.listings.first)
        XCTAssertEqual(restored.detail?.latitude, nearby.detail?.latitude)
        XCTAssertEqual(restored.detailObservedAt, nearby.detailObservedAt)
        XCTAssertEqual(restored.cardIndex, 0)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testRefreshUsesNewlyCachedPointsAndTheySurviveRelaunch() async {
        let cache = makeCache()
        let response = page([card("123456789")], cursor: nil)
        let client = DiscoverStub([.success(response), .success(response)])
        let discover = makeDiscover(client, cache: cache)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertEqual(discover.listings.count, 1)

        let detail = DetailEngine(graphQL: DiscoverLocationDetailStub(), actorProvider: { nil })
        let store = ListingStore(detail: detail, cache: cache)
        let opened = await store.enrich(discover.listings[0])
        let distances = DistanceResolver(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        distances.setUserLocation(.init(latitude: 37.7793, longitude: -122.419))
        XCTAssertEqual(discover.listings.first?.detail?.latitude, 34.05)
        XCTAssertNotNil(distances.bestDistanceText(for: discover.listings[0]))
        let visible = ListingWinnower.apply(to: discover.listings, hiddenAsViewed: [], hidingViewed: false,
                                            radiusKM: 8, distances: distances,
                                            distanceSnapshot: discover.distanceSnapshot)
        XCTAssertEqual(visible.items.map(\.id), [opened.id])
        XCTAssertEqual(visible.hiddenByDistance, 0)
        let beforeRefresh = await client.cursors
        XCTAssertEqual(beforeRefresh, [nil], "Updating details must not fetch the feed again")
        await discover.loadIfNeeded(citySlug: "sanfrancisco", force: true)
        XCTAssertTrue(discover.listings.isEmpty)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persisted = ListingCache(directory: directory, isSaved: { _ in false })
        persisted.store(opened)
        await persisted.writeToDisk()
        let restored = ListingCache(directory: directory, isSaved: { _ in false })
        let relaunched = makeDiscover(DiscoverStub([.success(response)]), cache: restored)
        await relaunched.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertTrue(relaunched.listings.isEmpty)
    }

    func testUnknownDistancesStayVisibleAndInvalidPointsUseCityFallback() async {
        let cache = makeCache()
        for (id, city) in [("invalid-near", "Near"), ("invalid-far", "Far")] {
            var listing = card(id, city: city).makeListing(cardIndex: 0)
            listing.detail = ListingDetail(latitude: 91, longitude: 0)
            cache.store(listing)
        }
        let unknown = card("unknown", city: nil)
        let response = page([unknown, card("invalid-near"), card("invalid-far", city: "Far")], cursor: nil)
        let discover = makeDiscover(DiscoverStub([.success(response)]), cache: cache)
        await discover.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertEqual(discover.listings.compactMap(\.title), ["unknown", "invalid-near"])
    }

    func testOnlyOptedInFeedUpdatesFilterTotals() async {
        let suite = "DiscoverPaginationTests.totals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let totals = FilterTotals(defaults: defaults)
        var response = page([card("near"), card("far", city: "Far")], cursor: nil)
        response.filteredAdCount = 3
        let sharedAds = FilterTotals.shared.ads
        let sharedNonLocal = FilterTotals.shared.nonLocalListings
        var feed = makeDiscover(DiscoverStub([.success(response)]))
        await feed.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertEqual(FilterTotals.shared.ads, sharedAds)
        XCTAssertEqual(FilterTotals.shared.nonLocalListings, sharedNonLocal)
        XCTAssertEqual(totals.ads, 0)
        feed = makeDiscover(DiscoverStub([.success(response)]), filterTotals: totals)
        await feed.loadIfNeeded(citySlug: "sanfrancisco")
        XCTAssertEqual(totals.ads, 3)
        XCTAssertEqual(totals.nonLocalListings, 1)
    }
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

    private func makeDiscover(_ client: any GraphQLFeedLoading, filterTotals: FilterTotals? = nil,
                              timeBudget: Duration = .seconds(8),
                              radiusKM: Int? = 8, cache: ListingCache? = nil) -> DiscoverFeed {
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
        return DiscoverFeed(prefs: prefs, filterTotals: filterTotals, distances: distances,
                            cache: cache ?? makeCache(), anonymous: client,
                            paginationTimeBudget: timeBudget, currentSession: { .unauthed })
    }

    private func makeCache() -> ListingCache {
        ListingCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
                     isSaved: { _ in false })
    }

    private func card(_ id: String, city: String? = "Near", shipping: Bool = false) -> PayloadListing {
        PayloadListing(id: id, title: id, creationTime: nil, priceAmount: "20", priceFormatted: "$20",
                       strikethroughFormatted: nil, photoURL: nil, photoID: nil, city: city, state: city == nil ? nil : "CA",
                       cityPageID: nil, deliveryTypes: shipping ? ["SHIPPING_ONSITE"] : ["IN_PERSON"],
                       isSold: nil, isLive: nil, categoryID: nil, createdWithSellerApp: nil)
    }

    private func page(_ cards: [PayloadListing], cursor: String?) -> GraphQLFeedPage {
        .init(listings: cards, endCursor: cursor, hasNextPage: cursor != nil)
    }
}

@MainActor
private final class DiscoverLocationDetailStub: GraphQLDetailLoading {
    func load(itemID: String, actor: String?,
              onPartial: @escaping @MainActor (ListingDetail) -> Void) async throws -> ListingDetail {
        let detail = ListingDetail(latitude: 34.05, longitude: -118.24)
        onPartial(detail)
        return detail
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
