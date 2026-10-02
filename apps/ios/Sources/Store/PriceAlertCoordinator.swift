import Foundation
import WebKit
import UserNotifications

@MainActor
final class PriceAlertCoordinator: ObservableObject {
    static let shared = PriceAlertCoordinator()
    @Published var selectedTab = 0
    @Published var openAlertID: String?
    @Published private(set) var webView: WKWebView?
    private var running: Task<Bool, Never>?
    private let service = PriceAlertsService()

    func open(_ id: String) {
        selectedTab = 2
        openAlertID = id
    }

    func cancel() { running?.cancel() }

    func perform() async -> Bool {
        if let running {
            return await withTaskCancellationHandler { await running.value } onCancel: { running.cancel() }
        }
        let task = Task { await searchPending() }
        running = task
        defer { running = nil; webView?.stopLoading(); webView = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func searchPending() async -> Bool {
        do {
            try Task.checkCancellation()
            guard await SessionState.isSignedIn() else {
                await AccountSession.shared.reportFacebookConnection(false)
                return false
            }
            await PushRegistrar.shared.refreshStatus()
            guard PushRegistrar.shared.isEnabled else { return false }
            let work = try await service.call("work", as: PriceAlertsService.WorkList.self).work
            for var check in work {
                try Task.checkCancellation()
                guard let actor = await SessionState.facebookActor(), check.actor == nil || check.actor == actor else { continue }
                let browser = WKWebView(frame: .zero, configuration: .make())
                browser.customUserAgent = Surface.desktop.userAgent
                webView = browser
                let client = AuthenticatedFeedClient(webView: browser, cursorActor: actor)
                var cursors = Set<String>()
                while true {
                    try Task.checkCancellation()
                    let page = try await client.page(for: check.searchQuery, cursor: check.cursor)
                    if page.hasNextPage {
                        guard let next = page.endCursor, !next.isEmpty, next != check.cursor,
                              cursors.insert(next).inserted else { throw GraphQLFeedError.invalidResponse }
                    }
                    let listings = page.listings.compactMap { item -> AlertListing? in
                        guard item.isSold != true, let title = item.title, !title.isEmpty else { return nil }
                        return AlertListing(id: item.id, title: title, priceText: item.priceFormatted ?? "",
                                            locationText: item.locationText ?? "", thumbnailURL: item.photoURL ?? "",
                                            description: "", condition: "")
                    }
                    let _: PriceAlertsService.Empty = try await service.call("page", .init(
                        checkID: check.id, pageNumber: check.pageNumber, cursor: page.endCursor,
                        actor: actor, complete: !page.hasNextPage, listings: listings), as: PriceAlertsService.Empty.self)
                    if !page.hasNextPage { break }
                    check.cursor = page.endCursor
                    check.pageNumber += 1
                }
                browser.stopLoading()
            }
            return !work.isEmpty
        } catch {
            if !Task.isCancelled { print("[price-alerts] Search deferred: \(error.localizedDescription)") }
            return false
        }
    }
}
