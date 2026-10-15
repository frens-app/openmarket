import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class MarketRegionTests: XCTestCase {
    func testEverySupportedCountryDeclaresARecognizedPricePrefix() {
        for region in MarketRegion.all where region.marketplaceVerified {
            XCTAssertFalse(region.pricePrefixes.isEmpty, "Missing prices for \(region.countryCode)")
            for prefix in region.pricePrefixes {
                XCTAssertTrue(PriceRun.isPrice("\(prefix)25"),
                              "Unrecognized \(region.countryCode) prefix \(prefix)")
            }
        }
    }

    func testCurrenciesOutsideSupportedMarketsAreNotAcceptedAsPrices() {
        XCTAssertFalse(PriceRun.isPrice("¥25"))
        XCTAssertTrue(PriceRun.isPrice("₹25"))
        XCTAssertFalse(PriceRun.isPrice("₩25"))
    }

    func testOnlyVerifiedCountriesCanBrowseMarketplace() {
        XCTAssertEqual(
            MarketRegion.verifiedMarketplaceCountryCodes,
            ["US", "CA", "GB", "IE", "AU", "NZ", "ES", "DK", "NL", "TW",
             "FR", "IT", "DE", "MX", "PH", "BR", "IN", "ID", "VN", "BD", "PK",
             "EG", "TH", "NG", "CO", "TR", "AR", "ZA", "DZ"]
        )
        XCTAssertTrue(MarketRegion.region(countryCode: "ca")?.marketplaceVerified == true)
        XCTAssertTrue(MarketRegion.region(countryCode: "GB")?.marketplaceVerified == true)
        XCTAssertTrue(MarketRegion.region(countryCode: "IT")?.marketplaceVerified == true)
        XCTAssertNil(MarketRegion.region(countryCode: "JP"))
    }

    func testResolvedPlaceNormalizesAndRetainsCountryCode() throws {
        let place = ResolvedPlace(
            name: "Toronto",
            segment: "toronto",
            coordinate: CLLocationCoordinate2D(latitude: 43.6532, longitude: -79.3832),
            origin: .searchedCity,
            countryCode: "ca"
        )

        XCTAssertEqual(place.countryCode, "CA")
        let roundTrip = try JSONDecoder().decode(
            ResolvedPlace.self,
            from: JSONEncoder().encode(place)
        )
        XCTAssertEqual(roundTrip.countryCode, "CA")
    }

    func testPreferencesRejectAStoredUnverifiedMarketplace() throws {
        let suite = "MarketRegionTests.unverified.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let place = ResolvedPlace(
            name: "Tokyo",
            segment: "tokyo",
            coordinate: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
            origin: .searchedCity,
            countryCode: "JP"
        )
        defaults.set(try JSONEncoder().encode(place), forKey: "resolvedPlace")

        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.hasBrowseablePlace)
        XCTAssertTrue(preferences.needsOnboarding)
    }

    func testPreferencesAcceptEveryNewlyVerifiedMarketplace() throws {
        for countryCode in MarketRegion.verifiedMarketplaceCountryCodes {
            let suite = "MarketRegionTests.verified.\(countryCode).\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let place = ResolvedPlace(
                name: countryCode,
                segment: countryCode.lowercased(),
                coordinate: CLLocationCoordinate2D(latitude: 1, longitude: 1),
                origin: .searchedCity,
                countryCode: countryCode
            )
            defaults.set(try JSONEncoder().encode(place), forKey: "resolvedPlace")

            XCTAssertTrue(
                Preferences(defaults: defaults).hasBrowseablePlace,
                "\(countryCode) should be browseable"
            )
        }
    }

    func testLegacyStoredPlaceRemainsBrowseableUntilItIsReselected() throws {
        let suite = "MarketRegionTests.legacy.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let place = ResolvedPlace(
            name: "San Francisco",
            segment: "sanfrancisco",
            coordinate: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
            origin: .searchedCity
        )
        defaults.set(try JSONEncoder().encode(place), forKey: "resolvedPlace")

        XCTAssertTrue(Preferences(defaults: defaults).hasBrowseablePlace)
    }
}
