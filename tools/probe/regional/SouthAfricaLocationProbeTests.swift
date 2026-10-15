import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class SouthAfricaLocationProbeTests: XCTestCase {
    func testSouthAfricanCitiesResolveThroughSharedLocationPicker() async throws {
        let suite = "SouthAfricaLocationProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let chooser = PlaceChooser(prefs: preferences)
        for (city, latitude, longitude) in [
            ("Johannesburg", -26.2041, 28.0473),
            ("Cape Town", -33.9249, 18.4241),
            ("Durban", -29.8587, 31.0218),
        ] {
            let cities = AppleMapsCitySearch()
            cities.search("\(city), South Africa")
            for _ in 0..<75 {
                if !cities.suggestions.isEmpty { break }
                try await Task.sleep(for: .milliseconds(200))
            }
            let suggestion = try XCTUnwrap(cities.suggestions.first)
            chooser.switchTo(suggestion, from: cities)
            cities.clear()
            await chooser.settle()
            XCTAssertNil(chooser.failure)
            guard chooser.failure == nil else { return }
            let place = try XCTUnwrap(preferences.resolvedPlace)
            XCTAssertEqual(place.name, suggestion.title)
            XCTAssertEqual(place.countryCode, "ZA")
            XCTAssertLessThan(CLLocation(latitude: latitude, longitude: longitude).distance(
                from: CLLocation(latitude: place.latitude, longitude: place.longitude)), 30_000)
            XCTAssertTrue(place.isVerified)
            XCTAssertEqual(place.origin, .searchedCity)
            XCTAssertTrue(preferences.hasBrowseablePlace)
            XCTAssertEqual(preferences.currencySymbol, "R")
            print("SOUTH_AFRICA_LOCATION city=\(city) country=\(place.countryCode ?? "unknown") segment=\(place.segment) latitude=\(place.latitude) longitude=\(place.longitude) symbol=\(preferences.currencySymbol)")
        }
    }
}
