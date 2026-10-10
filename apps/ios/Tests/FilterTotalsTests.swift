import XCTest
@testable import OpenMarket

@MainActor
final class FilterTotalsTests: XCTestCase {
    func testTotalsPersistAndListingsAreCountedOnceAcrossLaunches() {
        let suite = "FilterTotalsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let totals = FilterTotals(defaults: defaults)
        XCTAssertEqual(totals.nonLocalListings, 0)
        XCTAssertEqual(totals.ads, 0)
        totals.recordNonLocal(["one", "two", "one"])
        totals.recordSponsoredListing("ad")
        totals.recordSponsoredListing("ad")
        totals.recordAds(3)
        totals.recordAds(0)

        let restored = FilterTotals(defaults: defaults)
        restored.recordNonLocal(["two", "three"])
        restored.recordSponsoredListing("ad")
        XCTAssertEqual(restored.nonLocalListings, 3)
        XCTAssertEqual(restored.ads, 4)
        XCTAssertEqual(FilterTotals(defaults: defaults).nonLocalListings, 3)
    }
}
