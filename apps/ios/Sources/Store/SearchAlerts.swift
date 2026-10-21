import Foundation
import Combine

/// The alert fields needed by Browse. Schedules and matches stay in the alert detail.
struct SearchAlert: Identifiable, Equatable {
    let id: String
    let query: String
    let minPrice: Int?
    let maxPrice: Int?
    var paused: Bool

    init(id: String, query: String, minPrice: Int?, maxPrice: Int?, paused: Bool = false) {
        self.id = id
        self.query = query
        self.minPrice = minPrice
        self.maxPrice = maxPrice
        self.paused = paused
    }

    init(_ alert: ListingAlert) {
        self.init(id: alert.id, query: alert.query, minPrice: alert.minPrice,
                  maxPrice: alert.maxPrice, paused: alert.paused)
    }

    static func normalizedQuery(_ query: String) -> String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }
}

@MainActor
final class SearchAlerts: ObservableObject {
    static let shared = SearchAlerts()

    @Published private(set) var alerts: [SearchAlert] = []
    private(set) var accountID: String?
    private(set) var revision = 0
    private let load: () async throws -> [SearchAlert]

    init(load: @escaping () async throws -> [SearchAlert] = {
        try await ListingAlertsService().call("list", as: ListingAlertsService.AlertList.self).alerts.map(SearchAlert.init)
    }) {
        self.load = load
    }

    func setAccount(_ id: String?) {
        guard accountID != id else { return }
        accountID = id
        revision += 1
        alerts = []
    }

    func refresh(for owner: String?) async {
        guard let owner, owner == accountID else { return }
        revision += 1
        let requestRevision = revision
        guard let loaded = try? await load(), accountID == owner, revision == requestRevision else { return }
        alerts = loaded
    }

    func replace(_ alerts: [ListingAlert], for owner: String?, since requestRevision: Int) {
        guard let owner, owner == accountID, requestRevision == revision else { return }
        revision += 1
        self.alerts = alerts.map(SearchAlert.init)
    }

    func created(_ alert: SearchAlert, for owner: String?) {
        guard let owner, owner == accountID else { return }
        revision += 1
        alerts.removeAll { $0.id == alert.id }
        alerts.insert(alert, at: 0)
    }

    func setPaused(_ paused: Bool, id: String, for owner: String?) {
        guard let owner, owner == accountID else { return }
        revision += 1
        if let index = alerts.firstIndex(where: { $0.id == id }) { alerts[index].paused = paused }
    }

    func remove(id: String, for owner: String?) {
        guard let owner, owner == accountID else { return }
        revision += 1
        alerts.removeAll { $0.id == id }
    }

    func matching(query: String, minPrice: Int?, maxPrice: Int?, for owner: String?) -> SearchAlert? {
        matchingHistory(query, for: owner, candidates: alerts.filter { $0.minPrice == minPrice && $0.maxPrice == maxPrice })
    }

    /// History stores terms, not filter snapshots. Any active alert for the term earns the badge.
    func matchingHistory(_ query: String, for owner: String?) -> SearchAlert? {
        matchingHistory(query, for: owner, candidates: alerts)
    }

    private func matchingHistory(_ query: String, for owner: String?, candidates: [SearchAlert]) -> SearchAlert? {
        guard let owner, owner == accountID else { return nil }
        let key = SearchAlert.normalizedQuery(query)
        guard !key.isEmpty else { return nil }
        let matches = candidates.filter { SearchAlert.normalizedQuery($0.query) == key }
        return matches.first { !$0.paused } ?? matches.first
    }
}
