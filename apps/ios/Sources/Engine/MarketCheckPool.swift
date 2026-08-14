import Foundation
import WebKit

/// A few search engines that can run at the same time, and a queue for the rest.
///
/// Its own engines rather than the browse tab's: a check navigates twice, and
/// borrowing `store.desktop` would page the grid the user is reading out from
/// under them. Same reasoning as `ComparableSearch` keeping the seller tab off
/// the browse engine, applied one surface further along.
///
/// Two, not one, because a buyer opens a listing, asks, backs out and asks about
/// the next one before the first has answered — serialised, the second looks
/// broken. Two, not ten, because every load still goes through
/// `RequestPacer.shared`: past the point where the pacer is the bottleneck, more
/// engines buy no throughput and cost a web content process each.
@MainActor
final class MarketCheckPool {
    /// Built up front, not on the first check. A webview has to be in the view
    /// hierarchy before it loads or WebKit takes a reduced rendering path and
    /// the cards never fully render (`SignedInView`) — and a webview created at
    /// the moment of use is one SwiftUI render pass behind that.
    let searches: [ComparableSearch]

    private var free: [ComparableSearch]
    private var waiting: [CheckedContinuation<ComparableSearch, Never>] = []

    init(capacity: Int = 2) {
        searches = (0..<max(1, capacity)).map { _ in ComparableSearch() }
        free = searches
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
