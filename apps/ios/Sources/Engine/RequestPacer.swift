import Foundation

/// Fetch only what the user is looking at, back off hard when Facebook
/// pushes back, and cap the session so a bug can't turn into a crawl.
actor RequestPacer {
    /// The one pacer. Everything that talks to Facebook shares it.
    ///
    /// A pacer per engine defeats all three mechanisms below: the session cap
    /// becomes per-engine, so the real ceiling is some multiple of 300; the
    /// minimum gap stops being a gap, since two engines can fire without seeing
    /// each other; and **backoff stops propagating**, leaving the detail engine
    /// at full speed while Facebook is blocking the feed engine. Backoff only
    /// one code path observes isn't backoff — the *session* has to go quiet,
    /// across both signed-in browsing and anonymous comparison traffic.
    static let shared = RequestPacer()

    private var consecutiveBlocks = 0
    private var requestCount = 0
    private var blockedUntil: Date?

    /// 30s → 2m → 10m → stop, per spec.
    private static let backoffLadder: [TimeInterval] = [30, 120, 600]
    private static let sessionRequestCap = 300
    /// Jitter request starts by 100–300 ms. Reserve each slot before sleeping
    /// so simultaneous callers cannot all select the same departure time.
    private let nextGap: @Sendable () -> TimeInterval
    private var lastRequest: Date?

    init(nextGap: @escaping @Sendable () -> TimeInterval = { .random(in: 0.1...0.3) }) {
        self.nextGap = nextGap
    }

    var isStopped: Bool { consecutiveBlocks > Self.backoffLadder.count }

    /// Returns false when the caller should not make a request at all.
    func waitForSlot() async -> Bool {
        guard requestCount < Self.sessionRequestCap, !isStopped else { return false }

        if let blockedUntil, blockedUntil > Date() {
            let wait = blockedUntil.timeIntervalSinceNow
            guard wait < 15 else { return false }   // don't hold the UI on a long backoff
            do { try await Task.sleep(for: .seconds(wait)) }
            catch { return false }
        }
        guard requestCount < Self.sessionRequestCap, !isStopped else { return false }
        // The slot is claimed *before* the wait, not after it.
        //
        // Sleeping first and stamping afterwards works for one caller at a time
        // and silently stops working the moment there are several: `await`
        // inside an actor method lets the next call in, so every concurrent
        // caller measured its gap against the same `lastRequest`, slept the
        // same amount, and fired together — a burst, which is the one thing
        // this exists to prevent. Measured when Discover started running its
        // three searches at once: two of the three left at the same
        // millisecond.
        //
        // Reserving the time up front makes each caller queue behind the last
        // reservation instead of behind the last departure.
        let now = Date()
        let gap = nextGap()
        let slot = max(now, lastRequest?.addingTimeInterval(gap) ?? now)
        lastRequest = slot
        requestCount += 1
        let wait = slot.timeIntervalSince(now)
        if wait > 0 {
            do { try await Task.sleep(for: .seconds(wait)) }
            catch { return false }
        }
        // Another engine may have encountered a block while this slot slept.
        guard !Task.isCancelled, !isStopped,
              blockedUntil.map({ $0 <= Date() }) ?? true else { return false }
        return true
    }

    func recordSuccess() {
        consecutiveBlocks = 0
        blockedUntil = nil
    }

    func recordBlock() {
        let index = min(consecutiveBlocks, Self.backoffLadder.count - 1)
        blockedUntil = Date().addingTimeInterval(Self.backoffLadder[index])
        consecutiveBlocks += 1
    }

    var backoffRemaining: TimeInterval {
        guard let blockedUntil else { return 0 }
        return max(0, blockedUntil.timeIntervalSinceNow)
    }
}
