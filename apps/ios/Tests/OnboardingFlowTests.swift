import XCTest
@testable import OpenMarket

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testSkippingAccountStillReachesLocationAndFacebook() {
        XCTAssertEqual(OnboardingView.Step.account.next(), .location)
        XCTAssertEqual(OnboardingView.Step.location.next(), .facebook)
    }

    func testFacebookIsTheFinalStep() {
        XCTAssertNil(OnboardingView.Step.facebook.next())
    }
}
