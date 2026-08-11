import Connect
import Foundation
import OpenMarketProtos

/// The Connect clients, and the one place the server's address is decided.
enum API {
    /// Where the app talks to.
    ///
    /// Debug builds point at a laptop; release builds at Railway. Left as a
    /// compile-time switch rather than a setting because a shipped build must
    /// not be pointable at an arbitrary host, and because `localhost` from the
    /// Simulator is the Mac running it — which is what makes `make dev` enough
    /// to develop against.
    static var baseURL: String {
        #if DEBUG
        return ProcessInfo.processInfo.environment["OPENMARKET_API_URL"] ?? "http://localhost:8080"
        #else
        return "https://api.openmarket.app"
        #endif
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
