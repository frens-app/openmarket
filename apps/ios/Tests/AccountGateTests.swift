import XCTest
@testable import OpenMarket

@MainActor
final class AccountGateTests: XCTestCase {
    func testGuestStartsWithPhone() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: false, facebookConnected: false), .phone)
    }

    func testFacebookAloneStillRequiresPhone() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: false, facebookConnected: true), .phone)
    }

    func testVerifiedAccountWithoutFacebookContinuesToFacebook() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: true, facebookConnected: false), .facebook)
    }

    func testBothSessionsCompleteWithoutAnotherStep() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: true, facebookConnected: true), .complete)
    }
}
