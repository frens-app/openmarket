import Foundation

/// A stable id for this installation of the app.
///
/// It exists to give install-scoped state — the Facebook webview session, the
/// APNs token — something to hang off on the server. Not a user id and not a
/// device fingerprint: it is generated locally, means nothing to anyone else,
/// and is only ever sent alongside a login the user just completed.
///
/// **Kept in the keychain, beside the session tokens, and that is deliberate.**
/// The thing this id stands in for is the app container: the Facebook cookie jar
/// lives there and dies with it. Storing the id anywhere more durable would let
/// it outlive the cookies it is meant to describe, and the server would go on
/// believing Facebook was connected on an install that had been wiped. Losing
/// the id and losing the cookies together is the correct behaviour, not a
/// shortcoming.
///
/// Not `identifierForVendor`: that survives a reinstall, which is precisely the
/// property we do not want, and it is a value Apple controls the lifetime of.
enum InstallIdentity {
    private static let key = "install_id"

    /// Read once per process.
    ///
    /// `Keychain.set` is best-effort, and if it silently fails, re-deriving on
    /// every call would mint a fresh id each time and create a new device row
    /// per login. Caching means the worst case is one extra row per app launch
    /// rather than one per sign-in.
    private static let cached: String = {
        if let existing = Keychain.get(key), !existing.isEmpty {
            return existing
        }
        let fresh = UUID().uuidString
        Keychain.set(fresh, for: key)
        return fresh
    }()

    static var current: String { cached }
}
