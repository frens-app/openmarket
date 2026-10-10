import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class SearchPaginationTests: XCTestCase {

    func testOnlyOptedInFeedUpdatesFilterTotals() async {
        let suite = "SearchPaginationTests.totals.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let totals = FilterTotals(defaults: defaults)
        var response = page([card("near")], cursor: nil)
        response.filteredAdCount = 3
        let sharedAds = FilterTotals.shared.ads
        let sharedNonLocal = FilterTotals.shared.nonLocalListings
        var feed = makeStore(SearchStub([.success(response)]))
        await feed.run(query())
        XCTAssertEqual(FilterTotals.shared.ads, sharedAds)
        XCTAssertEqual(FilterTotals.shared.nonLocalListings, sharedNonLocal)
        XCTAssertEqual(totals.ads, 0)
        feed = makeStore(SearchStub([.success(response)]), filterTotals: totals)
        await feed.run(query())
        XCTAssertEqual(totals.ads, 3)
    }
    func testTopUpCountsVisibleCardsAcrossEmptyDistantViewedAndDuplicatePages() async {
        let client = SearchStub([
            .success(page([card("base")], cursor: "A")),
            .success(page([], cursor: "B")),
            .success(page([card("far", city: "Far")], cursor: "C")),
            .success(page([card("viewed")], cursor: "D")),
            .success(page([card("base")], cursor: "E")),
            .success(page([card("one")], cursor: "F")),
            .success(page((0..<5).map { card("next-\($0)") }, cursor: "G"))
        ])
        let store = makeStore(client)
        await store.run(query(), hiddenAsViewed: ["fb:viewed"])
        await store.loadMore()

        XCTAssertEqual(store.listings.count, 9, "Six visible additions plus two filtered cards must be stored")
        XCTAssertEqual(Set(store.listings.compactMap(\.title)), Set(["base", "far", "viewed", "one"] + (0..<5).map { "next-\($0)" }))
        XCTAssertFalse(store.paginationPaused)
        XCTAssertNil(store.paginationError)
        XCTAssertFalse(store.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B", "C", "D", "E", "F"])
    }

    func testBudgetPauseFlushesOddRowAndScrollContinuesFromItsCursor() async {
        var responses: [Result<GraphQLFeedPage, GraphQLFeedError>] = [.success(page([card("base")], cursor: "A"))]
        for index in 1...ListingStore.graphQLPageBudget {
            responses.append(.success(page(index == 1 ? (0..<3).map { card("partial-\($0)") } : [], cursor: "P\(index)")))
        }
        responses.append(.success(page([card("last")], cursor: nil)))
        let client = SearchStub(responses)
        let store = makeStore(client)
        await store.run(query())
        await store.loadMore()

        XCTAssertEqual(store.listings.count, 4)
        XCTAssertTrue(store.paginationPaused)
        XCTAssertNil(store.paginationError)
        XCTAssertFalse(store.reachedEnd)
        XCTAssertEqual(store.loadingPlaceholderCount, 0)
        await store.loadMore()
        await store.loadMoreIfNeeded(currentItem: store.listings.last!, hiddenAsViewed: [])
        let paused = await client.cursors
        XCTAssertEqual(paused.count, 1 + ListingStore.graphQLPageBudget)
        store.noteScroll(hiddenAsViewed: [])
        await store.loadMoreIfNeeded(currentItem: store.listings.last!, hiddenAsViewed: [])

        XCTAssertEqual(store.listings.count, 5)
        XCTAssertFalse(store.paginationPaused)
        XCTAssertTrue(store.reachedEnd)
        let cursors = await client.cursors
        XCTAssertEqual(cursors.last!, "P\(ListingStore.graphQLPageBudget)")
    }

    func testTimeBudgetStopsBeforeAnotherPageAndRetainsSparseResult() async {
        let client = SearchStub([
            .success(page([card("base")], cursor: "A")),
            .success(page([card("one")], cursor: "B")),
            .success(page([card("later")], cursor: nil))
        ])
        let store = makeStore(client, timeBudget: .zero)
        await store.run(query())
        await store.loadMore()

        XCTAssertEqual(store.listings.count, 2)
        XCTAssertTrue(store.paginationPaused)
        XCTAssertNil(store.paginationError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testInitialLoadFollowsFilteredPagesUsingOnlyNewSnapshot() async {
        let client = SearchStub([
            .success(page([card("viewed")], cursor: "A")),
            .success(page([card("far", city: "Far")], cursor: "B")),
            .success(page([], cursor: "C")),
            .success(page([card("match")], cursor: nil))
        ])
        let store = makeStore(client)
        await store.run(query(), hiddenAsViewed: ["fb:viewed"])

        XCTAssertEqual(store.listings.compactMap(\.title), ["viewed", "far", "match"])
        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.paginationPaused)
        XCTAssertNil(store.paginationError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B", "C"])
    }

    func testInitialFilteredGridResumesOnDragWithoutVisibleCardCallbacks() async {
        let client = SearchStub([
            .success(page([card("far", city: "Far")], cursor: "A")),
            .success(page([card("match")], cursor: nil))
        ])
        let store = makeStore(client, timeBudget: .zero)
        await store.run(query())
        XCTAssertTrue(store.paginationPaused)
        await store.loadMore()
        let before = await client.cursors
        XCTAssertEqual(before, [nil])
        store.noteScroll(hiddenAsViewed: [])
        await waitUntilIdle(store, count: 2)

        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.paginationPaused)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A"])
    }

    func testChangingOnlyNewUpdatesTopUpTargetWithoutAnotherCardAppearance() async {
        let client = SearchStub([
            .success(page([card("base")], cursor: "A")),
            .success(page((0..<6).map { card("viewed-\($0)") }, cursor: "B")),
            .success(page((0..<6).map { card("new-\($0)") }, cursor: "C"))
        ])
        let store = makeStore(client)
        await store.run(query())
        store.updateHiddenAsViewed(Set((0..<6).map { "fb:viewed-\($0)" }))
        await store.loadMore()

        XCTAssertEqual(store.listings.count, 13)
        XCTAssertFalse(store.paginationPaused)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B"])
    }

    func testErrorsRequireExplicitRetryAndKeepCursorAndPartialCards() async {
        let client = SearchStub([
            .success(page([card("base")], cursor: "A")),
            .success(page((0..<3).map { card("partial-\($0)") }, cursor: "B")),
            .failure(.blocked),
            .success(page([card("last")], cursor: nil))
        ])
        let store = makeStore(client)
        await store.run(query())
        await store.loadMore()
        XCTAssertNotNil(store.paginationError)
        XCTAssertFalse(store.paginationPaused)
        XCTAssertEqual(store.listings.count, 4)
        await store.loadMore()
        store.noteScroll(hiddenAsViewed: [])
        await store.loadMoreIfNeeded(currentItem: store.listings.last!, hiddenAsViewed: [])
        let before = await client.cursors
        XCTAssertEqual(before, [nil, "A", "B"])
        await store.retryLoadingMore()

        XCTAssertTrue(store.reachedEnd)
        XCTAssertNil(store.paginationError)
        XCTAssertEqual(store.listings.count, 5)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B", "B"])
    }

    func testNewSearchResetsPauseAndViewedSnapshot() async {
        let client = SearchStub([
            .success(page([card("base")], cursor: "A")),
            .success(page([], cursor: "B")),
            .success(page([card("viewed")], cursor: "C"))
        ])
        let store = makeStore(client, timeBudget: .zero)
        await store.run(query(), hiddenAsViewed: ["fb:viewed"])
        await store.loadMore()
        XCTAssertTrue(store.paginationPaused)
        await store.run(query("new"))

        XCTAssertFalse(store.paginationPaused)
        XCTAssertEqual(store.listings.compactMap(\.title), ["viewed"])
        XCTAssertNil(store.paginationError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", nil])
    }

    func testNewSearchDiscardsOldTopUpAndConcurrentDemandDoesNotDuplicateIt() async {
        let client = SearchSuspendedStub(initial: page([card("base")], cursor: "A"),
                                          subsequent: page([card("replacement")], cursor: nil))
        let store = makeStore(client)
        await store.run(query())
        let topUp = Task { await store.loadMore() }
        await client.waitUntilSuspended()
        await store.loadMore()
        await store.retryLoadingMore()
        let before = await client.cursors
        XCTAssertEqual(before, [nil, "A"])
        await store.run(query("new"))
        await client.finish(page([card("stale")], cursor: "B"))
        await topUp.value

        XCTAssertEqual(store.listings.compactMap(\.title), ["replacement"])
        XCTAssertTrue(store.reachedEnd)
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertFalse(store.paginationPaused)
    }

    func testScrollDuringSparseTopUpQueuesOneContinuation() async {
        let client = SearchSuspendedStub(initial: page([card("base")], cursor: "A"),
                                          subsequent: page([card("last")], cursor: nil))
        let store = makeStore(client, timeBudget: .zero)
        await store.run(query())
        await store.loadMoreIfNeeded(currentItem: store.listings[0], hiddenAsViewed: [])
        let topUp = Task { await store.loadMore() }
        await client.waitUntilSuspended()
        store.noteScroll(hiddenAsViewed: [])
        await client.finish(page([], cursor: "B"))
        await topUp.value
        await waitUntilIdle(store, count: 2)

        XCTAssertTrue(store.reachedEnd)
        XCTAssertNil(store.paginationError)
        let cursors = await client.cursors
        XCTAssertEqual(cursors, [nil, "A", "B"])
    }

    private func waitUntilIdle(_ store: ListingStore, count: Int) async {
        for _ in 0..<100 {
            if store.listings.count >= count && !store.isLoadingMore { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Pagination did not finish")
    }

    private func makeStore(_ client: any GraphQLFeedLoading, filterTotals: FilterTotals? = nil, timeBudget: Duration = .seconds(8)) -> ListingStore {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set(["Near, CA": [37.7793, -122.419], "Far, CA": [34.05, -118.24]], forKey: "placeCoordinates")
        let prefs = Preferences(defaults: defaults)
        prefs.radiusKM = 8
        let distances = DistanceResolver(defaults: defaults)
        distances.setUserLocation(query().coordinate)
        let cache = ListingCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), isSaved: { _ in false })
        return ListingStore(prefs: prefs, filterTotals: filterTotals, cache: cache, anonymous: client,
                            distances: distances, paginationTimeBudget: timeBudget)
    }

    private func query(_ term: String = "desk") -> SearchQuery {
        SearchQuery(kind: .search(term), radiusKM: 8, citySlug: "sanfrancisco",
                    coordinate: .init(latitude: 37.7793, longitude: -122.419))
    }

    private func card(_ id: String, city: String = "Near") -> PayloadListing {
        PayloadListing(id: id, title: id, creationTime: nil, priceAmount: "20", priceFormatted: "$20",
                       strikethroughFormatted: nil, photoURL: nil, photoID: nil, city: city, state: "CA",
                       cityPageID: nil, deliveryTypes: ["IN_PERSON"], isSold: nil, isLive: nil,
                       categoryID: nil, createdWithSellerApp: nil)
    }

    private func page(_ cards: [PayloadListing], cursor: String?) -> GraphQLFeedPage {
        .init(listings: cards, endCursor: cursor, hasNextPage: cursor != nil)
    }
}

private actor SearchStub: GraphQLFeedLoading {
    var responses: [Result<GraphQLFeedPage, GraphQLFeedError>]
    private(set) var cursors: [String?] = []
    init(_ responses: [Result<GraphQLFeedPage, GraphQLFeedError>]) { self.responses = responses }
    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        cursors.append(cursor)
        guard !responses.isEmpty else { throw GraphQLFeedError.blocked }
        return try responses.removeFirst().get()
    }
}

private actor SearchSuspendedStub: GraphQLFeedLoading {
    let initial: GraphQLFeedPage
    let subsequent: GraphQLFeedPage
    private(set) var cursors: [String?] = []
    private var pending: CheckedContinuation<GraphQLFeedPage, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(initial: GraphQLFeedPage, subsequent: GraphQLFeedPage) {
        self.initial = initial
        self.subsequent = subsequent
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
        return subsequent
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
