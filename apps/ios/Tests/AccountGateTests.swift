import XCTest
@testable import OpenMarket

@MainActor
final class AccountGateTests: XCTestCase {
    func testGuestStartsWithAccount() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: false, facebookConnected: false), .account)
    }

    func testFacebookAloneStillRequiresAccount() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: false, facebookConnected: true), .account)
    }

    func testVerifiedAccountWithoutFacebookContinuesToFacebook() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: true, facebookConnected: false), .facebook)
    }

    func testBothSessionsCompleteWithoutAnotherStep() {
        XCTAssertEqual(AccountGateView.Step.next(hasAccount: true, facebookConnected: true), .complete)
    }
}
