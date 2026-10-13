import Foundation
import Combine

@MainActor
final class FilterTotals: ObservableObject {
    static let shared = FilterTotals()

    enum Surface {
        case discover
        case search
    }

    @Published private(set) var nonLocalListings: Int
    @Published private(set) var ads: Int
    @Published private(set) var discoverListings: Int
    @Published private(set) var searchListings: Int
    private let defaults: UserDefaults
    private var nonLocalIDs: Set<String>
    private var sponsoredIDs: Set<String>
    private var discoverIDs: Set<String>
    private var searchIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nonLocalIDs = Set(defaults.stringArray(forKey: "filterTotals.nonLocalIDs") ?? [])
        sponsoredIDs = Set(defaults.stringArray(forKey: "filterTotals.sponsoredIDs") ?? [])
        discoverIDs = Set(defaults.stringArray(forKey: "filterTotals.discoverIDs") ?? [])
        searchIDs = Set(defaults.stringArray(forKey: "filterTotals.searchIDs") ?? [])
        nonLocalListings = nonLocalIDs.count
        ads = defaults.integer(forKey: "filterTotals.ads")
        discoverListings = discoverIDs.count
        searchListings = searchIDs.count
    }

    func recordShownListing(_ id: String, on surface: Surface) {
        switch surface {
        case .discover:
            guard discoverIDs.insert(id).inserted else { return }
            discoverListings = discoverIDs.count
            defaults.set(Array(discoverIDs), forKey: "filterTotals.discoverIDs")
        case .search:
            guard searchIDs.insert(id).inserted else { return }
            searchListings = searchIDs.count
            defaults.set(Array(searchIDs), forKey: "filterTotals.searchIDs")
        }
    }

    func recordNonLocal(_ ids: [String]) {
        let previous = nonLocalIDs.count
        nonLocalIDs.formUnion(ids)
        guard nonLocalIDs.count != previous else { return }
        nonLocalListings = nonLocalIDs.count
        defaults.set(Array(nonLocalIDs), forKey: "filterTotals.nonLocalIDs")
    }

    func recordSponsoredListing(_ id: String) {
        guard sponsoredIDs.insert(id).inserted else { return }
        defaults.set(Array(sponsoredIDs), forKey: "filterTotals.sponsoredIDs")
        recordAds(1)
    }

    // Ad stories can lack stable IDs; count their slots once per accepted page.
    func recordAds(_ count: Int) {
        guard count > 0 else { return }
        ads += count
        defaults.set(ads, forKey: "filterTotals.ads")
    }
}
