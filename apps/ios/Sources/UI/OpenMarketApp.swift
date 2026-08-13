import SwiftUI
import WebKit

/// Exists for one callback: APNs hands the device token to the app delegate and
/// nowhere else, so a SwiftUI-only app has no way to receive it.
///
/// Everything it does is forwarded to `PushRegistrar`, which owns the permission
/// and the reporting. Nothing else should accumulate here — an app delegate is a
/// grab bag by nature, and this one has a single reason to exist.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Says which backend this build is talking to, once, at launch.
    ///
    /// Two builds now install side by side with near-identical UI, so "which
    /// one am I looking at" is a real question — and the expensive version of
    /// getting it wrong is debugging a laptop's database while looking at
    /// production. One line in the console answers it before anything else
    /// happens.
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        print("[openmarket] \(Bundle.main.bundleIdentifier ?? "?") → \(API.baseURL)")
        // Here rather than in a `.task`, because PostHog's own lifecycle events
        // are the point of having it early: `$application_opened` has to be
        // captured for the launch that is happening, and a SwiftUI task runs
        // after the app is already up. It is a no-op in Debug, which ships no
        // key — see `Analytics`.
        Analytics.start()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushRegistrar.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushRegistrar.shared.didFailToRegister(error: error) }
    }
}

@main
struct OpenMarketApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ListingStore()
    @StateObject private var prefs = Preferences.shared
    @StateObject private var location = LocationProvider()
    @StateObject private var distances = DistanceResolver.shared
    @StateObject private var saved = SavedListings.shared
    @StateObject private var viewed = ViewedListings.shared
    @StateObject private var seller = SellerToolsModel()
    @StateObject private var discover = DiscoverFeed()
    /// App-level because a location switch outlives the sheet that starts it:
    /// the sheet dismisses on the tap and the results screen behind it shows
    /// the change landing (`PlaceChooser`).
    @StateObject private var chooser = PlaceChooser.shared
    /// The app's own account, distinct from the Facebook browsing session the
    /// engines use. Owned at app level because the whole UI is gated on it.
    @StateObject private var account = AccountSession.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(account)
                .environmentObject(store)
                .environmentObject(prefs)
                .environmentObject(location)
                .environmentObject(distances)
                .environmentObject(saved)
                .environmentObject(viewed)
                .environmentObject(seller)
                .environmentObject(discover)
                .environmentObject(chooser)
        }
        // Cache writes are coalesced on a 2s debounce, which is right for a
        // burst of writes and wrong for an app about to be killed. Leaving
        // the foreground is the last reliable moment to get it to disk.
        //
        // Returning to the foreground re-checks the session, because it can end
        // without the app doing anything — a password change or a Facebook-side
        // expiry — and a stale belief about being signed in would have the
        // store keying its cache under the wrong context.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task {
                    // A failed launch-time check keeps the local account signed
                    // in. Foregrounding is the natural retry point once the
                    // network or server has recovered.
                    if case .signedInOffline = account.state {
                        await account.restore()
                    }
                    let connected = await SessionState.isSignedIn()
                    store.setSession(connected ? .authed : .unauthed)
                    // The same check, reported upward. This is the one place
                    // that notices a session ending on its own — an expiry or a
                    // password change elsewhere — so it is also the one place
                    // that can tell the server the connection has lapsed.
                    // `reportFacebookConnection` dedupes, so the usual
                    // foreground costs nothing.
                    await account.reportFacebookConnection(connected)
                }
            } else {
                Task { await ListingCache.shared.writeToDisk() }
                // Same reasoning as the cache write above, applied to the event
                // queue: it flushes on a size and a timer, neither of which
                // helps a process about to be killed. The last events of a
                // session are the ones at the end of a funnel.
                Analytics.flush()
            }
        }
    }
}

/// Decides which of the three things the app can be showing: nothing yet,
/// onboarding, or the app.
///
/// Signing in is the *first step of onboarding* rather than a gate in front of
/// it. It used to be a gate, which made a first run a login screen followed by a
/// flow that started over with a welcome carousel — two beginnings for one
/// arrival. `OnboardingView` owns all four questions now and works out which one
/// is outstanding, so this view only has to decide whether any of them are.
struct RootView: View {
    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var prefs: Preferences

    /// Whether the flow is on screen. `nil` until the session check comes back.
    ///
    /// **A latch, not a derivation, and that is the whole point.** It used to be
    /// `!account.isSignedIn || prefs.needsOnboarding` recomputed on every change,
    /// which meant any answer landing early could dismiss the flow out from under
    /// the person still using it — the location step resolves a place in the
    /// background, and the moment it landed `needsOnboarding` went false and the
    /// notifications step was never shown. `openIfNeeded` can only *open* this;
    /// only `finish` closes it.
    @State private var isOnboarding: Bool?

    var body: some View {
        Group {
            // `restore()` asks the server whether the stored session is still
            // live, so there is a round trip between launch and knowing. Showing
            // the login screen during it would flash it at every user who is
            // already signed in.
            if account.state == .unknown || isOnboarding == nil {
                LaunchView()
            } else if isOnboarding == true {
                OnboardingView { finish() }
            } else {
                SignedInView()
            }
        }
        .task {
            if account.state == .unknown { await account.restore() }
        }
        .onAppear { openIfNeeded() }
        .onChange(of: prefs.needsOnboarding) { _, _ in openIfNeeded() }
        // The server is the authority on whether this account has ever been
        // onboarded, so a reinstall or a second device doesn't repeat the parts
        // that are account-shaped. The parts that are *install*-shaped — a
        // place, a Facebook cookie jar, a notification permission — are still
        // asked, because a new install genuinely has none of them.
        //
        // **Both directions, and that is a bug fix.** This used to only ever
        // set the flag true, which meant the answer belonged to whichever
        // account had last set it rather than to the account signing in. Sign a
        // brand-new user in on an install that had already onboarded — delete
        // your account and sign up again, or hand someone your phone — and the
        // server's `false` was ignored: `needsOnboarding` went false the instant
        // the session landed and tore the flow away mid-flight, straight past
        // the Facebook, location and notification steps to the home screen.
        .onChange(of: account.state) { _, state in
            if let viewer = state.viewer {
                // A different account than the one this install last saw means
                // a different person is holding the phone, and the answers that
                // are install-shaped were the last person's. Signing back into
                // the *same* account deliberately keeps them: that is routine,
                // and making somebody pick their city again for it is a
                // punishment for signing out.
                if let last = prefs.lastAccountID, last != viewer.id {
                    prefs.resetOnboarding()
                }
                prefs.lastAccountID = viewer.id
                // After the reset, so the server's answer for the account that
                // is actually signing in wins.
                prefs.hasCompletedOnboarding = viewer.onboardingCompleted
            }
            openIfNeeded()
        }
    }

    /// Opens the flow when something is outstanding, and never closes it.
    ///
    /// The one-way door is what keeps `RootView` and `OnboardingView` from
    /// disagreeing. They test different things — this one asks whether anything
    /// is missing, the flow asks which step is next — so letting both decide when
    /// to dismiss means the stricter answer wins at whatever moment it happens to
    /// change, mid-step.
    private func openIfNeeded() {
        switch account.state {
        case .unknown:
            // Nothing is known yet, and guessing here is how you flash a login
            // screen at somebody who is already signed in.
            return
        case .signedOut:
            // The phone screen is the first step, so signing out — or being
            // signed out by an expired session — starts the flow rather than
            // dropping the user somewhere with no account.
            isOnboarding = true
        case .signedIn, .signedInOffline:
            // First decision after launch settles it either way; after that this
            // can only open.
            if isOnboarding == nil {
                isOnboarding = prefs.needsOnboarding
            } else if prefs.needsOnboarding {
                isOnboarding = true
            }
        }
    }

    private func finish() {
        prefs.hasCompletedOnboarding = true
        isOnboarding = false
        // The end of the funnel, and it is fired here rather than in
        // `OnboardingView` because this is the one-way door: the flow can send
        // itself back to the location step, and only reaching this line means
        // all four questions are behind the user.
        Analytics.capture(.onboardingCompleted)
        // Recorded on the account too, so the answer survives a reinstall rather
        // than living only in this install's defaults.
        Task { await account.markOnboardingComplete() }
    }
}

/// The launch state, before the session check has come back.
private struct LaunchView: View {
    var body: some View {
        // Deliberately bare. Anything more would read as a real screen and then
        // be replaced a few hundred milliseconds later.
        Color(.systemBackground)
            .ignoresSafeArea()
            .overlay(ProgressView())
    }
}

struct SignedInView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var seller: SellerToolsModel
    @EnvironmentObject private var discover: DiscoverFeed
    @EnvironmentObject private var account: AccountSession

    var body: some View {
        ZStack {
            // Two things this app does: find what other people are selling, and
            // work out things about a listing of your own. They share a
            // location, a session and a pacer, and nothing else — which is
            // exactly what a tab boundary is for.
            TabView {
                ResultsView()
                    .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                ToolsView()
                    .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            }

            // §2.1 — the engines' webviews must be in the hierarchy or WebKit
            // throttles them. But *covering* them isn't good enough either:
            // behind an opaque view, WebKit takes a reduced rendering path and
            // parts of each card (notably the location line) never render at
            // all. So they're laid out at full size and pushed outside the
            // visible area, where WebKit still treats them as live.
            //
            // They sit beside the `TabView` rather than inside a tab for the
            // same reason. A tab that isn't selected is torn down, and Price
            // Check's search would then be running in a webview SwiftUI had
            // just removed from the hierarchy.
            HiddenWebViewHost(webView: store.desktop.webView)
                .offset(x: 3000)
            HiddenWebViewHost(webView: store.feed.webView)
                .offset(x: 3000)
            HiddenWebViewHost(webView: store.detail.webView)
                .offset(x: 3000)
            HiddenWebViewHost(webView: seller.webView)
                .offset(x: 3000)
            // One per Discover search — they run at the same time, and an
            // engine is one webview with one in-flight navigation.
            ForEach(discover.webViews, id: \.self) { webView in
                HiddenWebViewHost(webView: webView)
                    .offset(x: 3000)
            }
        }
    }
}

/// Attached, sized, and rendering — but invisible and non-interactive.
struct HiddenWebViewHost: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        // Fully live — normal opacity, interaction and scrolling all enabled —
        // because WebLite's rendering and tap handling both degrade when the
        // view is treated as inert. It stays invisible by sitting behind the
        // opaque results UI rather than by being dimmed or disabled.
        webView.isUserInteractionEnabled = true
        webView.alpha = 1
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
