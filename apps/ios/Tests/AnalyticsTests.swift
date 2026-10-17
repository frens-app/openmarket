import XCTest
@testable import OpenMarket

/// A misnamed event doesn't fail or warn — it lands in PostHog as a second event
/// beside the right one, splitting a funnel nobody looks at for a month. These
/// catch it at compile time instead.
final class AnalyticsTests: XCTestCase {
    func testEveryEventNameFollowsTheConvention() {
        for event in Analytics.Event.allCases {
            assertSnakeCase(event.rawValue, what: "event")
        }
    }

    func testEverySurfaceValueFollowsTheConvention() {
        for surface in Analytics.Surface.allCases {
            assertSnakeCase(surface.rawValue, what: "surface")
        }
    }

    func testEverySearchSourceValueFollowsTheConvention() {
        for source in [Analytics.SearchSource.typed, .recent] {
            assertSnakeCase(source.rawValue, what: "search source")
        }
    }

    /// PostHog groups events by prefix, so a stray `copied_price_check` would
    /// sort away from the funnel it belongs to.
    func testPriceCheckEventsShareTheirPrefix() {
        let priceCheck: [Analytics.Event] = [
            .priceCheckStarted, .priceCheckCompleted, .priceCheckFailed,
            .priceCheckPriceCopied, .priceCheckListingCopied,
            .priceCheckFeedbackSubmitted, .priceCheckEvidenceOpened,
            .priceCheckHistoryOpened
        ]
        for event in priceCheck {
            XCTAssertTrue(event.rawValue.hasPrefix("price_check_"),
                          "\(event.rawValue) is a price check event and should say so first")
        }
    }

    /// And the buyer-side check keeps its own prefix, so the two never merge
    /// into one funnel — they answer different questions and end differently.
    func testListingPriceCheckEventsShareTheirPrefix() {
        let listingPriceCheck: [Analytics.Event] = [
            .listingPriceCheckClicked, .listingPriceCheckStarted, .listingPriceCheckCompleted, .listingPriceCheckFailed,
            .listingPriceCheckEvidenceOpened
        ]
        for event in listingPriceCheck {
            XCTAssertTrue(event.rawValue.hasPrefix("listing_price_check_"),
                          "\(event.rawValue) is a listing price check event and should say so first")
        }
    }

    func testListingOpensKeepCanonicalIdentityAcrossSurfaces() throws {
        let listing = AlertListing(id: "123456789", title: "  Anthurium  ", priceText: "$25",
            locationText: "Toronto", thumbnailURL: "", description: "", condition: "").listing
        for surface in [Analytics.Surface.discover, .search, .aiSearch, .listingAlerts] {
            let properties = Analytics.listingOpenProperties(listing, surface: surface, position: 2,
                isSaved: false, isSeen: true)
            XCTAssertEqual(properties["listing_id"] as? String, "fb:123456789")
            XCTAssertEqual(properties["surface"] as? String, surface.rawValue)
            XCTAssertEqual(properties["position"] as? Int, 2)
            XCTAssertEqual(properties["title"] as? String, "Anthurium")
            XCTAssertEqual(properties["is_saved"] as? Bool, false)
            XCTAssertEqual(properties["is_seen"] as? Bool, true)
            XCTAssertNil(properties["notification_id"])
            XCTAssertNil(properties["alert_id"])
        }
    }

    // MARK: - Configuration

    /// Tests run under Debug, which ships `POSTHOG_CAPTURE_EVENTS = NO`.
    ///
    /// Asserted rather than assumed, because the failure is silent in both
    /// directions: a `YES` that reaches this file means every CI run and every
    /// simulator session is writing events, and nothing else would say so.
    func testDebugBuildsDoNotCaptureEvents() {
        XCTAssertFalse(Analytics.capturesEvents)
    }

    /// And the SDK is still configured, which is the point of the split — a
    /// non-capturing build can still evaluate feature flags.
    func testAnalyticsIsStillConfiguredWhileNotCapturing() {
        XCTAssertTrue(Analytics.isEnabled)
    }

    // MARK: - Free text

    /// An empty property is a value in PostHog: it makes its own breakdown row
    /// and counts as "set" in a filter, which would make a listing with no title
    /// indistinguishable from one whose title failed to parse.
    func testEmptyTextIsAbsentRatherThanBlank() {
        XCTAssertNil(Analytics.text(nil))
        XCTAssertNil(Analytics.text(""))
        XCTAssertNil(Analytics.text("   \n "))
    }

    func testTextIsTrimmed() {
        XCTAssertEqual(Analytics.text("  Weber Genesis II  "), "Weber Genesis II")
    }

    func testLongTextIsTruncated() {
        let capped = Analytics.text(String(repeating: "a", count: 500))
        XCTAssertEqual(capped?.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(capped?.hasSuffix("…") == true)
    }

    func testTextAtTheLimitIsUntouched() {
        let exact = String(repeating: "a", count: 200)
        XCTAssertEqual(Analytics.text(exact), exact)
    }

    private func assertSnakeCase(_ value: String, what: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value.isEmpty, "an \(what) name may not be empty", file: file, line: line)
        XCTAssertEqual(value, value.lowercased(),
                       "\(what) `\(value)` should be lowercase", file: file, line: line)
        XCTAssertTrue(value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "_" },
                      "\(what) `\(value)` should be snake_case with no spaces or punctuation",
                      file: file, line: line)
        XCTAssertFalse(value.hasPrefix("_") || value.hasSuffix("_"),
                       "\(what) `\(value)` has a stray underscore", file: file, line: line)
    }
}
