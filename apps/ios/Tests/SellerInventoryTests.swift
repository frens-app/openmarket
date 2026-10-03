import XCTest
import WebKit
@testable import OpenMarket

@MainActor
final class SellerInventoryTests: XCTestCase {
    private final class Loader: SellerInventoryLoading {
        let webView = WKWebView()
        var first: CheckedContinuation<SellerInventoryPage, Error>?
        var last: CheckedContinuation<SellerInventoryPage, Error>?
        var next: Result<SellerInventoryPage, Error> = .failure(SellerInventoryError.unavailable)
        var loads = 0
        func load(profile: SellerProfile, filter: SellerListingFilter) async throws -> SellerInventoryPage {
            loads += 1
            return try await withCheckedThrowingContinuation { continuation in
                if first == nil { first = continuation } else { last = continuation }
            }
        }
        func nextPage() async throws -> SellerInventoryPage { try next.get() }
        func cancel() {}
    }

    private var profile: SellerProfile {
        SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "Example Seller"))!
    }
    private func card(_ id: String) -> Listing {
        Listing(id: "fb:\(id)", title: "Item", itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(id)/"), cardIndex: 0, capturedAt: Date())
    }
    private func waitForLoad(_ loader: Loader, count: Int) async {
        for _ in 0..<100 where loader.loads < count { await Task.yield() }
    }

    func testReturningFromListingPreservesInventoryAndPagination() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let photoURL = URL(string: "https://example.com/seller.jpg")!
        let load = Task { await model.loadIfNeeded(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: true, sellerPhotoURL: photoURL))
        await load.value
        loader.next = .success(SellerInventoryPage(items: [card("2")], hasMore: true))
        await model.loadMore()
        model.cancel()

        await model.loadIfNeeded(profile: profile, filter: .available)

        XCTAssertEqual(loader.loads, 1)
        XCTAssertEqual(model.items.map(\.id), ["fb:1", "fb:2"])
        XCTAssertEqual(model.sellerPhotoURL, photoURL)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.canLoadMore)
        loader.next = .success(SellerInventoryPage(items: [card("3")], hasMore: false))
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id), ["fb:1", "fb:2", "fb:3"])
    }

    func testEmptyInventoryIsReusedButExplicitRefreshReloads() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let load = Task { await model.loadIfNeeded(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        loader.first?.resume(returning: SellerInventoryPage(items: [], hasMore: false))
        await load.value
        model.cancel()
        await model.loadIfNeeded(profile: profile, filter: .available)
        XCTAssertEqual(loader.loads, 1)

        let refresh = Task { await model.load(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 2)
        loader.last?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: false))
        await refresh.value
        XCTAssertEqual(loader.loads, 2)
        XCTAssertEqual(model.items.map(\.id), ["fb:1"])
    }

    func testChangingFilterOrSellerLoadsNewInventory() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let load = Task { await model.loadIfNeeded(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: false))
        await load.value

        let filterChange = Task { await model.loadIfNeeded(profile: profile, filter: .unavailable) }
        await waitForLoad(loader, count: 2)
        loader.last?.resume(returning: SellerInventoryPage(items: [card("2")], hasMore: false))
        await filterChange.value
        XCTAssertEqual(model.items.map(\.id), ["fb:2"])

        let other = SellerProfile(detail: ListingDetail(sellerProfileID: "987654321", sellerName: "Other Seller"))!
        let sellerChange = Task { await model.loadIfNeeded(profile: other, filter: .unavailable) }
        await waitForLoad(loader, count: 3)
        loader.last?.resume(returning: SellerInventoryPage(items: [card("3")], hasMore: false))
        await sellerChange.value
        XCTAssertEqual(loader.loads, 3)
        XCTAssertEqual(model.items.map(\.id), ["fb:3"])
    }

    func testCancelledInitialLoadCanRestartOnReturn() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let load = Task { await model.loadIfNeeded(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        model.cancel()
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: false))
        await load.value

        let retry = Task { await model.loadIfNeeded(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 2)
        loader.last?.resume(returning: SellerInventoryPage(items: [card("2")], hasMore: false))
        await retry.value
        XCTAssertEqual(loader.loads, 2)
        XCTAssertEqual(model.items.map(\.id), ["fb:2"])
    }

    func testSupersededFilterCannotPublishOldInventory() async {
        let loader = Loader()
        let inventory = SellerInventory(loader: loader)
        let first = Task { await inventory.load(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        let second = Task { await inventory.load(profile: profile, filter: .unavailable) }
        await waitForLoad(loader, count: 2)
        loader.last?.resume(returning: SellerInventoryPage(items: [card("2")], hasMore: false))
        await second.value
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: true))
        await first.value
        XCTAssertEqual(inventory.items.map(\.id), ["fb:2"])
        XCTAssertFalse(inventory.canLoadMore)
        XCTAssertFalse(inventory.isLoading)
    }

    func testPaginationDeduplicatesAndPreservesItemsOnFailure() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let load = Task { await model.load(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: true))
        await load.value
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertNotNil(model.errorMessage)
        loader.next = .success(SellerInventoryPage(items: [card("1"), card("2")], hasMore: false))
        await model.retry(profile: profile, filter: .available)
        XCTAssertEqual(model.items.map(\.id), ["fb:1", "fb:2"])
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.canLoadMore)
    }

    func testSessionChangeDiscardsInventory() async {
        let loader = Loader()
        let model = SellerInventory(loader: loader)
        let load = Task { await model.load(profile: profile, filter: .available) }
        await waitForLoad(loader, count: 1)
        loader.first?.resume(returning: SellerInventoryPage(items: [card("1")], hasMore: true))
        await load.value
        loader.next = .failure(GraphQLFeedError.sessionChanged)
        await model.loadMore()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.canLoadMore)
        XCTAssertNotNil(model.errorMessage)
    }
}
