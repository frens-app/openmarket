import XCTest
@testable import OpenMarket

@MainActor
final class AuthenticatedFeedTests: XCTestCase {
    func testHTTPBlocksApplySharedBackoff() async {
        for status in [403, 429] {
            let pacer = RequestPacer()
            do {
                _ = try await AuthenticatedFeedClient.decode(["status": status], kind: .browse, pacer: pacer)
                XCTFail("Expected block")
            } catch { XCTAssertEqual(error as? GraphQLFeedError, .blocked) }
            let allowed = await pacer.waitForSlot()
            XCTAssertFalse(allowed)
        }
    }

    func testNetworkFailuresDoNotBecomeBrowserFallback() async {
        for (failure, code) in [("timeout", URLError.Code.timedOut), ("network", .networkConnectionLost)] {
            do {
                _ = try await AuthenticatedFeedClient.decode(["failure": failure], kind: .browse, pacer: RequestPacer())
                XCTFail("Expected network error")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
        }
    }

    func testInvalidContextAndLoginHTMLAreNotEmptySuccessfulPages() async {
        for envelope: [String: Any] in [["failure": "context"], ["status": 200, "text": "<html>Log in</html>"]] {
            do {
                _ = try await AuthenticatedFeedClient.decode(envelope, kind: .browse, pacer: RequestPacer())
                XCTFail("Expected unsupported response")
            } catch { XCTAssertEqual(error as? GraphQLFeedError, .invalidResponse) }
        }
    }

    func testGraphQLBlocksApplySharedBackoff() async {
        let pacer = RequestPacer()
        let text = #"{"errors":[{"message":"Too many requests"}],"data":null}"#
        do {
            _ = try await AuthenticatedFeedClient.decode(["status": 200, "text": text], kind: .browse, pacer: pacer)
            XCTFail("Expected block")
        } catch { XCTAssertEqual(error as? GraphQLFeedError, .blocked) }
        let allowed = await pacer.waitForSlot()
        XCTAssertFalse(allowed)
    }
}
