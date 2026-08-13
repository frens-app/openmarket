import SwiftUI
import WebKit

/// Signing in, by handing the user Facebook's own login page.
///
/// The app has no login form and never will. It presents Facebook's real page
/// in a visible webview, the user types into that, and the app learns the
/// outcome by reading cookies afterwards — it never sees, collects, forwards or
/// stores a password. This is the only shape of sign-in this project will carry.
///
/// The session lands in `BrowserSession.authed`'s persistent store, which is a
/// different store from the anonymous one; nothing crosses between them. See
/// `docs/decision-desktop-primary.md`.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = SignInModel()

    /// For the analytics only — this sheet is offered from five places, and
    /// which prompt converts is worth knowing. Nothing here varies with it.
    let surface: Analytics.Surface

    /// Called once a session is detected, so the caller can re-run whatever the
    /// user was doing — the result set differs by authentication, not just the
    /// fields on it.
    var onSignedIn: () -> Void = {}

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isSignedIn {
                    signedIn
                } else {
                    LoginWebView(webView: model.webView)
                }
            }
            // Keyboard avoidance is WebKit's job here, and only WebKit's.
            //
            // Left to itself SwiftUI shrinks this view to sit above the
            // keyboard, while WebKit independently insets the same webview's
            // scroll view by the keyboard height — two avoidances for one
            // keyboard, so the page ends up with roughly twice the keyboard's
            // height of dead space and the focused field lands under the fold.
            // Worse, WebKit's scroll-the-field-into-view runs while the frame
            // is still animating, computes against the geometry it had a
            // moment ago, and stops short: the two-factor code box on
            // Facebook's own login stays off screen until you tap it enough
            // times that one attempt happens to land after layout settles.
            //
            // Holding the frame still leaves exactly one inset — the keyboard
            // safe area still reaches the scroll view, which is the half that
            // was always correct.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .navigationTitle(model.isSignedIn ? "Signed in" : "Sign in to Facebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.start() }
            .onChange(of: model.isSignedIn) { _, signedIn in
                guard signedIn else { return }
                // Opening this on a session that already exists is not a
                // connection — that is the ordinary Settings path.
                if model.openedWithSession != true {
                    Analytics.capture(.facebookSessionConnected, ["surface": surface.rawValue])
                }
                onSignedIn()
            }
        }
    }

    private var signedIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Signed in")
                .font(.headline)
            Text("Seller details, unlimited scrolling and Facebook's own picks are all switched on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}

private struct LoginWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView {
        // An escape hatch that doesn't depend on any of the above being right:
        // dragging down puts the keyboard away, so a field the page has hidden
        // under it is always reachable by hand.
        webView.scrollView.keyboardDismissMode = .interactive
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class SignInModel: ObservableObject {
    @Published private(set) var isSignedIn = false

    /// Whether a session already existed when this screen opened. Nil until
    /// `start` has looked — defaulting to false would credit the sheet with a
    /// connection made weeks ago.
    @Published private(set) var openedWithSession: Bool?

    let webView: WKWebView
    private var pollTask: Task<Void, Never>?

    init() {
        // The mobile user agent, deliberately: Facebook's desktop login form is
        // unusable at phone width. The cookie jar is shared across user agents,
        // so the desktop engines pick the session up afterwards.
        let config = WKWebViewConfiguration.make()
        // Born at phone size rather than `.zero`: the first layout is the one
        // Facebook picks a login form for, and a zero-width viewport is not a
        // width any of its breakpoints expect.
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 402, height: 874),
                            configuration: config)
        webView.customUserAgent = Surface.mobile.userAgent
    }

    func start() async {
        let existing = await SessionState.isSignedIn()
        // Before the published flag, so `onChange` doesn't race it.
        openedWithSession = existing
        isSignedIn = existing
        guard !isSignedIn else { return }
        webView.load(URLRequest(url: URL(string: "https://www.facebook.com/login/")!))
        beginPolling()
    }

    /// Cookies are the only reliable completion signal here.
    ///
    /// Facebook's login can finish through a redirect, a checkpoint, or a
    /// two-factor step, and watching navigations would mean predicting which —
    /// so this watches for the outcome instead: `c_user` and `xs` both present.
    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if await SessionState.isSignedIn() {
                    self.isSignedIn = true
                    return
                }
            }
        }
    }

    deinit { pollTask?.cancel() }
}
