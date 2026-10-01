import Foundation
import os

extension Logger {
    static let cache = Logger(subsystem: "lol.frens.openmarket", category: "cache")
}

/// Everything known about one listing: the card as the grid saw it, plus the
/// detail read off its item page.
///
/// Both halves are optional and for different reasons. `card` is absent from
/// files written before the saved-items screen needed it. `detail` is absent
/// when a listing was saved in the couple of seconds before its first
/// enrichment landed — the save is still real, it just has nothing behind it
/// yet, and the next open fills it in.
struct CachedProfile: Codable {
    var card: Listing?
    var detail: ListingDetail?
    /// The canonical item URL, learned by tapping the card. Worth keeping
    /// separately from the detail: it's what lets a revalidation skip the feed
    /// entirely and load the page directly, which matters for a restored card
    /// whose position in the DOM is no longer known.
    var itemURL: URL?
    var fetchedAt: Date
    var usedAt: Date

    /// What the app was when this record was captured.
    ///
    /// Absent in files written before sessions existed, which decode as `nil` —
    /// correctly, since those predate any notion of being signed in and their
    /// seller fields are unknown rather than empty.
    var capture: CaptureContext?

    /// The two halves put back together, ready to render.
    var listing: Listing? {
        guard var listing = card else { return nil }
        listing.detail = detail
        listing.itemURL = listing.itemURL ?? itemURL
        return listing
    }

    /// Seller identity is only exposed to a signed-in desktop session, so a
    /// record captured any other way has *unknown* seller fields, not empty
    /// ones. The distinction matters because ratings are a primary signal for
    /// the business-seller filter, and treating "we never had a session" as
    /// "this seller is unrated" would corrupt it silently.
    var sellerFieldsAreKnown: Bool {
        capture?.canCarrySellerIdentity ?? false
    }

    /// Worth re-fetching now that a session exists.
    var wouldBenefitFromRefetch: Bool {
        detail != nil && !sellerFieldsAreKnown
    }
}

/// The cards from one search, as they were last seen.
///
/// Keyed by session as well as query URL because the *result set* differs by
/// authentication, not merely the fields on it: signed in, a San Francisco
/// query returned 15 San Francisco listings, where the same query signed out
/// spread to Martinez, Vallejo and Oakland. Restoring one under the other would
/// show the wrong listings, not merely a thinner version of the right ones.
struct CachedResults: Codable {
    var queryURL: String
    var listings: [Listing]
    var savedAt: Date
    var session: BrowserSession?
    var latitude: Double?
    var longitude: Double?
}

/// On-device persistence for two things with two different lifetimes.
///
/// **The last result set** — so a returning user sees their grid on the first
/// frame instead of a skeleton for the 5.13s it takes Facebook to serve and
/// hydrate a results page.
///
/// **Listing profiles** — full detail for listings actually opened, capped at
/// `profileLimit` and evicted least-recently-used. A tap paints from here
/// immediately; the live refetch that always follows is what keeps it honest.
///
/// Everything lives in memory and is mirrored to disk, so reads on the tap path
/// are synchronous and writes never block a frame. Nothing here is a source of
/// truth — Facebook is, and a cached profile is only ever a head start.
@MainActor
final class ListingCache {
    static let shared = ListingCache()

    /// Roughly a few MB at the ceiling: descriptions are already clamped to
    /// 1500 characters and galleries to 12 URLs.
    static let profileLimit = 1000

    private var profiles: [String: CachedProfile] = [:]
    private var results: CachedResults?
    private var saveTask: Task<Void, Never>?
    private let directory: URL
    /// Saved listings are user data, not cache. Letting the LRU evict one would
    /// quietly drop the detail behind something the user deliberately kept.
    private let isSaved: @MainActor (String) -> Bool

    private var profilesFile: URL { directory.appendingPathComponent("profiles.json") }
    private var resultsFile: URL { directory.appendingPathComponent("results.json") }

    init(directory: URL? = nil,
         isSaved: @escaping @MainActor (String) -> Bool = { SavedListings.shared.contains($0) }) {
        self.isSaved = isSaved
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MarketplaceCache", isDirectory: true)
        load()
    }

    // MARK: - Profiles

    /// Synchronous by design: this is read on the tap path, where the whole
    /// point is to have something on screen in the same frame.
    func profile(for id: String) -> CachedProfile? {
        guard var hit = profiles[id] else { return nil }
        hit.usedAt = Date()
        profiles[id] = hit          // keeps LRU honest without a second structure
        scheduleSave()
        return hit
    }

    /// Records everything currently known about a listing.
    ///
    /// A sighting can never reduce what we know (docs/data-model.md): a call
    /// carrying no detail — a save made before the first enrichment landed —
    /// keeps whatever was already there rather than blanking it.
    func store(_ listing: Listing, capture: CaptureContext? = nil) {
        let existing = profiles[listing.id]
        var card = listing
        card.detail = nil       // held alongside, not inside; don't store it twice

        // Keep the richer provenance. A record captured with a session knows
        // things a later anonymous sighting doesn't, so an unauthenticated
        // refresh must not downgrade the claim about what the stored fields
        // mean — the fields themselves are merged the same way.
        let mergedCapture: CaptureContext? = {
            guard let capture else { return existing?.capture }
            guard let old = existing?.capture else { return capture }
            return capture.canCarrySellerIdentity || !old.canCarrySellerIdentity ? capture : old
        }()

        profiles[listing.id] = CachedProfile(
            card: card,
            detail: listing.detail ?? existing?.detail,
            // Never trade a known URL for nil — a revalidation that couldn't
            // resolve the id shouldn't cost us the one we already had.
            itemURL: listing.itemURL ?? existing?.itemURL,
            fetchedAt: listing.detail != nil ? Date() : (existing?.fetchedAt ?? Date()),
            usedAt: Date(),
            capture: mergedCapture
        )
        evictIfNeeded()
        scheduleSave()
    }

    /// Profiles worth re-fetching now that a session exists — captured without
    /// one, so their seller fields are unknown rather than absent.
    func idsNeedingSellerRefresh() -> [String] {
        profiles.filter { $0.value.wouldBenefitFromRefetch }.map(\.key)
    }

    /// Saved listings, most recently saved first, skipping any whose profile
    /// has gone (nothing evicts a saved one, but a cache file can be deleted).
    func listings(for ids: [String]) -> [Listing] {
        ids.compactMap { profiles[$0]?.listing }
    }

    var profileCount: Int { profiles.count }

    /// Least-recently-used first, skipping anything saved. `usedAt` is touched
    /// on read, so the listings that survive are the ones being looked at, not
    /// merely the newest.
    private func evictIfNeeded() {
        guard profiles.count > Self.profileLimit else { return }
        let doomed = profiles
            .filter { !isSaved($0.key) }
            .sorted { $0.value.usedAt < $1.value.usedAt }
            .prefix(profiles.count - Self.profileLimit)
        for (id, _) in doomed { profiles.removeValue(forKey: id) }
        Logger.cache.info("evicted \(doomed.count) profiles, \(self.profiles.count) remain")
    }

    // MARK: - Results

    /// Only for the same query *and* the same session — a grid restored under a
    /// different search term would be actively misleading, and one restored
    /// under a different authentication state would show genuinely different
    /// listings rather than a subset (see `CachedResults`).
    ///
    /// A file written before sessions existed has no `session`, and is accepted
    /// only for an unauthenticated read: it was necessarily captured without one.
    func results(for query: SearchQuery, session: BrowserSession) -> [Listing]? {
        guard let results, results.queryURL == query.url.absoluteString else { return nil }
        guard (results.session ?? .unauthed) == session,
              results.latitude == query.coordinate?.latitude,
              results.longitude == query.coordinate?.longitude else { return nil }
        return results.listings.isEmpty ? nil : results.listings
    }

    func saveResults(_ listings: [Listing], for query: SearchQuery, session: BrowserSession) {
        results = CachedResults(queryURL: query.url.absoluteString,
                                listings: listings,
                                savedAt: Date(),
                                session: session,
                                latitude: query.coordinate?.latitude,
                                longitude: query.coordinate?.longitude)
        scheduleSave()
    }

    // MARK: - Disk

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: profilesFile),
           let decoded = try? decoder.decode([String: CachedProfile].self, from: data) {
            profiles = decoded
        }
        if let data = try? Data(contentsOf: resultsFile),
           let decoded = try? decoder.decode(CachedResults.self, from: data) {
            results = decoded
        }
        Logger.cache.info("loaded \(self.profiles.count) profiles, \(self.results?.listings.count ?? 0) cards")
    }

    /// Coalesced: a burst of writes during a prefetch produces one file write.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await self?.writeToDisk()
        }
    }

    /// Snapshot on the main actor, encode and write off it — a thousand
    /// profiles is megabytes, and none of it belongs on a frame.
    func writeToDisk() async {
        let profilesSnapshot = profiles
        let resultsSnapshot = results
        let directory = directory
        let profilesFile = profilesFile
        let resultsFile = resultsFile

        await Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? encoder.encode(profilesSnapshot) {
                try? data.write(to: profilesFile, options: .atomic)
            }
            if let resultsSnapshot, let data = try? encoder.encode(resultsSnapshot) {
                try? data.write(to: resultsFile, options: .atomic)
            }
        }.value
    }
}
