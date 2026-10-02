import Foundation
import WebKit
import CoreLocation

/// A few search engines that can run at the same time, and a queue for the rest.
///
/// Its own engines rather than the browse tab's: fallback searches navigate, and
/// borrowing `store.desktop` would page the grid the user is reading out from
/// under them. Same reasoning as `ComparableSearch` keeping the seller tab off
/// the browse engine, applied one surface further along.
///
/// Two engines let the active and sold searches overlap. Each search borrows
/// independently, so concurrent checks queue without holding one engine while
/// waiting for another. All Facebook traffic still shares `RequestPacer`.
@MainActor
final class MarketCheckPool {
    /// Built up front, not on the first check. A webview has to be in the view
    /// hierarchy before it loads or WebKit takes a reduced rendering path and
    /// the cards never fully render (`AppView`) — and a webview created at
    /// the moment of use is one SwiftUI render pass behind that.
    let searches: [ComparableSearch]

    private var free: [ComparableSearch]
    private var waiting: [CheckedContinuation<ComparableSearch, Never>] = []

    init(capacity: Int = 2) {
        searches = (0..<max(1, capacity)).map { _ in ComparableSearch() }
        free = searches
    }

    init(searches: [ComparableSearch]) {
        precondition(!searches.isEmpty)
        self.searches = searches
        free = searches
    }

    struct SearchRun {
        let result: Result<[MarketComp], ComparableSearch.Failure>
        let queueMS: Int
        let fetchMS: Int
        let transport: String
    }

    struct SearchPair {
        let active: SearchRun
        let sold: SearchRun

        var timings: [String: Any] {
            ["active_queue_ms": active.queueMS, "active_fetch_ms": active.fetchMS,
             "sold_queue_ms": sold.queueMS, "sold_fetch_ms": sold.fetchMS,
             "active_transport": active.transport, "sold_transport": sold.transport]
        }
    }

    func comparables(to term: String, citySlug: String, radiusKM: Int,
                     coordinate: CLLocationCoordinate2D?, onStart: @escaping () -> Void = {}) async -> SearchPair {
        async let active = timedSearch(to: term, citySlug: citySlug, radiusKM: radiusKM,
                                       coordinate: coordinate, sold: false, onStart: onStart)
        async let sold = timedSearch(to: term, citySlug: citySlug, radiusKM: radiusKM,
                                     coordinate: coordinate, sold: true, onStart: onStart)
        return await SearchPair(active: active, sold: sold)
    }

    private func timedSearch(to term: String, citySlug: String, radiusKM: Int,
                             coordinate: CLLocationCoordinate2D?, sold: Bool, onStart: () -> Void) async -> SearchRun {
        let queuedAt = ContinuousClock.now
        return await withSearch { search in
            let started = ContinuousClock.now
            onStart()
            let result = sold
                ? await search.soldComparables(to: term, citySlug: citySlug, radiusKM: radiusKM, coordinate: coordinate)
                : await search.comparables(to: term, citySlug: citySlug, radiusKM: radiusKM, coordinate: coordinate)
            return SearchRun(result: result,
                             queueMS: Int(queuedAt.duration(to: started) / .milliseconds(1)),
                             fetchMS: Int(started.duration(to: .now) / .milliseconds(1)),
                             transport: search.lastTransport)
        }
    }

    var webViews: [WKWebView] { searches.map(\.webView) }

    /// Runs `body` on a free engine, waiting for one if all are busy.
    func withSearch<T>(_ body: (ComparableSearch) async -> T) async -> T {
        let search = await borrow()
        defer { giveBack(search) }
        return await body(search)
    }

    /// Whether a caller would have to wait, so the screen can say so instead of
    /// showing a spinner over a request that hasn't left yet.
    var hasFreeSearch: Bool { !free.isEmpty }

    /// Nothing cancels a check — `MarketCheckModel` runs them off the screen
    /// that asked, so a task waiting here is never torn down. A caller that did
    /// cancel would strand this continuation and never resume.
    private func borrow() async -> ComparableSearch {
        if !free.isEmpty { return free.removeFirst() }
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func giveBack(_ search: ComparableSearch) {
        if waiting.isEmpty {
            free.append(search)
        } else {
            waiting.removeFirst().resume(returning: search)
        }
    }
}
