import Foundation
import Combine

/// Which listings the user has actually opened, and when.
///
/// "Seen" here means **opened**, not scrolled past. Anything else would need a
/// judgement about dwell time and viewport that the grid can't make honestly,
/// and a tap is an unambiguous act: the user chose this listing.
///
/// Facebook has no equivalent — it will happily show you the same sofa every
/// day for a week — which is the whole reason this exists. It makes two things
/// possible that the remote surface can't: an "only new listings" filter
/// (`Preferences.hideViewed`) and the recently-viewed strip on the home screen.
///
/// Keyed by Facebook listing ID, with legacy keys migrated from cached URLs.
///
/// **Deliberately not part of `ListingCache`.** Profiles there are evicted LRU
/// at a thousand, and eviction would silently un-see a listing — the record of
/// having looked at something is user data with a different lifetime from the
/// cached copy of what was looked at.
@MainActor
final class ViewedListings: ObservableObject {
    static let shared = ViewedListings()

    struct Sighting: Codable, Equatable, Identifiable {
        let id: String
        var viewedAt: Date
    }

    /// Most recent first. Ordered rather than a bare dictionary because this is
    /// also the running order of the recently-viewed strip; membership goes
    /// through `index` instead, since it is checked once per card per render.
    @Published private(set) var sightings: [Sighting] = []
    private var index: [String: Date] = [:]

    private let defaults: UserDefaults
    private static let key = "viewedListings"

    /// Old sightings fall off the end, and a listing that falls off can look new
    /// again. At two thousand that needs a user who has opened two thousand
    /// listings *and* meets one from before that all again — Marketplace stock
    /// turns over long before then. The cap is here so the record can't grow
    /// without bound, not because forgetting is wanted.
    static let limit = 2000

    /// How many the home screen offers. A strip, not an archive.
    static let recentStripLength = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([Sighting].self, from: data) {
            var seen = Set<String>()
            sightings = decoded.compactMap { sighting in
                let id = ListingCache.shared.profile(for: sighting.id)?.listing?.id ?? sighting.id
                guard seen.insert(id).inserted else { return nil }
                return Sighting(id: id, viewedAt: sighting.viewedAt)
            }
            index = Dictionary(sightings.map { ($0.id, $0.viewedAt) },
                               uniquingKeysWith: { first, _ in first })
            persist()
        }
    }

    var isEmpty: Bool { sightings.isEmpty }

    /// Ids in view order, most recent first.
    var ids: [String] { sightings.map(\.id) }

    func contains(_ id: String) -> Bool { index[id] != nil }

    /// When this listing was last opened, or nil if it never was.
    func viewedAt(_ id: String) -> Date? { index[id] }

    /// Everything seen, as a set — for filtering a whole result set in one pass
    /// rather than a lookup per card.
    var allIDs: Set<String> { Set(index.keys) }

    /// Records an open. Re-opening something moves it to the front and updates
    /// the timestamp rather than adding a second row: this is a record of
    /// listings, not of visits, and nothing downstream wants the same listing
    /// twice in the recently-viewed strip.
    func record(_ id: String, at date: Date = Date()) {
        index[id] = date
        if let existing = sightings.firstIndex(where: { $0.id == id }) {
            sightings.remove(at: existing)
        }
        sightings.insert(Sighting(id: id, viewedAt: date), at: 0)
        if sightings.count > Self.limit {
            for dropped in sightings[Self.limit...] { index.removeValue(forKey: dropped.id) }
            sightings.removeSubrange(Self.limit...)
        }
        persist()
    }

    func forget(_ id: String) {
        guard index.removeValue(forKey: id) != nil else { return }
        sightings.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        guard !sightings.isEmpty else { return }
        sightings = []
        index = [:]
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(sightings) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
