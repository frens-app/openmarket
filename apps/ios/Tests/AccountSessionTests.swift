import Connect
import WebKit
import OpenMarketProtos
import XCTest
@testable import OpenMarket

@MainActor
final class AccountSessionTests: XCTestCase {
    private func preserveSessionKeys() {
        let keys = ["access_token", "refresh_token", "access_token_expiry", "viewer",
                    "social_apple_user_id", "install_id"]
        let saved = keys.map { ($0, Keychain.get($0)) }
        for key in keys { Keychain.delete(key) }
        addTeardownBlock {
            for (key, value) in saved {
                if let value { Keychain.set(value, for: key) }
                else { Keychain.delete(key) }
            }
        }
    }

    private func storedPhoneViewer() throws -> Viewer {
        var viewer = Viewer()
        viewer.id = "phone-user"
        viewer.phoneNumber = "+15005550100"
        viewer.onboardingCompleted = true
        Keychain.set("phone-access", for: "access_token")
        Keychain.set("phone-refresh", for: "refresh_token")
        Keychain.set(String(Date().addingTimeInterval(3600).timeIntervalSince1970), for: "access_token_expiry")
        Keychain.set(try viewer.serializedData().base64EncodedString(), for: "viewer")
        Keychain.set("existing-install", for: "install_id")
        return viewer
    }

    private func session(host: String) -> AccountSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhoneSessionURLProtocol.self]
        return AccountSession(protocolClient: ProtocolClient(
            httpClient: URLSessionHTTPClient(configuration: configuration),
            config: ProtocolClientConfig(host: "https://\(host)", networkProtocol: .connect, codec: JSONCodec())
        ))
    }

    func testPhoneUpgradeRetainsCachedSessionOfflineAndFacebookCookies() async throws {
        preserveSessionKeys()
        let viewer = try storedPhoneViewer()
        let store = BrowserSession.dataStore.httpCookieStore
        let previousCookies = await store.allCookies().filter { $0.name == "c_user" || $0.name == "xs" }
        var testCookies: [HTTPCookie] = []
        for (name, value) in [("c_user", "123456789"), ("xs", "test-facebook-session")] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [
                .domain: ".facebook.com", .path: "/", .name: name, .value: value,
                .expires: Date().addingTimeInterval(3600)
            ]))
            testCookies.append(cookie)
            await store.setCookie(cookie)
        }
        let cookiesToRemove = testCookies
        addTeardownBlock { @MainActor in
            for cookie in cookiesToRemove { await store.deleteCookie(cookie) }
            for cookie in previousCookies { await store.setCookie(cookie) }
        }
        let session = session(host: "offline.test")
        await session.restore()
        XCTAssertEqual(session.state, .signedInOffline(viewer))
        XCTAssertEqual(Keychain.get("access_token"), "phone-access")
        XCTAssertEqual(Keychain.get("refresh_token"), "phone-refresh")
        XCTAssertEqual(Keychain.get("install_id"), "existing-install")
        XCTAssertEqual(session.state.viewer?.onboardingCompleted, true)
        let facebookConnected = await SessionState.isSignedIn(settleFor: .zero)
        XCTAssertTrue(facebookConnected)
        let remainingCookies = await store.allCookies()
        for cookie in testCookies {
            XCTAssertTrue(remainingCookies.contains { $0.name == cookie.name && $0.value == cookie.value })
        }
    }

    func testPhoneUpgradeRefreshesLegacyKeysAndRestoresSameAccount() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        Keychain.set("0", for: "access_token_expiry")
        let session = session(host: "online.test")
        await session.restore()
        XCTAssertTrue(session.isSignedIn)
        XCTAssertEqual(session.state.viewer?.id, "phone-user")
        XCTAssertEqual(session.state.viewer?.phoneNumber, "+15005550100")
        XCTAssertEqual(session.state.viewer?.signInProvider, "phone")
        XCTAssertEqual(session.state.viewer?.onboardingCompleted, true)
        XCTAssertEqual(Keychain.get("access_token"), "refreshed-access")
        XCTAssertEqual(Keychain.get("refresh_token"), "refreshed-refresh")
        XCTAssertEqual(session.device?.facebookConnected, true)
    }

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

private final class PhoneSessionURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host != "offline.test" else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let json: String
        if request.url?.path.hasSuffix("/RefreshToken") == true {
            json = #"{"accessToken":"refreshed-access","refreshToken":"refreshed-refresh","accessTokenExpiresInSeconds":3600}"#
        } else if request.url?.path.hasSuffix("/GetViewer") == true && request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-access" {
            json = #"{"viewer":{"id":"phone-user","phoneNumber":"+15005550100","signInProvider":"phone","onboardingCompleted":true},"device":{"id":"phone-device","facebookConnected":true}}"#
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
