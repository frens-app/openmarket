import Foundation
import OpenMarketProtos

enum ComparisonRelevance {
    static func item(title: String, description: String?, condition: String? = nil) -> ComparisonItem {
        var item = ComparisonItem()
        item.title = String(title.prefix(500))
        item.description_p = String((description ?? "").prefix(2000))
        item.condition = String((condition ?? "").prefix(200))
        return item
    }

    static func item(for listing: Listing) -> ComparisonItem {
        item(title: listing.title ?? "", description: listing.detail?.description,
             condition: listing.conditionText ?? listing.detail?.conditionText)
    }

    static func candidates(from comps: [MarketComp]) -> [ComparisonCandidate] {
        comps.enumerated().compactMap { index, comp in
            guard let title = comp.listing.title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            var candidate = ComparisonCandidate()
            candidate.id = String(index)
            candidate.item = item(for: comp.listing)
            return candidate
        }
    }

    static func apply(_ decisions: [ComparableDecision], to comps: [MarketComp],
                      candidates: [ComparisonCandidate]) throws -> [MarketComp] {
        let expected = Set(candidates.map(\.id))
        guard decisions.count == expected.count,
              Set(decisions.map(\.id)) == expected else { throw APIError.network }
        let byID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.id, $0) })
        return try comps.enumerated().map { index, comp in
            var result = comp
            guard let decision = byID[String(index)] else {
                result.relevance = .excluded
                return result
            }
            guard decision.probability.isFinite, (0...1).contains(decision.probability) else {
                throw APIError.network
            }
            result.relevance = decision.useInComparison ? .included : .excluded
            result.relevanceProbability = decision.probability
            return result
        }
    }
}
