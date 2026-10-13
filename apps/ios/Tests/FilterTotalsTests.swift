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
        XCTAssertEqual(totals.discoverListings, 0)
        XCTAssertEqual(totals.searchListings, 0)
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

    func testShownListingsPersistAndDeduplicateSeparatelyForEachSurface() {
        let suite = "FilterTotalsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let totals = FilterTotals(defaults: defaults)

        totals.recordShownListing("one", on: .discover)
        totals.recordShownListing("one", on: .discover)
        totals.recordShownListing("two", on: .discover)
        XCTAssertEqual(totals.discoverListings, 2)
        XCTAssertEqual(totals.searchListings, 0)

        totals.recordShownListing("one", on: .search)
        totals.recordShownListing("one", on: .search)
        XCTAssertEqual(totals.searchListings, 1)

        let restored = FilterTotals(defaults: defaults)
        restored.recordShownListing("one", on: .discover)
        restored.recordShownListing("one", on: .search)
        restored.recordShownListing("three", on: .search)
        XCTAssertEqual(restored.discoverListings, 2)
        XCTAssertEqual(restored.searchListings, 2)
        XCTAssertEqual(restored.ads, 0)
        XCTAssertEqual(restored.nonLocalListings, 0)
        XCTAssertEqual(FilterTotals(defaults: defaults).searchListings, 2)
    }
}
