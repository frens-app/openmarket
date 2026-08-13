import Connect
import OpenMarketProtos
import XCTest
@testable import OpenMarket

@MainActor
final class AccountSessionTests: XCTestCase {
    func testOnlyAuthoritativeServerResponsesInvalidateSession() {
        XCTAssertFalse(AccountSession.State.restoreInvalidatesSession(for: .unavailable))
        XCTAssertFalse(AccountSession.State.restoreInvalidatesSession(for: .internalError))
        XCTAssertTrue(AccountSession.State.restoreInvalidatesSession(for: .unauthenticated))
        XCTAssertTrue(AccountSession.State.restoreInvalidatesSession(for: .notFound))
    }

    func testFailedRestoreKeepsStoredSessionSignedIn() {
        var viewer = Viewer()
        viewer.id = "viewer-1"

        let state = AccountSession.State.afterFailedRestore(
            sessionIsInvalid: false,
            cachedViewer: viewer
        )

        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state.viewer?.id, "viewer-1")
        XCTAssertEqual(state, .signedInOffline(viewer))
    }

    func testFailedRestoreSupportsSessionsCreatedBeforeViewerCaching() {
        let state = AccountSession.State.afterFailedRestore(
            sessionIsInvalid: false,
            cachedViewer: nil
        )

        XCTAssertTrue(state.isSignedIn)
        XCTAssertEqual(state, .signedInOffline(nil))
    }

    func testAuthoritativeRejectionSignsStoredSessionOut() {
        let state = AccountSession.State.afterFailedRestore(
            sessionIsInvalid: true,
            cachedViewer: Viewer()
        )

        XCTAssertFalse(state.isSignedIn)
        XCTAssertEqual(state, .signedOut)
    }
}
