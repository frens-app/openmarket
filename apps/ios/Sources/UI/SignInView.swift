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
                    explanation
                    LoginWebView(webView: model.webView)
                }
            }
            .navigationTitle(model.isSignedIn ? "Signed in" : "Sign in to Facebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await model.start() }
            .onChange(of: model.isSignedIn) { _, signedIn in
                if signedIn { onSignedIn() }
            }
        }
    }

    /// Says plainly what signing in buys and what it costs, because the honest
    /// answer to "why does a browsing app want my Facebook account" is neither
    /// obvious nor trivial.
    private var explanation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You'll sign in on Facebook's own page below.")
                .font(.subheadline.weight(.medium))
            Text("Signing in adds seller names and ratings, lets results keep loading past the first page, and builds the home screen from Facebook's own picks. This app has no login form of its own and never sees your password.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
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
            Button(role: .destructive) {
                Task { await model.signOut() }
            } label: {
                Text("Sign out")
            }
            .buttonStyle(.bordered)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 60)
    }
}

private struct LoginWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
final class SignInModel: ObservableObject {
    @Published private(set) var isSignedIn = false

    let webView: WKWebView
    private var pollTask: Task<Void, Never>?

    init() {
        // The mobile user agent, deliberately: Facebook's desktop login form is
        // unusable at phone width. The cookie jar is shared across user agents,
        // so the desktop engines pick the session up afterwards.
        let config = WKWebViewConfiguration.make()
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Surface.mobile.userAgent
    }

    func start() async {
        isSignedIn = await SessionState.isSignedIn()
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

    func signOut() async {
        await SessionState.signOut()
        isSignedIn = false
        webView.load(URLRequest(url: URL(string: "https://www.facebook.com/login/")!))
        beginPolling()
    }

    deinit { pollTask?.cancel() }
}
