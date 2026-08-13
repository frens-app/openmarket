import Foundation
import os

/// Counters and rates only — no listing content and no search terms pass
/// through here. (That describes this file, not the app: `Analytics` sends
/// content deliberately.)
///
/// `loginWallHit` and `handoff` are also forwarded to `Analytics`, being product
/// facts rather than engine health. The other three stay local on volume
/// grounds: they fire on every page of every search.
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

    /// Any field below this is flagged.
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

    /// `loginWallCount` is per-process; the event is what says whether the
    /// share of sessions hitting one is moving.
    func loginWallHit(surface: String) {
        loginWallCount += 1
        log.warning("login wall on \(surface, privacy: .public), total=\(self.loginWallCount)")
        Analytics.capture(.loginWallHit, [
            "surface": surface,
            // The first wall is a rate limit; the fourth is a dead session.
            "session_count": loginWallCount
        ])
    }

    func detailLatency(seconds: TimeInterval, succeeded: Bool) {
        log.info("detail \(succeeded ? "ok" : "failed") in \(String(format: "%.2f", seconds))s")
    }

    /// §4 makes every route out of a listing a link, so this is the last thing
    /// the app can observe about somebody who went on to buy something.
    func handoff(kind: String) {
        log.info("handoff: \(kind, privacy: .public)")
        Analytics.capture(.listingOpenedOnFacebook, ["kind": kind])
    }

    func pageLoaded(index: Int, listings: Int) {
        sessionRequestCount += 1
        log.info("page \(index) -> \(listings) listings (session requests: \(self.sessionRequestCount))")
    }
}
