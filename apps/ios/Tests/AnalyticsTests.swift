import XCTest
@testable import OpenMarket

/// The naming convention, enforced.
///
/// These look like tests of nothing until the first time somebody adds
/// `priceCheckShared = "PriceCheckShared"` in a hurry. A misnamed event does not
/// fail, warn, or look wrong at the call site — it lands in PostHog as a second
/// event beside the right one, splitting a funnel in half, and nobody notices
/// until the chart has a month of data in it. Compile-time is the only cheap
/// moment to catch it.
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
        for source in [Analytics.SearchSource.typed, .recent, .interest] {
            assertSnakeCase(source.rawValue, what: "search source")
        }
    }

    func testEverySearchTriggerValueFollowsTheConvention() {
        let triggers: [Analytics.SearchTrigger] = [
            .newSearch, .filters, .location, .refresh, .rerun, .retry, .signIn
        ]
        for trigger in triggers {
            assertSnakeCase(trigger.rawValue, what: "search trigger")
        }
    }

    /// Events are grouped in PostHog's insight builder by their prefix, which is
    /// the whole reason the price-check ones share one. A stray
    /// `copied_price_check` would sort somewhere else entirely and stop reading
    /// as part of the funnel.
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

    // MARK: - Free text

    /// Empty has to come back nil, not `""`.
    ///
    /// A property set to the empty string is a value in PostHog: it makes its
    /// own row in a breakdown and it counts as "set" in a filter. A listing with
    /// no title and a listing whose title failed to parse would then be
    /// indistinguishable from each other, and both distinguishable from a
    /// listing that was never asked — which is exactly backwards.
    func testEmptyTextIsAbsentRatherThanBlank() {
        XCTAssertNil(Analytics.text(nil))
        XCTAssertNil(Analytics.text(""))
        XCTAssertNil(Analytics.text("   \n "))
    }

    func testTextIsTrimmed() {
        XCTAssertEqual(Analytics.text("  Weber Genesis II  "), "Weber Genesis II")
    }

    /// The cap is a size measure, not a privacy one — but an uncapped property
    /// is how one pasted essay becomes a 50KB event that sits in the queue and
    /// is retried on every flush.
    func testLongTextIsTruncated() {
        let long = String(repeating: "a", count: 500)
        let capped = Analytics.text(long)
        XCTAssertEqual(capped?.count, 201, "200 characters plus the ellipsis")
        XCTAssertTrue(capped?.hasSuffix("…") == true)
    }

    /// Nothing is added to something that already fits.
    func testTextAtTheLimitIsUntouched() {
        let exact = String(repeating: "a", count: 200)
        XCTAssertEqual(Analytics.text(exact), exact)
    }

// `testAnalyticsIsOffInTests` stood here, asserting `Analytics.isEnabled` was
// false because Debug shipped no key. Debug now points at the dev PostHog
// project deliberately, so the assertion is testing a decision that has been
// reversed rather than an invariant. Note the consequence it was written to
// flag: the host app launches for a test run, so `$application_opened` reaches
// the dev project on every `make ios-build`-and-test. That is what a dev
// project is for, but it is why the two keys must not be the same one.

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
