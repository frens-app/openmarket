import XCTest
@testable import OpenMarket

final class OnboardingFlowTests: XCTestCase {
    func testFacebookStepIsNotPresented() {
        XCTAssertFalse(OnboardingView.includesFacebookStep)

        let presented = OnboardingView.Step.allCases.filter {
            OnboardingView.includesFacebookStep || $0 != .facebook
        }
        XCTAssertEqual(presented, [.phone, .location, .notifications])
        XCTAssertEqual(
            OnboardingView.Step.phone.next(
                includingFacebook: OnboardingView.includesFacebookStep
            ),
            .location
        )
    }
}
