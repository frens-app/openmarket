import CoreLocation
import OpenMarketProtos
import XCTest
@testable import OpenMarket

@MainActor
final class ShoppingTests: XCTestCase {
    private func preferences() -> Preferences {
        let defaults = UserDefaults(suiteName: "shopping-tests-\(UUID().uuidString)")!
        let prefs = Preferences(defaults: defaults)
        prefs.locationSlug = "sanfrancisco"
        prefs.locationName = "San Francisco"
        prefs.radiusKM = 16
        return prefs
    }
    func testSearchMapsIndividualFiltersWithoutChangingDeviceSettings() throws {
        let prefs = preferences()
        let area = try XCTUnwrap(ShoppingTools.Area(prefs: prefs))
        var search = ShoppingSearch()
        search.query = "desk"; search.minPrice = 0; search.maxPrice = 150
        search.sort = "price_lowest"; search.delivery = "local_pickup"
        search.conditions = ["used_good"]; search.listedWithinDays = 7
        search.availability = "available"
        let query = try ShoppingTools.query(search, area: area)
        XCTAssertEqual(query.kind, .search("desk"))
        XCTAssertEqual(query.citySlug, "sanfrancisco")
        XCTAssertEqual(query.radiusKM, 16)
        XCTAssertEqual(query.minPrice, 0)
        XCTAssertEqual(query.maxPrice, 150)
        XCTAssertEqual(query.sort, .priceLowest)
        XCTAssertEqual(query.delivery, .localPickup)
        XCTAssertEqual(query.conditions, [.usedGood])
        XCTAssertEqual(query.age, .week)
        XCTAssertEqual(prefs.radiusKM, 16)
        search.sort = "invented"
        XCTAssertThrowsError(try ShoppingTools.query(search, area: area))
    }
    func testDetailRoundtripPreservesParsedFieldsAndUnknowns() throws {
        var detail = ListingDetail()
        detail.description = "Solid oak, 54 inches wide with drawers"
        detail.photoURLs = [URL(string: "https://example.com/photo.jpg")!]
        detail.postedText = "Listed today"
        detail.conditionText = "Used - Good"
        detail.locationText = "San Francisco"
        detail.sellerProfileID = "123"
        detail.sellerName = "Seller"
        detail.sellerJoined = "2020"
        detail.sellerRating = 4.8
        detail.sellerRatingCount = 12
        detail.sellerIsHighlyRated = false
        detail.latitude = 37.7
        detail.longitude = -122.4
        detail.isSold = false
        detail.isPending = nil
        detail.fulfillment = Fulfillment(tokens: ["IN_PERSON", "DOOR_PICKUP"])
        let listing = Listing(id: "fb:123456789", title: "Desk", priceText: "$100", originalPriceText: "$150",
                              locationText: "San Francisco", thumbnailURL: URL(string: "https://example.com/photo.jpg"),
                              itemURL: URL(string: "https://www.facebook.com/marketplace/item/123456789/"),
                              cardIndex: 0, detail: detail, capturedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let observation = ShoppingListing(listing, source: "item_detail")
        XCTAssertTrue(observation.hasDetail)
        XCTAssertTrue(observation.detail.hasIsSold)
        XCTAssertFalse(observation.detail.hasIsPending)
        XCTAssertEqual(observation.parsed.detail, detail)
        XCTAssertEqual(observation.parsed.title, listing.title)
        XCTAssertEqual(observation.parsed.itemURL, listing.itemURL)
        XCTAssertEqual(observation.parsed.capturedAt, listing.capturedAt)
    }
    func testSearchCardDoesNotInventDetailOrPrice() {
        let listing = Listing(id: "fb:123456789", title: "Desk", cardIndex: 0, capturedAt: Date())
        let observation = ShoppingListing(listing, source: "authenticated_graphql")
        XCTAssertFalse(observation.hasDetail)
        XCTAssertFalse(observation.hasPriceText)
        XCTAssertNil(observation.parsed.detail)
        XCTAssertNil(observation.parsed.priceText)
    }
    func testAreaSnapshotDoesNotFollowLaterPreferenceChanges() throws {
        let prefs = preferences()
        let area = try XCTUnwrap(ShoppingTools.Area(prefs: prefs))
        prefs.locationSlug = "oakland"
        prefs.radiusKM = 40
        var search = ShoppingSearch(); search.query = "desk"
        let query = try ShoppingTools.query(search, area: area)
        XCTAssertEqual(query.citySlug, "sanfrancisco")
        XCTAssertEqual(query.radiusKM, 16)
        XCTAssertNotEqual(area, ShoppingTools.Area(prefs: prefs))
    }
}

@MainActor
private final class ShoppingFeedFixture: GraphQLFeedLoading {
    var cursors: [String?] = []
    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        cursors.append(cursor)
        let id = cursor == nil ? "123456789" : "987654321"
        let raw = """
        {"data":{"marketplace_search":{"feed_units":{"edges":[{"node":{"listing":{"id":"\(id)","marketplace_listing_title":"Desk"}}}],"page_info":{"has_next_page":false}}}}}
        """
        let parsed = try GraphQLFeedDecoder.decode(Data(raw.utf8), kind: .search("desk"))
        return GraphQLFeedPage(listings: parsed.listings, endCursor: cursor == nil ? "source-page-2" : nil, hasNextPage: cursor == nil)
    }
}

extension ShoppingTests {
    func testFrontendPaginationInspectionAndRetryUseCachedResults() async throws {
        let loader = ShoppingFeedFixture()
        var inspectionCount = 0
        let tools = ShoppingTools(feedLoader: loader, actorProvider: { "actor" }, detailLoader: { _ in
            inspectionCount += 1
            var detail = ListingDetail()
            detail.description = "Solid oak with drawers"
            return detail
        })
        tools.begin(try XCTUnwrap(ShoppingTools.Area(prefs: preferences())))
        var search = ShoppingSearch(); search.query = "desk"
        var first = ShoppingToolCall(); first.id = "page1"; first.search = search
        let page1 = try await tools.execute(first)
        XCTAssertTrue(page1.hasMore_p)
        XCTAssertNotEqual(page1.nextCursor, "source-page-2")
        XCTAssertEqual(page1.listings.map(\.id), ["fb:123456789"])
        _ = try await tools.execute(first)
        XCTAssertEqual(loader.cursors.count, 1, "retry fetched the source twice")
        search.cursor = page1.nextCursor
        var next = ShoppingToolCall(); next.id = "page2"; next.search = search
        let page2 = try await tools.execute(next)
        XCTAssertFalse(page2.hasMore_p)
        XCTAssertEqual(loader.cursors.last!, "source-page-2")
        XCTAssertEqual(page2.listings.map(\.id), ["fb:987654321"])
        var inspect = ShoppingToolCall(); inspect.id = "inspect"
        var args = ShoppingInspect(); args.listingID = "fb:123456789"; inspect.inspect = args
        let detail = try await tools.execute(inspect)
        XCTAssertEqual(detail.listings.first?.detail.description_p, "Solid oak with drawers")
        _ = try await tools.execute(inspect)
        XCTAssertEqual(inspectionCount, 1)
    }
}
