import XCTest
@testable import OpenMarket

@MainActor
final class SellerAccessTests: XCTestCase {
    private var seller: SellerProfile {
        SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "Example Seller"))!
    }

    func testSignedOutTapCannotNavigateAndSuccessfulLoginResumes() async {
        var connected = false
        let access = SellerAccess(isSignedIn: { connected })
        await access.open(seller)
        XCTAssertNil(access.destination)
        XCTAssertTrue(access.showSignIn)
        let beforeLogin = await access.finishSignIn()
        XCTAssertFalse(beforeLogin)
        XCTAssertNil(access.destination)
        connected = true
        let afterLogin = await access.finishSignIn()
        XCTAssertTrue(afterLogin)
        XCTAssertEqual(access.destination, seller)
        XCTAssertFalse(access.showSignIn)
    }

    func testCancelledLoginDoesNotOpenSellerLater() async {
        var connected = false
        let access = SellerAccess(isSignedIn: { connected })
        await access.open(seller)
        access.cancelSignIn()
        connected = true
        _ = await access.finishSignIn()
        XCTAssertNil(access.destination)
        XCTAssertFalse(access.showSignIn)
    }

    func testAuthenticatedTapNavigatesWithoutLogin() async {
        let access = SellerAccess(isSignedIn: { true })
        await access.open(seller)
        XCTAssertEqual(access.destination, seller)
        XCTAssertFalse(access.showSignIn)
    }

    func testLoaderRejectsAnonymousAccessBeforeNavigation() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("QA simulator must be signed out") }
        let client = SellerProfileClient()
        do {
            _ = try await client.load(profile: seller, filter: .available)
            XCTFail("Anonymous loading must be rejected")
        } catch {
            guard case SellerInventoryError.signInRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(client.webView.url)
    }
}
