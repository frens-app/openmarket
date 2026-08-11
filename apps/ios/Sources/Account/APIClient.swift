import Connect
import Foundation
import OpenMarketProtos

/// The Connect clients, and the one place the server's address is decided.
enum API {
    /// Where the app talks to, fixed at build time by the configuration.
    ///
    /// Read from the Info.plist, which `apps/ios/Configurations/*.xcconfig`
    /// fills in — Debug points at a laptop, Release at Railway. Two keys rather
    /// than one URL because xcconfig treats `//` as a comment; the reasoning is
    /// in `Debug.xcconfig`.
    ///
    /// This replaced a `#if DEBUG` branch with an environment-variable override.
    /// Both halves of that were wrong: `#if DEBUG` is a compiler flag rather
    /// than a build configuration, so it cannot describe a third environment and
    /// says nothing to anything that isn't compiling; and the override only
    /// existed when Xcode launched the process, so it silently did nothing on a
    /// TestFlight build or a device run from the home screen.
    ///
    /// Still not a user-facing setting, for the original reason: a shipped build
    /// must not be pointable at an arbitrary host. A developer changes it by
    /// editing a gitignored `Debug.local.xcconfig` and rebuilding.
    static let baseURL: String = resolveBaseURL()

    /// Human-readable, for the launch log and for a Settings row in Debug. Just
    /// the host — the scheme is noise once you know which of the two it is.
    static var environmentSummary: String {
        "\(bundleString("API_HOSTNAME") ?? "unconfigured")"
    }

    private static func bundleString(_ key: String) -> String? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Fails the launch rather than starting up pointed at nothing.
    ///
    /// A missing or malformed endpoint is a build misconfiguration, not a
    /// runtime condition: it is identical on every launch of that build, so it
    /// surfaces the first time anybody runs it — including in TestFlight, before
    /// it can reach the App Store. The alternative is an app that opens onto a
    /// login screen where every attempt fails with "couldn't reach the server",
    /// which looks like an outage and gets debugged as one.
    private static func resolveBaseURL() -> String {
        guard let scheme = bundleString("API_SCHEME"), let host = bundleString("API_HOSTNAME") else {
            preconditionFailure(
                "API_SCHEME and API_HOSTNAME must be set. They come from "
                + "apps/ios/Configurations/<config>.xcconfig — check that project.yml still "
                + "lists them under the target's `info.properties`, and re-run `make ios-generate`."
            )
        }
        precondition(scheme == "http" || scheme == "https", "API_SCHEME must be http or https, got \(scheme)")

        // Cleartext to a real server is a mistake worth catching at the door,
        // and it can only happen by editing Release.xcconfig — which is exactly
        // the edit nobody would notice in review.
        #if !DEBUG
        precondition(scheme == "https", "a release build must talk https, got \(scheme)://\(host)")
        #endif

        return "\(scheme)://\(host)"
    }

    static func makeProtocolClient() -> ProtocolClient {
        ProtocolClient(
            httpClient: URLSessionHTTPClient(),
            config: ProtocolClientConfig(
                host: baseURL,
                // JSON over Connect, not binary proto. The schema is where the
                // value is; the encoding is a tuning knob, and JSON stays
                // curl-able while the API is still moving. Switching is a
                // one-line change here.
                networkProtocol: .connect,
                codec: JSONCodec()
            )
        )
    }
}

/// What a call can fail with, in terms the UI can act on.
enum APIError: LocalizedError {
    /// The server rejected the request and said why in words meant for a user.
    case message(String)
    /// Too many attempts.
    case rateLimited(String)
    /// The session is gone — the caller should sign out rather than retry.
    case unauthenticated
    /// Anything the network did. Distinguished from `.message` because it is
    /// worth retrying and the others are not.
    case network

    var errorDescription: String? {
        switch self {
        case .message(let text), .rateLimited(let text):
            return text
        case .unauthenticated:
            return "Your session ended. Sign in again."
        case .network:
            return "Couldn't reach the server. Check your connection."
        }
    }
}

extension ConnectError {
    /// Maps a Connect error onto `APIError`.
    ///
    /// The server writes user-facing text into the message for exactly the
    /// codes below and nothing else, so anything unrecognised is deliberately
    /// flattened to `.network` rather than shown — an internal error's message
    /// is not something to put in front of a person.
    var asAPIError: APIError {
        switch code {
        case .unauthenticated:
            return .unauthenticated
        case .resourceExhausted:
            return .rateLimited(message ?? "Too many attempts. Try again later.")
        case .invalidArgument, .failedPrecondition, .notFound:
            return .message(message ?? "That didn't work.")
        default:
            return .network
        }
    }
}
