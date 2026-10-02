import XCTest
@testable import OpenMarket

@MainActor
final class PriceAlertsTests: XCTestCase {
    func testWorkUsesNewestAvailableSearchAndSavedLocation() throws {
        let data = Data(#"{"work":[{"id":"check","alertID":"alert","query":"Switch OLED","location":{"citySlug":"sanfrancisco","name":"San Francisco","radiusKM":16,"latitude":37.77,"longitude":-122.42},"cursor":"next-page","actor":"123","pageNumber":2}]}"#.utf8)
        let work = try PriceAlertsService.decoder().decode(PriceAlertsService.WorkList.self, from: data).work[0]
        XCTAssertEqual(work.searchQuery.sort, .newest)
        XCTAssertEqual(work.searchQuery.availability, .available)
        XCTAssertEqual(work.searchQuery.citySlug, "sanfrancisco")
        XCTAssertEqual(work.searchQuery.coordinate?.latitude, 37.77)
        XCTAssertEqual(work.cursor, "next-page")
        XCTAssertEqual(work.pageNumber, 2)
        let request = try AnonymousFeedClient.request(for: work.searchQuery, cursor: work.cursor)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let variables = try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems?.first(where: { $0.name == "variables" })?.value)
        XCTAssertTrue(variables.contains("CREATION_TIME_DESCEND"))
        XCTAssertTrue(variables.contains("commerce_search_and_rp_available"))
    }

    func testMatchesKeepExactPaginationTimestampAndCanonicalListingID() throws {
        let data = Data(#"{"matches":[{"listing":{"id":"123456789","title":"Switch OLED","priceText":"$150","locationText":"San Francisco","thumbnailURL":"","description":"","condition":""},"matchedAt":"2026-10-01T12:34:56.123456Z","matchedCursor":"2026-10-01T12:34:56.123456Z","viewedAt":null}]}"#.utf8)
        let match = try PriceAlertsService.decoder().decode(PriceAlertsService.MatchList.self, from: data).matches[0]
        XCTAssertEqual(match.matchedCursor, "2026-10-01T12:34:56.123456Z")
        XCTAssertNil(match.viewedAt)
        XCTAssertEqual(match.listing.listing.itemURL?.absoluteString, "https://www.facebook.com/marketplace/item/123456789/")
        XCTAssertEqual(match.listing.listing.id, "fb:123456789")
        let request = PriceAlertsService.Request(id: "alert", beforeID: match.id, before: match.matchedCursor)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("2026-10-01T12:34:56.123456Z"))
    }

    func testNotificationRouteSelectsAlertsAndSpecificAlert() {
        let coordinator = PriceAlertCoordinator.shared
        defer { coordinator.openAlertID = nil; coordinator.selectedTab = 0 }
        coordinator.open("test-alert")
        XCTAssertEqual(coordinator.selectedTab, 2)
        XCTAssertEqual(coordinator.openAlertID, "test-alert")
    }
}
