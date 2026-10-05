import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class LocationTargetingProbeTests: XCTestCase {
    func testExplicitCoordinatesWithoutPicker() async throws {
        guard await SessionState.isSignedIn() else { throw XCTSkip("Requires existing Facebook session") }
        let downtown = CLLocationCoordinate2D(latitude: 43.6503, longitude: -79.3596)
        let north = CLLocationCoordinate2D(latitude: 43.7615, longitude: -79.4111)
        let sf = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let resolution = await UnauthenticatedMarketplacePlaceResolver(pacer: RequestPacer())
            .resolve(downtown, name: "Distillery District", origin: .searchedCity)
        let place = try resolution.get()
        print("LOCATION_PROBE resolved segment=\(place.segment) preservedCoordinate=\(place.latitude == downtown.latitude && place.longitude == downtown.longitude)")
        let engine = DesktopFeedEngine(session: .authed, pacer: RequestPacer())
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(engine.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = AuthenticatedFeedClient(webView: engine.webView, pacer: RequestPacer())
        var results: [Set<String>] = []
        for (label, coordinate) in [("downtown-A", downtown), ("north-B", north), ("downtown-A2", downtown), ("sf-control", sf)] {
            let query = SearchQuery(kind: .search("desk"), radiusKM: 5, citySlug: place.segment,
                                    coordinate: coordinate, sort: .nearest, delivery: .localPickup)
            let page = try await client.page(for: query, cursor: nil)
            XCTAssertFalse(page.listings.isEmpty)
            results.append(Set(page.listings.map(\.id)))
            let cities = Dictionary(grouping: page.listings, by: { $0.locationText ?? "unknown" }).mapValues(\.count)
            print("LOCATION_PROBE search \(label) count=\(page.listings.count) cities=\(cities)")
        }
        print("LOCATION_PROBE intersections A-B=\(results[0].intersection(results[1]).count) A-A2=\(results[0].intersection(results[2]).count) A-SF=\(results[0].intersection(results[3]).count)")
        XCTAssertNotEqual(results[0], results[3])
        for (label, coordinate) in [("toronto", downtown), ("sf-control", sf)] {
            let query = SearchQuery(kind: .browse, radiusKM: 5, citySlug: place.segment, coordinate: coordinate)
            let page = try await client.page(for: query, cursor: nil)
            let cities = Dictionary(grouping: page.listings, by: { $0.locationText ?? "unknown" }).mapValues(\.count)
            print("LOCATION_PROBE browse \(label) count=\(page.listings.count) cities=\(cities)")
            XCTAssertFalse(page.listings.isEmpty)
        }
    }
}
