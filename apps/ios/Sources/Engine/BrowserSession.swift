import Foundation
import WebKit

/// Which auth state a piece of data came from.
///
/// **This is a label, not a sandbox.** It used to be both: `authed` and
/// `unauthed` selected different `WKWebsiteDataStore`s that shared nothing, so
/// anonymous browsing left no persistent trace. That split is gone, and it is
/// worth being clear about why, because it was a deliberate design decision
/// being reversed rather than a simplification.
///
/// It was buying less than it looked. Every user-facing engine already
/// defaulted to `.authed`, so all searching and detail-fetching ran on the
/// persistent store whether or not anyone was signed in — `.authed` was simply
/// "the store", empty of cookies when logged out. The isolation was real only
/// for the one webview that used `.unauthed`, the place resolver.
///
/// And there it was actively harmful. Facebook keeps the coordinate fed to its
/// location picker in **session state**, not in the URL, and ranks results by
/// proximity to it — two ends of Manhattan share ~36% of their results from a
/// byte-identical URL (`docs/location.md` §5). Resolving in a throwaway store
/// meant that state was discarded seconds after it was established, so the app
/// paid ten seconds for a city slug and threw the precision away.
///
/// What isolation bought was also weaker than it appeared: same IP, same
/// device, same user agent. A separate cookie jar prevents cookie linkage, not
/// identification.
///
/// The label survives because it does a second, unrelated job that is still
/// worth doing: `ListingCache` refuses to serve results captured in one auth
/// state to the other. Signed-in results carry seller identity and logged-out
/// ones cannot, so serving one as the other would be a real bug.
///
/// See `docs/decision-desktop-primary.md` and `docs/location.md` §5.
enum BrowserSession: String, CaseIterable, Codable, Sendable {
    case authed
    case unauthed

    /// The one store. Process-wide and persistent, so a session obtained in the
    /// visible login webview is usable by the engines afterwards — and so is
    /// whatever server-side state Facebook associates with it.
    ///
    /// Persistence is inherent to having a session at all: it has to survive
    /// relaunches or the user signs in on every cold start. Everything the app
    /// stores here is discarded by `SessionState.signOut()`.
    static var dataStore: WKWebsiteDataStore { .default() }
}

/// Which Facebook surface a webview is pretending to be.
///
/// The server keys purely off the UA string, and the two surfaces expose
/// genuinely different data — see `docs/surface-strategy.md`.
enum Surface: String, Codable, Sendable {
    /// Filters, sorting, listing ids, and the embedded GraphQL payload.
    case desktop
    /// WebLite. Paginates indefinitely; no filters, no payload, no ids.
    case mobile

    var userAgent: String {
        switch self {
        case .desktop:
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.7 Safari/605.1.15"
        case .mobile:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1"
        }
    }
}

extension WKWebViewConfiguration {
    /// Builds a configuration on the app's single web store.
    ///
    /// Takes no session argument on purpose: there is one store now, and a
    /// parameter that no longer changes anything is worse than none — it reads
    /// like a choice being made.
    static func make() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = BrowserSession.dataStore
        config.allowsInlineMediaPlayback = true
        config.suppressesIncrementalRendering = false
        return config
    }
}

/// Reads and clears the signed-in session.
///
/// Deliberately has no way to *create* one: signing in happens in a visible
/// webview against Facebook's own login page, so the app never sees, collects,
/// or stores a password. This type only observes the result.
@MainActor
enum SessionState {
    /// Facebook sets `c_user` (the account id) and `xs` (the session) on a
    /// successful login. Both present is the cheapest reliable signal, and it
    /// needs no request of our own.
    ///
    /// **An empty jar on a cold start means "not loaded yet", not "signed
    /// out".** `allCookies()` answers before WebKit has finished reading its
    /// store off disk, and the answer it gives is an empty array. Observed:
    /// Discover asked at launch+0.5s, got false, and built the signed-out feed
    /// for a signed-in account; the scene-phase check 400ms later on the same
    /// launch got `authed` from the identical call.
    ///
    /// So an *entirely* empty jar is retried, and anything else is trusted
    /// immediately. That split is what keeps this cheap: a signed-out user who
    /// has ever loaded Facebook still has `datr` and `sb`, so they answer on the
    /// first pass. Only a genuinely fresh install waits, once, for a deadline it
    /// will always hit.
    static func isSignedIn(settleFor timeout: Duration = .milliseconds(1500)) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            let cookies = await BrowserSession.dataStore.httpCookieStore.allCookies()
            if !cookies.isEmpty || ContinuousClock.now >= deadline {
                let facebook = cookies.filter { $0.domain.contains("facebook.com") }
                return facebook.contains { $0.name == "c_user" }
                    && facebook.contains { $0.name == "xs" }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Signs out by discarding the store's contents.
    ///
    /// Everything the app ever stored lives here, so this is the whole of "log
    /// out" and there is no server call to make. Now that there is only one
    /// store, this also clears anonymous browsing state and whatever location
    /// the picker established — which is the right behaviour, since neither
    /// should outlive the session it was set in.
    static func signOut() async {
        let store = BrowserSession.dataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
