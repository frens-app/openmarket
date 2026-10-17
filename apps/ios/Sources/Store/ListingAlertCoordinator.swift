import Foundation
import WebKit
import UserNotifications

@MainActor
final class ListingAlertCoordinator: ObservableObject {
    static let shared = ListingAlertCoordinator()
    @Published var selectedTab = 0
    @Published var matchRevision = 0
    @Published var openAlertID: String?
    private(set) var openNotificationID: String?
    @Published private(set) var webView: WKWebView?
    private var running: Task<Bool, Never>?
    private let service = ListingAlertsService()

    func open(_ id: String, notificationID: String? = nil) {
        openNotificationID = notificationID
        selectedTab = 3
        openAlertID = id
    }

    func cancel() { running?.cancel() }

    func perform(fetchAttemptID: String? = nil) async -> Bool {
        await reportFetchEvent(fetchAttemptID, event: "acknowledged")
        if let running {
            await reportFetchEvent(fetchAttemptID, event: "failed", stage: "background", code: "already_running")
            return await running.value
        }
        let task = Task { await searchPending(fetchAttemptID: fetchAttemptID) }
        running = task
        defer { running = nil; webView?.stopLoading(); webView = nil }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func searchFirstPage(_ check: AlertWork, actor: String, client: any GraphQLFeedLoading) async throws -> ListingAlertsService.Request {
        let page = try await client.page(for: check.searchQuery, cursor: nil)
        try Task.checkCancellation()
        let listings = page.listings.compactMap { item -> AlertListing? in
            guard item.isSold != true, let title = item.title, !title.isEmpty else { return nil }
            return AlertListing(id: item.id, title: title, priceText: item.priceFormatted ?? "",
                                locationText: item.locationText ?? "", thumbnailURL: item.photoURL ?? "",
                                description: "", condition: "")
        }
        return .init(checkID: check.id, pageNumber: check.pageNumber,
                     actor: actor, complete: true, listings: listings, fetchAttemptID: check.fetchAttemptID)
    }

    func reportFetchEvent(_ attemptID: String?, event: String, stage: String? = nil, code: String? = nil) async {
        guard let attemptID else { return }
        // An independent task can report cancellation while the background callback has time left.
        await Task { @MainActor in
            let _: ListingAlertsService.Empty? = try? await service.call("fetch-event", .init(
                fetchAttemptID: attemptID, event: event, failureStage: stage, failureCode: code),
                as: ListingAlertsService.Empty.self, timeout: 2)
        }.value
    }

    static func failureCode(for error: Error) -> String {
        if let error = error as? GraphQLFeedError {
            switch error {
            case .unsupportedQuery: return "unsupported_search"
            case .invalidResponse: return "invalid_facebook_response"
            case .blocked: return "facebook_blocked"
            case .paused: return "search_paused"
            case .sessionChanged: return "facebook_changed"
            }
        }
        if let error = error as? URLError {
            return error.code == .timedOut ? "network_timeout" : "network_error"
        }
        if error is DecodingError { return "invalid_server_response" }
        return "request_failed"
    }

    private func searchPending(fetchAttemptID: String?) async -> Bool {
        var activeAttemptID = fetchAttemptID
        var stage = "eligibility"
        do {
            try Task.checkCancellation()
            guard await SessionState.isSignedIn() else {
                await reportFetchEvent(activeAttemptID, event: "failed", stage: stage, code: "facebook_disconnected")
                await AccountSession.shared.reportFacebookConnection(false)
                return false
            }
            await PushRegistrar.shared.refreshStatus()
            guard PushRegistrar.shared.isEnabled else {
                await reportFetchEvent(activeAttemptID, event: "failed", stage: stage, code: "notifications_disabled")
                return false
            }
            stage = "work"
            let prefs = Preferences.shared
            let location = prefs.resolvedPlace.map {
                AlertLocation(citySlug: $0.segment, name: $0.name, radiusKM: prefs.radiusKM,
                              latitude: $0.latitude, longitude: $0.longitude)
            }
            let work = try await service.call("work", .init(location: location, fetchAttemptID: fetchAttemptID,
                trigger: fetchAttemptID == nil ? "foreground" : "background_push"), as: ListingAlertsService.WorkList.self).work
            if work.isEmpty {
                await reportFetchEvent(activeAttemptID, event: "failed", stage: stage, code: "no_pending_work")
            }
            for check in work {
                try Task.checkCancellation()
                activeAttemptID = check.fetchAttemptID
                stage = "eligibility"
                guard let actor = await SessionState.facebookActor(), check.actor == nil || check.actor == actor else {
                    await reportFetchEvent(activeAttemptID, event: "failed", stage: stage, code: "facebook_changed")
                    continue
                }
                let browser = WKWebView(frame: .zero, configuration: .make())
                browser.customUserAgent = Surface.desktop.userAgent
                webView = browser
                let client = AuthenticatedFeedClient(webView: browser, cursorActor: actor)
                stage = "search"
                await reportFetchEvent(activeAttemptID, event: "search_started")
                try Task.checkCancellation()
                let request = try await Self.searchFirstPage(check, actor: actor, client: client)
                stage = "upload"
                let _: ListingAlertsService.Empty = try await service.call("page", request, as: ListingAlertsService.Empty.self)
                browser.stopLoading()
            }
            return !work.isEmpty
        } catch {
            await reportFetchEvent(activeAttemptID, event: "failed", stage: stage,
                                   code: Task.isCancelled ? "cancelled" : Self.failureCode(for: error))
            if !Task.isCancelled { print("[listing-alerts] Search deferred: \(error.localizedDescription)") }
            return false
        }
    }
}
