import Foundation
import Combine

/// §3.1 recent pills, §5 settings, §6 content filtering. All small and
/// non-sensitive, so UserDefaults is the right store.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let recentSearches = "recentSearches"
        static let recordSearchHistory = "recordSearchHistory"
        static let radiusKM = "radiusKM"
        static let interests = "interests"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let locationName = "locationName"
        static let locationSlug = "locationSlug"
        static let lastQueryKind = "lastQueryKind"
        static let lastQueryValue = "lastQueryValue"
        static let sortBy = "sortBy"
        static let deliveryMethod = "deliveryMethod"
        static let minPrice = "minPrice"
        static let maxPrice = "maxPrice"
        static let conditions = "itemConditions"
        static let hideViewed = "hideViewed"
        static let resolvedPlace = "resolvedPlace"
    }

    private let defaults: UserDefaults

    @Published var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    /// Whether a search the user runs is added to that list.
    ///
    /// It stopped being a private matter between the search field and its own
    /// suggestions the moment Discover started seeding from it: history is now
    /// the thing that decides what fills the home screen, so anything searched
    /// once shows up there until it ages out. Someone looking for a gift, or for
    /// something they'd rather not see on the first screen of the app, needs a
    /// way to run that search without it becoming the wallpaper.
    ///
    /// Off does not clear anything — existing history stays until cleared
    /// explicitly, which is the honest reading of "stop recording".
    @Published var recordSearchHistory: Bool { didSet { defaults.set(recordSearchHistory, forKey: Key.recordSearchHistory) } }
    @Published var radiusKM: Int { didSet { defaults.set(radiusKM, forKey: Key.radiusKM) } }

    /// The categories the user said they shop for, as `Interest` ids.
    ///
    /// Long-term storage on purpose: this is a standing statement about the
    /// person, not about a session, and it is the only thing the home screen
    /// has to go on before they've searched for anything. Order is the order
    /// they were picked in — Discover reads it as a preference ranking when it
    /// has to take a subset.
    @Published var interests: [String] { didSet { defaults.set(interests, forKey: Key.interests) } }

    /// Set by the last step of onboarding, and never cleared.
    ///
    /// A stored flag rather than a purely derived one because the derived
    /// condition goes true the instant the third interest is tapped, which
    /// would tear the screen away before the user could press Continue.
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }
    /// Human-readable place name for the UI ("San Francisco, CA").
    @Published var locationName: String? { didSet { defaults.set(locationName, forKey: Key.locationName) } }
    /// Facebook's city slug used in the search path ("sanfrancisco").
    @Published var locationSlug: String? { didSet { defaults.set(locationSlug, forKey: Key.locationSlug) } }
    /// The place Facebook resolved, and the coordinate that produced it.
    ///
    /// The record of *how* the current location was arrived at. `locationSlug`
    /// and `locationName` remain the things the query and the UI read, so
    /// nothing downstream has to know this exists — `setResolvedPlace` keeps
    /// all three in step, and is the only writer of a slug in the app.
    @Published private(set) var resolvedPlace: ResolvedPlace? {
        didSet {
            defaults.set(resolvedPlace.flatMap { try? JSONEncoder().encode($0) },
                         forKey: Key.resolvedPlace)
        }
    }

    func setResolvedPlace(_ place: ResolvedPlace) {
        resolvedPlace = place
        locationSlug = place.segment
        locationName = place.name
    }
    /// The last thing the user looked at, so reopening the app lands them back
    /// there instead of on an empty screen.
    @Published private(set) var lastQueryKind: String? { didSet { defaults.set(lastQueryKind, forKey: Key.lastQueryKind) } }
    @Published private(set) var lastQueryValue: String? { didSet { defaults.set(lastQueryValue, forKey: Key.lastQueryValue) } }

    /// Both are applied server-side by Facebook, so changing either means
    /// re-running the search rather than re-sorting what's on screen.
    @Published var sort: SearchQuery.Sort { didSet { defaults.set(sort.rawValue, forKey: Key.sortBy) } }
    /// Defaults to local pickup: this is a local-browsing app, and shipping
    /// listings are the main thing that makes a result set stop being local.
    /// `local_pick_up` returned 15 results with 0 shipping against a default
    /// page where shipping was mixed in throughout.
    @Published var delivery: SearchQuery.Delivery { didSet { defaults.set(delivery.rawValue, forKey: Key.deliveryMethod) } }

    /// Nil means unbounded on that end. Stored as -1 rather than absent so a
    /// cleared bound is distinguishable from never having set one.
    @Published var minPrice: Int? { didSet { defaults.set(minPrice ?? -1, forKey: Key.minPrice) } }
    @Published var maxPrice: Int? { didSet { defaults.set(maxPrice ?? -1, forKey: Key.maxPrice) } }

    /// Comma-joined raw values, which is also the shape Facebook's own
    /// `itemCondition` parameter takes.
    @Published var conditions: [SearchQuery.Condition] {
        didSet { defaults.set(conditions.map(\.rawValue).joined(separator: ","), forKey: Key.conditions) }
    }

    /// Hide listings the user has already opened (`ViewedListings`).
    ///
    /// Unlike everything above it, this one is ours: it is applied on device,
    /// against a record Facebook doesn't keep, and there is no parameter that
    /// would ask for it. Off by default — it is a way to re-scan a search you
    /// have already been through, not the normal way to browse.
    @Published var hideViewed: Bool { didSet { defaults.set(hideViewed, forKey: Key.hideViewed) } }

    static let maxRecentSearches = 12

    /// Kilometres, chosen so each one is a round number of *miles* — the unit
    /// the UI shows and the one people think in. 16 km is 10 mi, 32 is 20, and
    /// so on. The old ladder was round in kilometres and consequently showed
    /// "6 mi" and "62 mi".
    static let radiusOptions = [2, 3, 8, 16, 32, 64, 161]   // 1, 2, 5, 10, 20, 40, 100 mi

    /// 10 miles. An opinionated default for a local-browsing app: far enough to
    /// find things, close enough that collecting them is still plausible.
    static let defaultRadiusKM = 16

    // `widenStepMiles` and `widenedRadiusKM` lived here, for a footer that
    // offered "try 15 mi" when the distance filter had hidden things. Both are
    // gone with that footer (`ResultsView.discoverFooter`). The radius is a
    // deliberate setting, changed where it is set, and offering to widen it was
    // a lie for a signed-in user in any case: Facebook's account radius is a
    // floor this app cannot raise (`docs/filter-parameters.md` §11).

    /// The chosen interests, as things with labels and search terms.
    ///
    /// Never empty in a shipped app — onboarding won't let go of the screen
    /// until three are picked — but it falls back rather than trapping, because
    /// an empty home screen is a worse answer than a generic one if this ever
    /// does get reached with nothing stored.
    var chosenInterests: [Interest] {
        let resolved = Interest.resolve(interests)
        return resolved.isEmpty ? Interest.defaults : resolved
    }

    /// Whether the app's two requirements are met: somewhere to search, and
    /// enough interests to build a first screen out of.
    ///
    /// Both are re-checked on every launch rather than trusted to the flag
    /// alone, so an install that somehow ends up without a place — or with its
    /// interests emptied — is asked again instead of landing on a home screen
    /// that has nothing to show. `hasCompletedOnboarding` is what keeps the
    /// flow on screen while it is being filled in.
    var needsOnboarding: Bool {
        !hasCompletedOnboarding
            || resolvedPlace == nil
            || Interest.resolve(interests).count < Interest.minimum
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        // Defaults on, and `object(forKey:)` is what makes that possible —
        // `bool(forKey:)` returns false for a key that was never written, which
        // would silently ship history recording turned off for every existing
        // install.
        recordSearchHistory = defaults.object(forKey: Key.recordSearchHistory) as? Bool ?? true
        // Stored as-is, off-ladder values included.
        //
        // This used to snap to the nearest rung, from a one-time migration when
        // the ladder changed from round kilometres to round miles. Nothing
        // writes an off-ladder value any more — the results screen's "try 15 mi"
        // button was the last one — but installs carrying one from that era are
        // still out there, and silently moving somebody's radius on launch is
        // worse than showing a number the picker didn't offer. It renders
        // whatever is set (`LocationPickerSheet`), so nothing needs a rung.
        radiusKM = defaults.object(forKey: Key.radiusKM) as? Int ?? Self.defaultRadiusKM
        interests = defaults.stringArray(forKey: Key.interests) ?? []
        // Deliberately a new key rather than a rename of `hasSeenFirstRun`.
        //
        // The old first run was three explanatory cards and asked for nothing,
        // so an install that has "seen" it has still never chosen a place or an
        // interest — exactly the two things the home screen now needs. Reading
        // the old flag would let those installs through to a Discover with
        // nothing behind it. They get asked once, like everyone else.
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        locationName = defaults.string(forKey: Key.locationName)
        // Kept as-is, with no validation against a curated list any more.
        //
        // That check existed because the app used to *guess* slugs, and five of
        // the twelve it shipped were not places Facebook recognises — a
        // rejected slug doesn't fail, it silently serves the IP-inferred city
        // (`docs/location-targeting.md` §1). Slugs now come back from
        // Facebook's own picker (`MarketplacePlaceResolver`), so they are valid
        // by construction, and a whitelist would do nothing but delete
        // perfectly good ones the moment a user picked a city nobody thought
        // to curate.
        locationSlug = defaults.string(forKey: Key.locationSlug)
        resolvedPlace = (defaults.data(forKey: Key.resolvedPlace))
            .flatMap { try? JSONDecoder().decode(ResolvedPlace.self, from: $0) }
        lastQueryKind = defaults.string(forKey: Key.lastQueryKind)
        lastQueryValue = defaults.string(forKey: Key.lastQueryValue)
        sort = defaults.string(forKey: Key.sortBy)
            .flatMap(SearchQuery.Sort.init(rawValue:)) ?? .bestMatch
        delivery = defaults.string(forKey: Key.deliveryMethod)
            .flatMap(SearchQuery.Delivery.init(rawValue:)) ?? .localPickup
        let storedMin = defaults.object(forKey: Key.minPrice) as? Int ?? -1
        let storedMax = defaults.object(forKey: Key.maxPrice) as? Int ?? -1
        minPrice = storedMin >= 0 ? storedMin : nil
        maxPrice = storedMax >= 0 ? storedMax : nil
        conditions = (defaults.string(forKey: Key.conditions) ?? "")
            .split(separator: ",")
            .compactMap { SearchQuery.Condition(rawValue: String($0)) }
        hideViewed = defaults.bool(forKey: Key.hideViewed)
    }

    /// Back to the app's opinionated defaults, not to "no filters at all" —
    /// local pickup and a 10-mile radius are the product's position on what a
    /// local marketplace browser should show, so Reset restores them rather
    /// than clearing them.
    func resetFilters() {
        sort = .bestMatch
        delivery = .localPickup
        radiusKM = Self.defaultRadiusKM
        minPrice = nil
        maxPrice = nil
        conditions = []
        hideViewed = false
    }

    /// Whether anything differs from those defaults — drives the dot on the
    /// Filters button.
    var hasNonDefaultFilters: Bool {
        sort != .bestMatch
            || delivery != .localPickup
            || radiusKM != Self.defaultRadiusKM
            || minPrice != nil
            || maxPrice != nil
            || !conditions.isEmpty
            || hideViewed
    }

    /// Remembers what to reopen on. Categories are remembered too — browsing
    /// "Free Stuff" is just as much "where I was" as typing a search.
    func recordLastQuery(_ kind: SearchQuery.Kind) {
        switch kind {
        case .search(let term):
            lastQueryKind = "search"
            lastQueryValue = term
        case .category(let name):
            lastQueryKind = "category"
            lastQueryValue = name
        // Nothing to remember: browse is the home screen, which is where an
        // app with no last query opens anyway. Recording it would make
        // "reopen where I left off" mean "reopen on the screen you get for
        // free", and it isn't a query the user ran.
        case .browse:
            break
        }
    }

    var lastQuery: SearchQuery.Kind? {
        guard let lastQueryValue, !lastQueryValue.isEmpty else { return nil }
        switch lastQueryKind {
        case "search": return .search(lastQueryValue)
        case "category": return .category(lastQueryValue)
        default: return nil
        }
    }

    func clearLastQuery() {
        lastQueryKind = nil
        lastQueryValue = nil
    }

    /// Records a search the *user* ran, for the suggestions list and for
    /// Discover's seeds.
    ///
    /// Two things never reach here, and both are deliberate:
    ///
    /// * **Anything the Seller tab searches.** Those terms are derived from the
    ///   item someone is drafting a listing for — they are the app asking a
    ///   question on the user's behalf, not the user looking for something to
    ///   buy. Seeding Discover with them would fill the home screen with the
    ///   thing you are trying to sell, which is precisely backwards.
    ///   `SellerToolsModel` reads `Preferences` for location and filters and
    ///   never calls this.
    /// * **Anything at all, when `recordSearchHistory` is off.** Enforced here
    ///   rather than at the call site so a future caller can't forget.
    func recordSearch(_ term: String) {
        guard recordSearchHistory else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        recentSearches = Array(next.prefix(Self.maxRecentSearches))
    }

    func removeSearch(_ term: String) {
        recentSearches.removeAll { $0.caseInsensitiveCompare(term) == .orderedSame }
    }

}
