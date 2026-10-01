import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class DistanceResolverTests: XCTestCase {
    func testCityCenterDoesNotBecomeListingDistance() throws {
        let suite = "DistanceResolverTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["Test City": [0.0, 0.0]], forKey: "placeCoordinates")
        let resolver = DistanceResolver(defaults: defaults)
        resolver.setUserLocation(.init(latitude: 0, longitude: 0))
        var listing = Listing(id: "test", locationText: "Test City", cardIndex: 0, capturedAt: Date())

        XCTAssertEqual(resolver.distanceKM(for: listing.locationText), 0)
        XCTAssertNil(resolver.bestDistanceText(for: listing))

        listing.detail = ListingDetail(latitude: 0, longitude: 0.061)
        XCTAssertEqual(resolver.bestDistanceText(for: listing), "~4.2 mi")

        let restored = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(listing))
        XCTAssertEqual(resolver.bestDistanceText(for: restored), "~4.2 mi")
    }

    func testIncompleteOrInvalidListingPointDoesNotProduceDistance() {
        let resolver = DistanceResolver()
        resolver.setUserLocation(.init(latitude: 0, longitude: 0))
        var listing = Listing(id: "test", cardIndex: 0, capturedAt: Date())
        for detail in [ListingDetail(latitude: 0),
                       ListingDetail(latitude: 91, longitude: 0),
                       ListingDetail(latitude: 0, longitude: .nan)] {
            listing.detail = detail
            XCTAssertNil(resolver.bestDistanceText(for: listing))
        }
    }

    func testApproximatePointDoesNotClaimExactColocation() {
        let resolver = DistanceResolver()
        resolver.setUserLocation(.init(latitude: 0, longitude: 0))
        let listing = Listing(id: "test", cardIndex: 0,
                              detail: ListingDetail(latitude: 0, longitude: 0), capturedAt: Date())
        XCTAssertEqual(resolver.bestDistanceText(for: listing), "Nearby")
    }
}
