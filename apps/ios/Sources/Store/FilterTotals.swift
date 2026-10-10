import Foundation
import Combine

@MainActor
final class FilterTotals: ObservableObject {
    static let shared = FilterTotals()

    @Published private(set) var nonLocalListings: Int
    @Published private(set) var ads: Int
    private let defaults: UserDefaults
    private var nonLocalIDs: Set<String>
    private var sponsoredIDs: Set<String>

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        nonLocalIDs = Set(defaults.stringArray(forKey: "filterTotals.nonLocalIDs") ?? [])
        sponsoredIDs = Set(defaults.stringArray(forKey: "filterTotals.sponsoredIDs") ?? [])
        nonLocalListings = nonLocalIDs.count
        ads = defaults.integer(forKey: "filterTotals.ads")
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
