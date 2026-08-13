import UIKit
import UserNotifications

/// The notification permission, and the APNs token that follows a yes.
///
/// Two separate things happen here and it is worth keeping them apart, because
/// only the first is visible to the user and only the second can fail for
/// reasons nobody can act on:
///
/// 1. **Authorization** — the system prompt. One shot per install: iOS shows it
///    once and every later request returns the stored answer without displaying
///    anything. That is why onboarding asks *for* it on a screen of our own
///    first, rather than firing the system alert at a cold audience.
/// 2. **Registration** — asking APNs for a device token, which arrives
///    asynchronously at the app delegate and is forwarded to the server.
///
/// A denied prompt still reports upward. The server wants to know that this
/// install has notifications off, not merely that it never heard about one —
/// the difference decides whether a price alert has any way to reach somebody.
@MainActor
final class PushRegistrar: ObservableObject {
    static let shared = PushRegistrar()

    /// Mirrors the system's own state, refreshed on demand rather than cached
    /// across launches — Settings is outside the app and can change it at any
    /// time, so a stored copy would be a guess.
    @Published private(set) var status: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    /// Asks the system, returning whether notifications can now be delivered.
    ///
    /// Registration is kicked off on a yes and deliberately not awaited: the
    /// token comes back through the app delegate whenever APNs answers, which
    /// may be after this returns and may — on a simulator, or with no network —
    /// never happen at all. Onboarding must not hold a button on that.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        await refreshStatus()

        // Here, not the onboarding screen: this is the only place that knows
        // what the system said, and iOS asks once per install.
        Analytics.capture(.notificationPermissionAnswered, ["granted": granted])

        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        } else {
            // Reported even though there is no token, so the server can tell a
            // device that said no from one that was never asked.
            await AccountSession.shared.registerPushToken(nil, granted: false)
        }
        return granted
    }

    func refreshStatus() async {
        status = await center.notificationSettings().authorizationStatus
    }

    /// Called by the app delegate when APNs hands over a token.
    func didRegister(deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AccountSession.shared.registerPushToken(token, granted: true) }
    }

    /// Called by the app delegate when APNs refuses.
    ///
    /// Nothing the user can act on, so nothing is shown — but the permission is
    /// still reported, with no token. Staying silent here would leave the server
    /// unable to tell this device from one that was never asked, when in fact
    /// the person said yes and only the address is missing. The next launch
    /// retries registration and fills it in.
    func didFailToRegister(error: Error) {
        print("[push] APNs registration failed: \(error.localizedDescription)")
        Task { await AccountSession.shared.registerPushToken(nil, granted: status == .authorized) }
    }
}
