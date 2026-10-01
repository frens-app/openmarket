import XCTest
@testable import OpenMarket

@MainActor
final class OnboardingFlowTests: XCTestCase {
    func testSkippingPhoneStillReachesLocationAndFacebook() {
        XCTAssertEqual(OnboardingView.Step.phone.next(hasAccount: false, needsNotificationPermission: true), .location)
        XCTAssertEqual(OnboardingView.Step.location.next(hasAccount: false, needsNotificationPermission: true), .facebook)
    }

    func testGuestFinishesWithoutNotificationSetup() {
        XCTAssertNil(OnboardingView.Step.facebook.next(hasAccount: false, needsNotificationPermission: true))
    }

    func testAccountCanSetUpNotifications() {
        XCTAssertEqual(OnboardingView.Step.facebook.next(hasAccount: true, needsNotificationPermission: true), .notifications)
    }

    func testExistingNotificationDecisionSkipsPrompt() {
        XCTAssertNil(OnboardingView.Step.facebook.next(hasAccount: true, needsNotificationPermission: false))
    }

    func testAcceptingOrSkippingNotificationsFinishes() {
        XCTAssertNil(OnboardingView.Step.notifications.next(hasAccount: true, needsNotificationPermission: true))
        XCTAssertNil(OnboardingView.Step.notifications.next(hasAccount: true, needsNotificationPermission: false))
    }
}
