import Foundation
import os

/// §8. These are counters and rates only — no listing content and no search
/// terms pass through *this* file, which is a statement about what parse health
/// and page latency are made of rather than a privacy boundary. `Analytics` does
/// send content, deliberately, and says why.
///
/// The protocol exists so a backend can be chosen later without touching call
/// sites — and for two of the five, one has been: `loginWallHit` and `handoff`
/// are forwarded to `Analytics` as well as logged, because both are product
/// facts rather than engine health.
///
/// The other three stay local, and the split is about volume, not secrecy.
/// Parse coverage and per-page latency are properties of somebody else's HTML:
/// they fire on every page of every search, they answer a question only this
/// repo can act on, and sending them would be paying a third party to store a
/// debug log.
protocol MetricsReporter: AnyObject {
    func parseHealth(_ health: ParseHealth)
    func loginWallHit(surface: String)
    func detailLatency(seconds: TimeInterval, succeeded: Bool)
    func handoff(kind: String)
    func pageLoaded(index: Int, listings: Int)
}

struct ParseHealth: Equatable {
    var domCards = 0
    var extracted = 0
    var dropped = 0
    var rendered = 0
    var fieldCounts: [String: Int] = [:]

    func coverage(_ field: String) -> Double {
        guard extracted > 0 else { return 0 }
        return Double(fieldCounts[field] ?? 0) / Double(extracted)
    }

    /// §3.4 flags any field below this.
    static let coverageThreshold = 0.90

    var failingFields: [String] {
        fieldCounts.keys.filter { coverage($0) < Self.coverageThreshold }.sorted()
    }
}

final class LocalMetrics: MetricsReporter {
    static let shared = LocalMetrics()
    private let log = Logger(subsystem: "lol.frens.openmarket", category: "metrics")

    private(set) var latestHealth = ParseHealth()
    private(set) var loginWallCount = 0
    private(set) var sessionRequestCount = 0

    func parseHealth(_ health: ParseHealth) {
        latestHealth = health
        let failing = health.failingFields
        log.info("parse: dom=\(health.domCards) extracted=\(health.extracted) dropped=\(health.dropped) rendered=\(health.rendered) failing=\(failing.joined(separator: ","))")
    }

    /// The failure that stops this being a product, so it is the one piece of
    /// engine health that also goes up.
    ///
    /// `loginWallCount` is per-process and answers "is it happening right now";
    /// the event answers the question that actually decides things — what share
    /// of sessions hit one, and whether that share is moving.
    func loginWallHit(surface: String) {
        loginWallCount += 1
        log.warning("login wall on \(surface, privacy: .public), total=\(self.loginWallCount)")
        Analytics.capture(.loginWallHit, [
            "surface": surface,
            // Which wall within this session — the first is a rate limit, the
            // fourth is a session that has stopped working.
            "session_count": loginWallCount
        ])
    }

    func detailLatency(seconds: TimeInterval, succeeded: Bool) {
        log.info("detail \(succeeded ? "ok" : "failed") in \(String(format: "%.2f", seconds))s")
    }

    /// Leaving for Facebook, which is as close as this app gets to a
    /// conversion: §4 makes every route out of a listing a link, so this is the
    /// last thing it can observe about somebody who went on to buy something.
    func handoff(kind: String) {
        log.info("handoff: \(kind, privacy: .public)")
        Analytics.capture(.listingOpenedOnFacebook, ["kind": kind])
    }

    func pageLoaded(index: Int, listings: Int) {
        sessionRequestCount += 1
        log.info("page \(index) -> \(listings) listings (session requests: \(self.sessionRequestCount))")
    }
}
