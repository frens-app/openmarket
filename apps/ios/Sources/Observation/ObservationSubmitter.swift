import Connect
import Foundation
import OpenMarketProtos
import os

extension Logger {
    /// Observation ingest. Its own category so the whole path can be silenced
    /// or watched without touching the extractor logs it sits beside.
    static let observation = Logger(subsystem: "lol.frens.openmarket", category: "observation")
}

/// Sends observations, and is incapable of affecting the app that produces them.
///
/// **Nothing here is on any path a person is waiting for.** Every entry point
/// returns immediately, nothing throws to a caller, and no result is awaited by
/// a screen. A batch is a by-product of a search or an open that has already
/// finished; if the server is down, the correct behaviour is that nobody
/// notices. The queue is bounded and the failure path is a log line.
///
/// That is a policy, not an accident, so it is enforced by shape: `submit` is
/// not `async`, not `throws`, and returns `Void` — there is no value for a call
/// site to wait on and no error for it to handle.
///
/// The queue is memory-only. Losing it on termination is fine and disk would be
/// worse: the server refuses a capture older than its window, so a persisted
/// batch would mostly be persisted rubbish, and observations are a by-product
/// rather than the user's data.
actor ObservationSubmitter {
    static let shared = ObservationSubmitter()

    /// Batches held while offline. Small: a batch is up to a hundred cards, and
    /// keeping a long backlog only means submitting stale captures the server
    /// will refuse anyway.
    private static let queueLimit = 16

    /// After this many consecutive failures, stop until something succeeds
    /// elsewhere. A device with no route to the server should not spend its
    /// battery finding that out once per search.
    private static let failureCeiling = 5

    private let client: ObservationServiceClient
    private let session: AccountSession

    private var pending: [SubmitObservationsRequest] = []
    private var draining = false
    private var consecutiveFailures = 0

    /// Set only when the server refuses this build outright.
    private var stopped = false

    init(session: AccountSession = .shared, client: ObservationServiceClient? = nil) {
        self.session = session
        self.client = client ?? ObservationServiceClient(client: API.makeProtocolClient())
    }

    /// Hands over a batch. Returns immediately, always.
    nonisolated func submit(_ request: SubmitObservationsRequest) {
        Task { await enqueue(request) }
    }

    private func enqueue(_ request: SubmitObservationsRequest) async {
        guard !stopped else { return }
        pending.append(request)
        if pending.count > Self.queueLimit {
            // Oldest first. A capture's value decays — the newest batch is the
            // one describing the market as it is now, and the server would
            // refuse the oldest on age anyway.
            let dropped = pending.count - Self.queueLimit
            pending.removeFirst(dropped)
            Logger.observation.error("dropped \(dropped) queued batches: queue full")
        }
        await drain()
    }

    private func drain() async {
        guard !draining, !stopped else { return }
        draining = true
        defer { draining = false }

        while !pending.isEmpty, !stopped {
            guard consecutiveFailures < Self.failureCeiling else {
                Logger.observation.info("paused after \(self.consecutiveFailures) failures; \(self.pending.count) batches held")
                return
            }
            let request = pending[0]
            guard await send(request) else { return }
            pending.removeFirst()
        }
    }

    /// One attempt. True when the batch is done with — accepted, or refused in
    /// a way a retry cannot change.
    private func send(_ request: SubmitObservationsRequest) async -> Bool {
        let headers: Headers
        do {
            headers = try await session.authorizedHeaders()
        } catch {
            // No session. Not a failure to count against the ceiling: signing
            // in is what fixes it, and it will be retried on the next batch.
            return false
        }

        let response = await client.submitObservations(request: request, headers: headers)
        switch response.result {
        case .success(let message):
            consecutiveFailures = 0
            if message.sourceSuspended {
                // Suspension is scoped to this request's surface. Other routes
                // remain healthy and must continue to submit.
                Logger.observation.error("source suspended by the server; batch not merged")
            }
            if message.quarantined > 0 {
                Logger.observation.error("""
                    batch \(message.batchID, privacy: .public): \
                    \(message.accepted) accepted, \(message.quarantined) quarantined
                    """)
            }
            return true

        case .failure(let error):
            switch error.code {
            case .failedPrecondition:
                // This build is refused, or this session has no device. Neither
                // changes while the process is alive.
                stopped = true
                Logger.observation.error("submission refused: \(error.message ?? "no reason given", privacy: .public)")
                return false
            case .invalidArgument:
                // Malformed by our own schema's rules, or a capture time the
                // server will not vouch for. Retrying is guaranteed to fail, so
                // the batch is discarded rather than held.
                Logger.observation.error("batch rejected: \(error.message ?? "no reason given", privacy: .public)")
                return true
            case .unauthenticated:
                return false
            default:
                consecutiveFailures += 1
                Logger.observation.info("submission failed (\(String(describing: error.code), privacy: .public)); will retry")
                return false
            }
        }
    }

    /// Lets a later batch retry after the ceiling was hit. Called when the app
    /// comes back to the foreground, which is the moment a network is most
    /// likely to have returned.
    func resume() {
        guard !stopped else { return }
        consecutiveFailures = 0
        Task { await drain() }
    }
}
