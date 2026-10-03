import Foundation
import WebKit

@MainActor
final class AmazonCheckModel: ObservableObject {
    enum Phase: Equatable {
        case running(String)
        case done([MarketComp])
        case failed(String)
    }

    @Published private(set) var phases: [String: Phase] = [:]
    private let search = AmazonSearch()
    private let pricing = PricingService(session: .shared)
    private var queue: [Listing] = []
    private var working = false
    private var completed: [String] = []
    var webView: WKWebView { search.webView }

    func check(_ listing: Listing) {
        switch phases[listing.id] {
        case .running, .done: return
        default: break
        }
        guard !SearchTerm.from(listing.title ?? "").isEmpty else { return }
        phases[listing.id] = .running(working ? "Amazon comparison queued" : "Searching Amazon")
        queue.append(listing)
        guard !working else { return }
        working = true
        Task {
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await run(next)
                completed.removeAll { $0 == next.id }
                completed.append(next.id)
                if completed.count > 40 { phases[completed.removeFirst()] = nil }
            }
            working = false
        }
    }

    private func run(_ listing: Listing) async {
        do {
            phases[listing.id] = .running("Searching Amazon")
            let products = try await search.search(SearchTerm.from(listing.title ?? ""))
            phases[listing.id] = .running("Checking which Amazon products match")
            let evaluated = try await pricing.evaluate(target: ComparisonRelevance.item(for: listing), comps: products, retailAlternative: true)
            phases[listing.id] = .done(MarketComp.comparableFirst(evaluated))
        } catch {
            phases[listing.id] = .failed("Couldn't compare with Amazon. " + error.localizedDescription)
        }
    }
}
