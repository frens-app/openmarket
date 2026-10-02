import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class AnonymousDetailProbeTests: XCTestCase {
    func testProductionAnonymousRoute() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("Use the logged-out QA Simulator") }
        let query = SearchQuery(kind: .search("plant"), radiusKM: 8, citySlug: "sanfrancisco",
                               coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                               delivery: .localPickup)
        let page = try await AnonymousFeedClient().page(for: query, cursor: nil)
        let target = try XCTUnwrap(page.listings.first)
        let listing = target.makeListing(cardIndex: 0)
        let engine = DetailEngine()
        let start = Date()
        var stages = 0
        let detail = await engine.loadDetail(id: listing.id, url: listing.itemURL!) { _ in stages += 1 }
        let result = try XCTUnwrap(detail)
        XCTAssertEqual(engine.lastTransport, "anonymous_graphql")
        XCTAssertNil(engine.webView.url, "No browser preparation or item navigation on success")
        XCTAssertFalse(result.photoURLs.isEmpty)
        XCTAssertNotNil(result.description)
        print("ANONYMOUS_DETAIL_PRODUCTION ms=\(Int(Date().timeIntervalSince(start)*1000)) stages=\(stages) photos=\(result.photoURLs.count) browser_loaded=\(engine.webView.url != nil)")
    }

    func testAnonymousComparison() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("Use a separate logged-out Simulator") }
        let query = SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco",
                               coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                               delivery: .localPickup)
        let feed = AnonymousFeedClient()
        let active = try await feed.page(for: query, cursor: nil)
        var soldQuery = query
        soldQuery.availability = .unavailable
        let sold = try await feed.page(for: soldQuery, cursor: nil)
        var targets = Array(active.listings.prefix(2))
        if let item = sold.listings.first(where: { $0.isSold == true }) { targets.append(item) }
        XCTAssertEqual(targets.count, 3)
        let browser = DetailEngine()
        let client = DetailGraphQLClient()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        host.view.addSubview(browser.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        for (index, target) in targets.enumerated() {
            let listing = target.makeListing(cardIndex: 0)
            var native: ListingDetail?, page: ListingDetail?
            var nativeMS = 0, browserMS = 0, browserGalleryMS = 0, coreMS = 0
            for useNative in index == 1 ? [false, true] : [true, false] {
                let start = Date()
                if useNative {
                    native = try await client.load(itemID: target.id, actor: nil) { _ in
                        if coreMS == 0 { coreMS = Int(Date().timeIntervalSince(start) * 1000) }
                    }
                    nativeMS = Int(Date().timeIntervalSince(start) * 1000)
                } else {
                    page = await browser.loadBrowserDetail(id: listing.id, url: listing.itemURL!) { stage in
                        if browserGalleryMS == 0, !stage.photoURLs.isEmpty {
                            browserGalleryMS = Int(Date().timeIntervalSince(start) * 1000)
                        }
                    }
                    browserMS = Int(Date().timeIntervalSince(start) * 1000)
                }
            }
            let direct = try XCTUnwrap(native), baseline = try XCTUnwrap(page)
            let a = Set(direct.photoURLs.compactMap(Listing.photoFBID))
            let b = Set(baseline.photoURLs.compactMap(Listing.photoFBID))
            let summary: [String: Any] = [
                "index": index, "sold": target.isSold == true,
                "native_ms": nativeMS, "native_core_ms": coreMS,
                "browser_ms": browserMS, "browser_gallery_ms": browserGalleryMS,
                "native_photos": direct.photoURLs.count, "browser_photos": baseline.photoURLs.count,
                "photo_ids_equal": a == b,
                "description_equal": direct.description == baseline.description,
                "description_contains_browser": direct.description?.contains(baseline.description ?? "") == true,
                "native_description_length": direct.description?.count ?? 0,
                "browser_description_length": baseline.description?.count ?? 0,
                "native_condition": direct.conditionText != nil, "browser_condition": baseline.conditionText != nil,
                "native_posted": direct.postedText != nil, "browser_posted": baseline.postedText != nil,
                "coordinates_equal": direct.latitude == baseline.latitude && direct.longitude == baseline.longitude,
                "native_coordinates": direct.latitude != nil && direct.longitude != nil,
                "browser_coordinates": baseline.latitude != nil && baseline.longitude != nil,
                "location_equal": direct.locationText == baseline.locationText,
                "fulfillment_equal": direct.fulfillment == baseline.fulfillment,
                "availability_equal": direct.isSold == baseline.isSold && direct.isPending == baseline.isPending,
                "native_seller": direct.sellerName != nil, "browser_seller": baseline.sellerName != nil
            ]
            print("ANONYMOUS_DETAIL_PROBE \(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys),as:UTF8.self))")
            XCTAssertFalse(a.isEmpty)
            XCTAssertTrue(a.isSuperset(of: b))
            XCTAssertEqual(direct.isSold, target.isSold)
            XCTAssertTrue(direct.description?.contains(baseline.description ?? "") == true)
        }
    }
}
