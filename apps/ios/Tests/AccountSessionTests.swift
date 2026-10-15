import SwiftUI
import PostHog
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

    func testLinkPreservesAccountTokensDeviceAndAnalyticsIdentity() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        Keychain.set("0", for: "access_token_expiry")
        let session = session(host: "online.test")
        await session.restore()
        XCTAssertTrue(session.needsPhoneLink)
        let originalViewer = try XCTUnwrap(session.state.viewer)
        let originalDevice = session.device
        let analyticsID = PostHogSDK.shared.getDistinctId()
        let nonce = try await session.beginLinkSignIn(provider: .google)
        try await session.linkSignIn(provider: .google, identityToken: "google-token", nonce: nonce,
                                     expectedUserID: originalViewer.id)
        XCTAssertFalse(session.needsPhoneLink)
        XCTAssertEqual(session.state.viewer?.id, originalViewer.id)
        XCTAssertEqual(session.state.viewer?.onboardingCompleted, originalViewer.onboardingCompleted)
        XCTAssertEqual(session.state.viewer?.signInProvider, "google")
        XCTAssertEqual(session.device, originalDevice)
        XCTAssertEqual(Keychain.get("access_token"), "refreshed-access")
        XCTAssertEqual(Keychain.get("refresh_token"), "refreshed-refresh")
        XCTAssertEqual(Keychain.get("install_id"), "existing-install")
        XCTAssertEqual(PostHogSDK.shared.getDistinctId(), analyticsID)
        let encoded = try XCTUnwrap(Keychain.get("viewer"))
        let cached = try Viewer(serializedBytes: XCTUnwrap(Data(base64Encoded: encoded)))
        XCTAssertEqual(cached.id, originalViewer.id)
        XCTAssertEqual(cached.signInProvider, "google")
    }

    func testAppleLinkKeepsAccountAndStoresCredentialStateIdentifier() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        Keychain.set("0", for: "access_token_expiry")
        let session = session(host: "apple.test")
        await session.restore()
        try await session.linkSignIn(provider: .apple, identityToken: "apple-token", nonce: "nonce",
                                     expectedUserID: "phone-user", appleUserID: "apple-user")
        XCTAssertEqual(session.state.viewer?.id, "phone-user")
        XCTAssertEqual(session.state.viewer?.signInProvider, "apple")
        XCTAssertEqual(Keychain.get("social_apple_user_id"), "apple-user")
        XCTAssertEqual(Keychain.get("refresh_token"), "refreshed-refresh")
        XCTAssertFalse(session.needsPhoneLink)
    }

    func testLinkPersistsProviderAndSeparateNamesAcrossOfflineRestart() async throws {
        preserveSessionKeys()
        for (provider, host, providerName) in [(SignInProvider.google, "online.test", "google"),
                                              (SignInProvider.apple, "apple.test", "apple")] {
            _ = try storedPhoneViewer()
            Keychain.set("0", for: "access_token_expiry")
            let account = session(host: host)
            await account.restore()
            let names = AccountNames(firstName: "Alex", lastName: "Rivera", displayName: "Alex R.")
            try await account.linkSignIn(provider: provider, identityToken: "provider-token", nonce: "nonce",
                                        expectedUserID: "phone-user", names: names)

            let linked = try XCTUnwrap(account.state.viewer)
            XCTAssertEqual(linked.id, "phone-user")
            XCTAssertEqual(linked.signInProvider, providerName)
            XCTAssertEqual(linked.firstName, "Alex")
            XCTAssertEqual(linked.lastName, "Rivera")
            XCTAssertEqual(linked.displayName, "Alex R.")
            let encoded = try XCTUnwrap(Keychain.get("viewer"))
            let cached = try Viewer(serializedBytes: XCTUnwrap(Data(base64Encoded: encoded)))
            XCTAssertEqual(cached, linked)

            let restarted = session(host: "offline.test")
            await restarted.restore()
            XCTAssertEqual(restarted.state, .signedInOffline(linked))
            XCTAssertFalse(restarted.needsPhoneLink)
        }
    }

    func testLinkConflictKeepsPhoneSessionAndShowsServerExplanation() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        Keychain.set("0", for: "access_token_expiry")
        let session = session(host: "conflict.test")
        await session.restore()
        do {
            try await session.linkSignIn(provider: .google, identityToken: "google-token", nonce: "nonce",
                                         expectedUserID: "phone-user")
            XCTFail("Expected conflict")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("already belongs to another"))
        }
        XCTAssertTrue(session.needsPhoneLink)
        XCTAssertEqual(session.state.viewer?.id, "phone-user")
        XCTAssertEqual(Keychain.get("refresh_token"), "refreshed-refresh")
    }

    func testBannerOnlyAppearsForKnownPhoneSessionsIncludingLegacyOfflineCache() async throws {
        preserveSessionKeys()
        let session = session(host: "offline.test")
        await session.restore()
        XCTAssertEqual(session.state, .signedOut)
        XCTAssertFalse(session.needsPhoneLink)
        _ = try storedPhoneViewer()
        await session.restore()
        XCTAssertTrue(session.needsPhoneLink)
        for provider in ["apple", "google"] {
            var viewer = try storedPhoneViewer()
            viewer.signInProvider = provider
            viewer.phoneNumber = ""
            Keychain.set(try viewer.serializedData().base64EncodedString(), for: "viewer")
            await session.restore()
            XCTAssertTrue(session.isSignedIn)
            XCTAssertFalse(session.needsPhoneLink)
        }
        Keychain.delete("viewer")
        await session.restore()
        XCTAssertTrue(session.isSignedIn)
        XCTAssertFalse(session.needsPhoneLink)
    }

    func testLinkRejectsAccountChangedDuringProviderAuthorization() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        let session = session(host: "offline.test")
        await session.restore()
        do {
            try await session.linkSignIn(provider: .google, identityToken: "token", nonce: "nonce",
                                         expectedUserID: "different-user")
            XCTFail("Expected account mismatch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("account changed"))
        }
        XCTAssertTrue(session.needsPhoneLink)
    }

    func testLinkingScreensRender() async throws {
        let banner = ImageRenderer(content: PhoneAccountLinkBanner {}.padding(12)
            .frame(width: 393).background(Color(.systemBackground)))
        let bannerAttachment = XCTAttachment(image: try XCTUnwrap(banner.uiImage))
        bannerAttachment.name = "Link account banner"
        bannerAttachment.lifetime = .keepAlways
        add(bannerAttachment)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: NavigationStack { AccountLoginView(isLinking: true) })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Link account screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testPhoneLinkBannerOnDiscoverScreenRenders() async throws {
        preserveSessionKeys()
        _ = try storedPhoneViewer()
        let account = session(host: "offline.test")
        await account.restore()
        let suite = "AccountSessionTests.Discover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: ResultsView()
            .environmentObject(account)
            .environmentObject(ListingStore())
            .environmentObject(prefs)
            .environmentObject(LocationProvider())
            .environmentObject(DistanceResolver(defaults: defaults))
            .environmentObject(SavedListings(defaults: defaults))
            .environmentObject(ViewedListings(defaults: defaults))
            .environmentObject(DiscoverFeed(prefs: prefs)))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "Discover with phone account link banner"
        attachment.lifetime = .keepAlways
        add(attachment)
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
        } else if request.url?.path.hasSuffix("/BeginLinkSignIn") == true {
            json = #"{"nonce":"link-nonce"}"#
        } else if request.url?.path.hasSuffix("/LinkSignIn") == true {
            if request.url?.host == "conflict.test" {
                let response = HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil,
                                               headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(#"{"code":"already_exists","message":"That Google login already belongs to another Openmarket account."}"#.utf8))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            let provider = request.url?.host == "apple.test" ? "apple" : "google"
            do {
                var body = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                        if count == 0 { break }
                        body.append(contentsOf: buffer.prefix(count))
                    }
                }
                let fields = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                var viewer: [String: Any] = ["id": "phone-user", "signInProvider": provider, "onboardingCompleted": true]
                for field in ["firstName", "lastName", "displayName"] {
                    viewer[field] = fields[field]
                }
                json = String(decoding: try JSONSerialization.data(withJSONObject: ["viewer": viewer]), as: UTF8.self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
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
