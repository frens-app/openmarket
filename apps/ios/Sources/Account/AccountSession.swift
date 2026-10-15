import AuthenticationServices
import Connect
import Foundation
import GoogleSignIn
import OpenMarketProtos
import SwiftProtobuf
import SwiftUI

/// The signed-in account, its tokens, and its provider login.
///
/// Everything the app does against our own API goes through `headers()` here,
/// so token refresh has exactly one implementation and no call site has to
/// remember to do it.
@MainActor
final class AccountSession: ObservableObject {
    enum State: Equatable {
        /// Before `restore()` has finished. Distinct from `signedOut` because
        /// showing the login screen during it would flash it at every user who
        /// is already signed in.
        case unknown
        case signedOut
        case signedIn(Viewer)
        /// Credentials still exist, but the server could not be reached to
        /// validate them. This is signed in from the UI's point of view: an
        /// outage must not turn into a logout. The optional viewer is absent
        /// only for sessions created by an older app version, before the viewer
        /// started being cached alongside the tokens.
        case signedInOffline(Viewer?)

        var isSignedIn: Bool {
            switch self {
            case .signedIn, .signedInOffline:
                return true
            case .unknown, .signedOut:
                return false
            }
        }

        var viewer: Viewer? {
            switch self {
            case .signedIn(let viewer):
                return viewer
            case .signedInOffline(let viewer):
                return viewer
            case .unknown, .signedOut:
                return nil
            }
        }

        /// Keeps the policy independently testable: only an authoritative
        /// rejection ends a stored session. A transport/server failure merely
        /// makes the session temporarily unverified.
        static func afterFailedRestore(sessionIsInvalid: Bool, cachedViewer: Viewer?) -> State {
            sessionIsInvalid ? .signedOut : .signedInOffline(cachedViewer)
        }

        static func restoreInvalidatesSession(for code: Code) -> Bool {
            code == .unauthenticated || code == .notFound
        }
    }

    static let shared = AccountSession()

    @Published private(set) var state: State = .unknown

    /// This install, as the server sees it. Nil until a call returns one.
    ///
    /// Held separately from `state` because it has a different lifetime: the
    /// viewer follows the person to a new phone and the device does not, which
    /// is the entire reason Facebook connection is tracked here rather than on
    /// the account.
    @Published private(set) var device: Device?

    private let protocolClient: any ProtocolClientInterface

    init(protocolClient: any ProtocolClientInterface = API.makeProtocolClient()) {
        self.protocolClient = protocolClient
        defaults.removeObject(forKey: "sign_in_calling_codes")
    }
    private lazy var auth = AuthServiceClient(client: protocolClient)
    private lazy var users = UserServiceClient(client: protocolClient)

    private enum Key {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let accessExpiry = "access_token_expiry"
        static let viewer = "viewer"
        static let appleUserID = "social_apple_user_id"
    }

    private let defaults = UserDefaults.standard

    /// Refresh this far before the token actually expires, so a call that is
    /// about to be made doesn't race the expiry it just checked.
    private let refreshMargin: TimeInterval = 60

    /// In-flight refresh. Concurrent callers await the same one — refresh
    /// tokens rotate, so two simultaneous refreshes would have the loser
    /// holding a token the server has already retired.
    private var refreshTask: Task<Void, Error>?

    var isSignedIn: Bool {
        state.isSignedIn
    }

    // MARK: - Lifecycle

    /// Decides which screen the app opens on.
    ///
    /// A stored refresh token is checked with the server whenever possible: it
    /// can have been revoked from another device, or the account deleted. When
    /// the server cannot be reached, though, the local session remains signed
    /// in and is checked again on a later foreground rather than presenting an
    /// outage as a logout.
    func restore() async {
        guard Keychain.get(Key.refreshToken) != nil else {
            state = .signedOut
            return
        }
        if let userID = Keychain.get(Key.appleUserID),
           let credential = try? await ASAuthorizationAppleIDProvider().credentialState(forUserID: userID),
           credential == .revoked || credential == .notFound {
            await signOut()
            return
        }
        let cachedViewer = cachedViewer()
        do {
            let headers = try await authorizedHeaders()
            let response = await users.getViewer(request: GetViewerRequest(), headers: headers)
            switch response.result {
            case .success(let message):
                cache(viewer: message.viewer)
                state = .signedIn(message.viewer)
                if message.hasDevice { device = message.device }
                // Link but no event and no properties: nobody signed in, a
                // stored session was confirmed.
                linkAnalyticsToAccount(message.viewer)
            case .failure(let error):
                // Unauthenticated or a deleted account means the session is
                // genuinely gone. Every other error leaves the local session
                // intact: the server being unavailable is not a logout event.
                let sessionIsInvalid = State.restoreInvalidatesSession(for: error.code)
                if sessionIsInvalid {
                    clearTokens()
                }
                state = State.afterFailedRestore(
                    sessionIsInvalid: sessionIsInvalid,
                    cachedViewer: cachedViewer
                )
            }
        } catch {
            let sessionIsInvalid: Bool
            if case APIError.unauthenticated = error {
                sessionIsInvalid = true
                clearTokens()
            } else {
                sessionIsInvalid = false
            }
            state = State.afterFailedRestore(
                sessionIsInvalid: sessionIsInvalid,
                cachedViewer: cachedViewer
            )
        }
    }

    // MARK: - Signing in

    func beginSignIn(provider: SignInProvider) async throws -> String {
        var request = BeginSignInRequest()
        request.provider = provider
        request.installID = InstallIdentity.current
        let response = await auth.beginSignIn(request: request)
        switch response.result {
        case .success(let message): return message.nonce
        case .failure(let error): throw error.asAPIError
        }
    }

    @discardableResult
    func signIn(provider: SignInProvider, identityToken: String, nonce: String, appleUserID: String? = nil, names: AccountNames = AccountNames()) async throws -> Bool {
        var request = SignInRequest()
        request.provider = provider
        request.identityToken = identityToken
        if let firstName = names.firstName { request.firstName = firstName }
        if let lastName = names.lastName { request.lastName = lastName }
        if let displayName = names.displayName { request.displayName = displayName }
        request.nonce = nonce
        request.devicePlatform = .ios
        request.timeZone = TimeZone.current.identifier
        request.installID = InstallIdentity.current

        let response = await auth.signIn(request: request)
        switch response.result {
        case .success(let message):
            store(
                accessToken: message.accessToken,
                refreshToken: message.refreshToken,
                expiresIn: TimeInterval(message.accessTokenExpiresInSeconds)
            )
            if provider == .apple, let appleUserID {
                Keychain.set(appleUserID, for: Key.appleUserID)
                AppleSignInNames.clear(userID: appleUserID)
            } else {
                Keychain.delete(Key.appleUserID)
            }
            cache(viewer: message.viewer)
            state = .signedIn(message.viewer)
            if message.hasDevice { device = message.device }
            // Before the event, so the signup lands on the person's profile
            // rather than the anonymous one it replaces.
            updateAnalyticsProfile(message.viewer)
            Analytics.capture(message.isNewUser ? .accountCreated : .accountSignedIn)
            return message.isNewUser
        case .failure(let error):
            if error.code == .unauthenticated {
                throw APIError.message(error.message ?? "Couldn't verify your sign-in. Please try again.")
            }
            throw error.asAPIError
        }
    }

    var needsPhoneLink: Bool {
        guard let viewer = state.viewer else { return false }
        return viewer.signInProvider == "phone"
            || (viewer.signInProvider.isEmpty && !viewer.phoneNumber.isEmpty)
    }

    func beginLinkSignIn(provider: SignInProvider) async throws -> String {
        let headers = try await authorizedHeaders()
        var request = BeginLinkSignInRequest()
        request.provider = provider
        let response = await auth.beginLinkSignIn(request: request, headers: headers)
        switch response.result {
        case .success(let message): return message.nonce
        case .failure(let error): throw error.asAPIError
        }
    }

    func linkSignIn(provider: SignInProvider, identityToken: String, nonce: String,
                    expectedUserID: String, appleUserID: String? = nil,
                    names: AccountNames = AccountNames()) async throws {
        guard state.viewer?.id == expectedUserID else {
            throw APIError.message("Your account changed. Please reopen the link screen.")
        }
        let headers = try await authorizedHeaders()
        var request = LinkSignInRequest()
        request.provider = provider
        request.identityToken = identityToken
        request.nonce = nonce
        if let firstName = names.firstName { request.firstName = firstName }
        if let lastName = names.lastName { request.lastName = lastName }
        if let displayName = names.displayName { request.displayName = displayName }
        let response = await auth.linkSignIn(request: request, headers: headers)
        switch response.result {
        case .success(let message):
            guard state.viewer?.id == expectedUserID, message.viewer.id == expectedUserID else {
                throw APIError.message("Your account changed. Please reopen the app to refresh it.")
            }
            if provider == .apple, let appleUserID {
                Keychain.set(appleUserID, for: Key.appleUserID)
                AppleSignInNames.clear(userID: appleUserID)
            }
            // The account ID and tokens stay unchanged: no store switch,
            // onboarding reset, analytics reset, or new-account event.
            cache(viewer: message.viewer)
            state = .signedIn(message.viewer)
            updateAnalyticsProfile(message.viewer)
            Analytics.capture(.accountSignInLinked, ["sign_in_provider": message.viewer.signInProvider])
        case .failure(let error): throw error.asAPIError
        }
    }

    // MARK: - Signing out

    func signOut() async {
        // Best-effort: the session is revoked server-side if the call lands,
        // but the local tokens are dropped either way. A sign-out that fails
        // because the network is down must still sign the user out.
        if let headers = try? await authorizedHeaders() {
            _ = await auth.logout(request: LogoutRequest(), headers: headers)
        }
        clearTokens()
        state = .signedOut
        // Not the install id — that stays, so signing back in on this phone
        // finds the same device row rather than orphaning its Facebook and push
        // state behind a new one.
        device = nil
        // Before the reset, or it lands on the new anonymous id.
        Analytics.capture(.accountSignedOut)
        Analytics.reset()
    }

    func deleteAccount() async throws {
        let headers = try await authorizedHeaders()
        var request = DeleteAccountRequest()
        if state.viewer?.signInProvider == "apple" {
            guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: \.isKeyWindow) else {
                throw APIError.message("Couldn't open Apple sign-in. Please try again.")
            }
            let nonce = try await beginSignIn(provider: .apple)
            let authorization = AppleAccountAuthorization()
            let credential = try await authorization.signIn(nonce: nonce, window: window)
            request.appleIdentityToken = credential.identityToken
            request.appleAuthorizationCode = credential.authorizationCode
            request.nonce = nonce
        }
        let deletingUserID = state.viewer?.id
        let response = await users.deleteAccount(request: request, headers: headers)
        if let error = response.error, error.code != .notFound {
            throw error.asAPIError
        }
        if let deletingUserID { SavedListings.shared.deleteAccount(deletingUserID) }
        clearTokens()
        state = .signedOut
        device = nil
        Analytics.capture(.accountDeleted)
        Analytics.reset()
    }

    // MARK: - Facebook connection

    /// Tells the server whether the Facebook webview session exists **on this
    /// install**.
    ///
    /// This is a report, not a request. The state is a cookie jar in this app's
    /// own container, so the client is the only thing that can observe it — and
    /// it cannot travel: signing in to the same account on a second phone starts
    /// with it false, which is exactly the fact the server needs in order to
    /// know that person has to connect again.
    ///
    /// Deduped against what the server last told us, because the app re-checks
    /// the cookie jar on every foreground and almost every check finds nothing
    /// changed. A failed call deliberately leaves `device` alone, so the next
    /// foreground retries rather than the app deciding it has already reported.
    func reportFacebookConnection(_ connected: Bool) async {
        guard isSignedIn else { return }
        // Above the dedupe: the server only needs telling when it changes,
        // where every later event wants it stamped on.
        Analytics.register(["facebook_connected": connected])
        if let device, device.facebookConnected == connected { return }
        guard let headers = try? await authorizedHeaders() else { return }

        var request = SetFacebookConnectionRequest()
        request.connected = connected

        let response = await users.setFacebookConnection(request: request, headers: headers)
        if let message = response.message {
            device = message.device
        }
    }

    /// Reports this install's push token and whether notifications are allowed.
    ///
    /// A nil token with `granted: false` is a real report, not a no-op: the
    /// server needs to distinguish an install that declined from one that was
    /// never asked, because that is what decides whether a listing alert has any
    /// way to reach the person. The proto requires a non-empty token, so a
    /// refusal is recorded as the permission status against the empty string —
    /// there is nothing to address, which is precisely the fact being sent.
    func registerPushToken(_ token: String?, granted: Bool) async {
        guard isSignedIn else { return }
        guard let headers = try? await authorizedHeaders() else { return }

        var request = RegisterDeviceTokenRequest()
        request.pushToken = token ?? ""
        request.permissionStatus = granted ? .enabled : .disabled

        // Fire and forget. A failure here costs a push that would have been
        // nice to send, and retrying it is the next launch's job — never
        // something that should block or fail the screen the user is on.
        _ = await users.registerDeviceToken(request: request, headers: headers)
    }

    // MARK: - Profile

    /// Marks onboarding complete server-side.
    ///
    /// The flag lives on the account rather than only in `Preferences` so a
    /// reinstall, or a second device, doesn't walk the user through onboarding
    /// again.
    func markOnboardingComplete() async {
        guard isSignedIn else { return }
        var request = UpdateViewerRequest()
        request.onboardingCompleted = true
        guard let headers = try? await authorizedHeaders() else { return }
        let response = await users.updateViewer(request: request, headers: headers)
        if let message = response.message {
            cache(viewer: message.viewer)
            state = .signedIn(message.viewer)
            // So `onboarding_completed` follows the account. Once per account:
            // the flag only ever goes true.
            updateAnalyticsProfile(message.viewer)
        }
    }

    // MARK: - Analytics

    /// Points this session's events at the account, and nothing else.
    ///
    /// **No person properties, deliberately.** PostHog dedupes repeated property
    /// writes against an in-memory hash that a relaunch clears, so passing them
    /// here would bill a `$set` on every cold launch to restate a flag that
    /// hasn't changed since signup. With none, an already-identified call is
    /// free.
    private func linkAnalyticsToAccount(_ viewer: Viewer) {
        Analytics.identify(userID: viewer.id)
    }

    /// The link plus the profile, for the two moments the properties change.
    ///
    /// Keyed on the server's user id, not `InstallIdentity`, which a reinstall
    /// wipes. No phone number — the user id answers everything it could.
    /// `createdAt` is `setOnce` so a later sign-in can't move somebody's cohort.
    private func updateAnalyticsProfile(_ viewer: Viewer) {
        var properties: [String: Any] = ["onboarding_completed": viewer.onboardingCompleted]
        let fallbackName = [viewer.firstName, viewer.lastName]
            .compactMap { Analytics.text($0, limit: 256) }
            .joined(separator: " ")
        if let name = Analytics.text(viewer.displayName, limit: 512)
            ?? Analytics.text(fallbackName, limit: 512) {
            properties["name"] = name
        }
        Analytics.identify(
            userID: viewer.id,
            properties: properties,
            setOnce: viewer.createdAt.isEmpty ? [:] : ["account_created_at": viewer.createdAt]
        )
    }

    // MARK: - Tokens

    /// The Authorization header for an authenticated call, refreshed if the
    /// current access token is at or near expiry.
    func authorizedHeaders() async throws -> Headers {
        if needsRefresh {
            try await refreshIfNeeded()
        }
        guard let token = Keychain.get(Key.accessToken) else {
            throw APIError.unauthenticated
        }
        return ["Authorization": ["Bearer \(token)"]]
    }

    private var needsRefresh: Bool {
        guard Keychain.get(Key.accessToken) != nil,
              let raw = Keychain.get(Key.accessExpiry),
              let expiry = TimeInterval(raw)
        else { return true }
        return Date().timeIntervalSince1970 + refreshMargin >= expiry
    }

    private func refreshIfNeeded() async throws {
        if let existing = refreshTask {
            try await existing.value
            return
        }
        let task = Task { try await performRefresh() }
        refreshTask = task
        defer { refreshTask = nil }
        try await task.value
    }

    private func performRefresh() async throws {
        guard let refreshToken = Keychain.get(Key.refreshToken) else {
            throw APIError.unauthenticated
        }
        var request = RefreshTokenRequest()
        request.refreshToken = refreshToken

        let response = await auth.refreshToken(request: request)
        switch response.result {
        case .success(let message):
            store(
                accessToken: message.accessToken,
                refreshToken: message.refreshToken,
                expiresIn: TimeInterval(message.accessTokenExpiresInSeconds)
            )
        case .failure(let error):
            if error.code == .unauthenticated {
                clearTokens()
                state = .signedOut
                throw APIError.unauthenticated
            }
            throw error.asAPIError
        }
    }

    private func store(accessToken: String, refreshToken: String, expiresIn: TimeInterval) {
        // A server that sends no lifetime gets treated as a very short one
        // rather than an infinite one: refreshing too often is a wasted
        // request, never refreshing is a session that dies mid-use.
        let lifetime = expiresIn > 0 ? expiresIn : 60
        Keychain.set(accessToken, for: Key.accessToken)
        Keychain.set(refreshToken, for: Key.refreshToken)
        Keychain.set(String(Date().timeIntervalSince1970 + lifetime), for: Key.accessExpiry)
    }

    private func cache(viewer: Viewer) {
        guard let data = try? viewer.serializedData() else { return }
        Keychain.set(data.base64EncodedString(), for: Key.viewer)
    }

    private func cachedViewer() -> Viewer? {
        guard let encoded = Keychain.get(Key.viewer),
              let data = Data(base64Encoded: encoded)
        else { return nil }
        return try? Viewer(serializedBytes: data)
    }

    private func clearTokens() {
        GIDSignIn.sharedInstance.signOut()
        Keychain.delete(Key.accessToken)
        Keychain.delete(Key.refreshToken)
        Keychain.delete(Key.accessExpiry)
        Keychain.delete(Key.viewer)
        Keychain.delete(Key.appleUserID)
    }
}
