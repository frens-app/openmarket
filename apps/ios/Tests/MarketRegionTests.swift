import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class MarketRegionTests: XCTestCase {
    func testOfflinePhoneFallbackComesFromCountryCatalog() {
        XCTAssertEqual(MarketRegion.defaultPhoneCallingCodes, ["1", "44", "353", "61", "64"])
        XCTAssertEqual(PhoneCountry.fallbackCallingCodes, MarketRegion.defaultPhoneCallingCodes)

        let expectedCountries = Set(
            MarketRegion.all.filter(\.phoneEnabledByDefault).map(\.countryCode)
        )
        let offeredCountries = Set(
            PhoneCountry.served(callingCodes: PhoneCountry.fallbackCallingCodes).map(\.regionCode)
        )
        XCTAssertEqual(offeredCountries, expectedCountries)
    }

    func testEveryDefaultPhoneCountryDeclaresARecognizedPricePrefix() {
        for region in MarketRegion.all where region.phoneEnabledByDefault {
            XCTAssertFalse(region.pricePrefixes.isEmpty, "Missing prices for \(region.countryCode)")
            for prefix in region.pricePrefixes {
                XCTAssertTrue(PriceRun.isPrice("\(prefix)25"),
                              "Unrecognized \(region.countryCode) prefix \(prefix)")
            }
        }
    }

    func testCurrenciesOutsidePhoneCatalogAreNotAcceptedAsPrices() {
        XCTAssertFalse(PriceRun.isPrice("¥25"))
        XCTAssertFalse(PriceRun.isPrice("₹25"))
        XCTAssertFalse(PriceRun.isPrice("₩25"))
    }

    func testOnlyVerifiedCountriesCanBrowseMarketplace() {
        XCTAssertEqual(MarketRegion.verifiedMarketplaceCountryCodes, ["US", "CA"])
        XCTAssertTrue(MarketRegion.region(countryCode: "ca")?.marketplaceVerified == true)
        XCTAssertFalse(MarketRegion.region(countryCode: "GB")?.marketplaceVerified == true)
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
            name: "London",
            segment: "london",
            coordinate: CLLocationCoordinate2D(latitude: 51.5072, longitude: -0.1276),
            origin: .searchedCity,
            countryCode: "GB"
        )
        defaults.set(try JSONEncoder().encode(place), forKey: "resolvedPlace")

        let preferences = Preferences(defaults: defaults)

        XCTAssertFalse(preferences.hasBrowseablePlace)
        XCTAssertTrue(preferences.needsOnboarding)
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
