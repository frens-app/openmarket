import SwiftUI
import WebKit

@main
struct OpenMarketApp: App {
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
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
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
                Task { store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed) }
            } else {
                Task { await ListingCache.shared.writeToDisk() }
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var seller: SellerToolsModel
    @EnvironmentObject private var discover: DiscoverFeed

    var body: some View {
        ZStack {
            // Two things this app does: find what other people are selling, and
            // work out how to sell your own. They share a location, a session
            // and a pacer, and nothing else — which is exactly what a tab
            // boundary is for.
            TabView {
                ResultsView()
                    .tabItem { Label("Browse", systemImage: "magnifyingglass") }
                SellerToolsView()
                    .tabItem { Label("Seller", systemImage: "tag") }
            }

            // §2.1 — the engines' webviews must be in the hierarchy or WebKit
            // throttles them. But *covering* them isn't good enough either:
            // behind an opaque view, WebKit takes a reduced rendering path and
            // parts of each card (notably the location line) never render at
            // all. So they're laid out at full size and pushed outside the
            // visible area, where WebKit still treats them as live.
            //
            // They sit beside the `TabView` rather than inside a tab for the
            // same reason. A tab that isn't selected is torn down, and the
            // seller tab's search would then be running in a webview SwiftUI
            // had just removed from the hierarchy.
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
        // Onboarding asks for two things the app cannot work without — a place
        // to search, and enough interests to build a first home screen from —
        // so it is a gate rather than a greeting. The binding is read-only for
        // that reason: nothing dismisses this except `done`, which stores the
        // answers and takes `needsOnboarding` false.
        .fullScreenCover(isPresented: .init(
            get: { prefs.needsOnboarding },
            set: { _ in }
        )) {
            OnboardingView { prefs.hasCompletedOnboarding = true }
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
