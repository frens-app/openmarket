import Connect
import Foundation
import OpenMarketProtos
import SwiftUI

/// The signed-in account: tokens, the viewer, and the two calls that get you
/// one.
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

    private let protocolClient = API.makeProtocolClient()
    private lazy var auth = AuthServiceClient(client: protocolClient)
    private lazy var users = UserServiceClient(client: protocolClient)

    private enum Key {
        static let accessToken = "access_token"
        static let refreshToken = "refresh_token"
        static let accessExpiry = "access_token_expiry"
    }

    /// Refresh this far before the token actually expires, so a call that is
    /// about to be made doesn't race the expiry it just checked.
    private let refreshMargin: TimeInterval = 60

    /// In-flight refresh. Concurrent callers await the same one — refresh
    /// tokens rotate, so two simultaneous refreshes would have the loser
    /// holding a token the server has already retired.
    private var refreshTask: Task<Void, Error>?

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Decides which screen the app opens on.
    ///
    /// A stored refresh token is not proof of a live session — it can have been
    /// revoked from another device, or the account deleted — so this asks the
    /// server rather than trusting the keychain.
    func restore() async {
        guard Keychain.get(Key.refreshToken) != nil else {
            state = .signedOut
            return
        }
        do {
            let headers = try await authorizedHeaders()
            let response = await users.getViewer(request: GetViewerRequest(), headers: headers)
            switch response.result {
            case .success(let message):
                state = .signedIn(message.viewer)
                if message.hasDevice { device = message.device }
            case .failure(let error):
                // Unauthenticated or a deleted account means the session is
                // genuinely gone. A network failure does not, but there is
                // nothing to show without a viewer either, so both land on the
                // login screen — the difference is that only the first one
                // clears the tokens.
                if error.code == .unauthenticated || error.code == .notFound {
                    clearTokens()
                }
                state = .signedOut
            }
        } catch {
            if case APIError.unauthenticated = error { clearTokens() }
            state = .signedOut
        }
    }

    // MARK: - Signing in

    /// Sends a code. Returns how many digits to expect and how long until a
    /// resend is allowed, both decided by the server.
    func startVerification(phoneNumber: String) async throws -> (codeLength: Int, resendAfter: Int) {
        var request = StartPhoneVerificationRequest()
        request.phoneNumber = phoneNumber
        request.devicePlatform = .ios
        // Not stored anywhere at this point — no account exists yet. It goes to
        // the verification provider as an anti-fraud signal, which is how a real
        // install asking about one number is told apart from a script walking a
        // range. `verify(phoneNumber:code:)` sends the same value again, and
        // that call is the one that persists it.
        request.installID = InstallIdentity.current

        let response = await auth.startPhoneVerification(request: request)
        switch response.result {
        case .success(let message):
            return (
                codeLength: message.codeLength > 0 ? Int(message.codeLength) : 6,
                resendAfter: Int(message.resendAvailableInSeconds)
            )
        case .failure(let error):
            throw error.asAPIError
        }
    }

    /// Exchanges a code for a session. Returns true if this call created the
    /// account, which is what decides whether onboarding runs.
    @discardableResult
    func verify(phoneNumber: String, code: String) async throws -> Bool {
        var request = VerifyPhoneRequest()
        request.phoneNumber = phoneNumber
        request.code = code
        request.devicePlatform = .ios
        request.timeZone = TimeZone.current.identifier
        // The only call that *stores* it: the session records which install it
        // belongs to, and every later RPC derives the device from the session.
        // startVerification sends the same value, but purely as a provider
        // signal — it has no account to attach it to.
        request.installID = InstallIdentity.current

        let response = await auth.verifyPhone(request: request)
        switch response.result {
        case .success(let message):
            store(
                accessToken: message.accessToken,
                refreshToken: message.refreshToken,
                expiresIn: TimeInterval(message.accessTokenExpiresInSeconds)
            )
            state = .signedIn(message.viewer)
            if message.hasDevice { device = message.device }
            return message.isNewUser
        case .failure(let error):
            // On this call `unauthenticated` means "wrong code", not "your
            // session ended" — mapping it the usual way would tell the user
            // their session expired while they are in the middle of creating
            // one.
            if error.code == .unauthenticated {
                throw APIError.message(error.message ?? "That code isn't right.")
            }
            throw error.asAPIError
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
    }

    func deleteAccount() async throws {
        let headers = try await authorizedHeaders()
        let response = await users.deleteAccount(request: DeleteAccountRequest(), headers: headers)
        if let error = response.error, error.code != .notFound {
            throw error.asAPIError
        }
        clearTokens()
        state = .signedOut
        device = nil
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
    /// never asked, because that is what decides whether a price alert has any
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
            state = .signedIn(message.viewer)
        }
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

    private func clearTokens() {
        Keychain.delete(Key.accessToken)
        Keychain.delete(Key.refreshToken)
        Keychain.delete(Key.accessExpiry)
    }
}
