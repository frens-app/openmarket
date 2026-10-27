import Foundation
import Combine

/// Recent pills, settings and content filtering. All small and
/// non-sensitive, so UserDefaults is the right store.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private enum Key {
        static let recentSearches = "recentSearches"
        static let searchCounts = "searchCounts"
        static let hasTappedAlertsTab = "hasTappedAlertsTab"
        static let recordSearchHistory = "recordSearchHistory"
        static let radiusKM = "radiusKM"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let lastAccountID = "lastAccountID"
        static let locationName = "locationName"
        static let locationSlug = "locationSlug"
        static let sortBy = "sortBy"
        static let deliveryMethod = "deliveryMethod"
        static let minPrice = "minPrice"
        static let maxPrice = "maxPrice"
        static let conditions = "itemConditions"
        static let hideViewed = "hideViewed"
        static let resolvedPlace = "resolvedPlace"
    }

    private let defaults: UserDefaults

    @Published private(set) var recentSearches: [String] { didSet { defaults.set(recentSearches, forKey: Key.recentSearches) } }
    @Published private var searchCounts: [String: Int] { didSet { defaults.set(searchCounts, forKey: Key.searchCounts) } }
    @Published var hasTappedAlertsTab: Bool { didSet { defaults.set(hasTappedAlertsTab, forKey: Key.hasTappedAlertsTab) } }
    /// Whether a search the user runs is added to that list. Off does not clear
    /// anything — existing history stays until cleared explicitly.
    @Published var recordSearchHistory: Bool { didSet { defaults.set(recordSearchHistory, forKey: Key.recordSearchHistory) } }
    @Published var radiusKM: Int { didSet { defaults.set(radiusKM, forKey: Key.radiusKM) } }

    /// Whether this install considers onboarding done.
    ///
    /// Stored rather than derived: the derived condition would go true the
    /// moment the last answer landed, tearing the screen away before the user
    /// could press the button under it. Written from the server's
    /// `viewer.onboardingCompleted` on every sign-in — the account is the
    /// authority — and cleared by `resetOnboarding`.
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    /// Human-readable place name for the UI ("San Francisco, CA").
    @Published var locationName: String? { didSet { defaults.set(locationName, forKey: Key.locationName) } }
    /// Facebook's place segment used in the search path — a slug or numeric id.
    @Published var locationSlug: String? { didSet { defaults.set(locationSlug, forKey: Key.locationSlug) } }
    /// The place Facebook resolved, and the coordinate that produced it.
    ///
    /// The query and the UI still read `locationSlug` and `locationName`;
    /// `setResolvedPlace` keeps all three in step and is the app's only writer
    /// of a slug.
    @Published private(set) var resolvedPlace: ResolvedPlace? {
        didSet {
            defaults.set(resolvedPlace.flatMap { try? JSONEncoder().encode($0) },
                         forKey: Key.resolvedPlace)
        }
    }

    func setResolvedPlace(_ place: ResolvedPlace) {
        // `PlaceChooser` performs this check before spending the Facebook
        // request, and this second boundary keeps a future writer from storing
        // an unverified market by accident. Nil is accepted only for places
        // saved by older releases, before country codes were persisted.
        guard place.countryCode == nil
                || MarketRegion.region(countryCode: place.countryCode)?.marketplaceVerified == true else {
            return
        }
        let previous = resolvedPlace
        resolvedPlace = place
        locationSlug = place.segment
        locationName = place.name

        // The app's only writer of a slug, so the only place every route to a
        // change of city passes through. The city is registered as a super
        // property; the coordinate behind it is not sent.
        Analytics.register(["city_slug": place.segment])
        // Spelled out: the raw values are camelCase storage keys, and every
        // other property value in the workspace is snake_case.
        Analytics.capture(.locationChanged, [
            "source": place.origin == .deviceFix ? "device_fix" : "searched_city",
            "segment_kind": place.segmentKind == .placeID ? "place_id" : "slug",
            "is_verified": place.isVerified,
            // A first place is onboarding finishing; a later one is somebody
            // deciding the app is looking in the wrong town.
            "is_first": previous == nil,
            "radius_km": radiusKM
        ])
    }
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

    var currencySymbol: String {
        MarketRegion.region(countryCode: resolvedPlace?.countryCode)?.currency.localSymbol ?? "$"
    }

    var priceFilterLabel: String {
        switch (minPrice, maxPrice) {
        case let (min?, max?): "\(currencySymbol)\(min)–\(currencySymbol)\(max)"
        case let (nil, max?): "Under \(currencySymbol)\(max)"
        case let (min?, nil): "Over \(currencySymbol)\(min)"
        default: "Any price"
        }
    }

    /// Comma-joined raw values, which is also the shape Facebook's own
    /// `itemCondition` parameter takes.
    @Published var conditions: [SearchQuery.Condition] {
        didSet { defaults.set(conditions.map(\.rawValue).joined(separator: ","), forKey: Key.conditions) }
    }

    /// Hide listings the user has already opened (`ViewedListings`).
    ///
    /// Unlike the filters above, this one is applied on device against a record
    /// Facebook doesn't keep. Off by default — a way to re-scan a search you
    /// have been through, not the normal way to browse.
    @Published var hideViewed: Bool { didSet { defaults.set(hideViewed, forKey: Key.hideViewed) } }

    static let maxRecentSearches = 12

    /// Kilometres, chosen so each is a round number of *miles* — the unit the UI
    /// shows. A ladder round in kilometres shows "6 mi" and "62 mi".
    static let radiusOptions = [2, 3, 8, 16, 32, 64, 161]   // 1, 2, 5, 10, 20, 40, 100 mi

    /// 10 miles. Far enough to find things, close enough to collect them.
    static let defaultRadiusKM = 16

    /// Whether onboarding still has something to do.
    ///
    /// The place is re-checked every launch rather than trusted to the flag,
    /// because every search is centred on it and an install without one lands
    /// on a home screen centred on nowhere. The skippable steps are deliberately
    /// excluded: a "no" to Facebook or notifications must not reopen the flow at
    /// every launch.
    var needsOnboarding: Bool {
        !hasCompletedOnboarding || !hasBrowseablePlace
    }

    /// A confirmed place in a Marketplace whose output format the app has
    /// verified. A legacy saved place has no country code; it remains usable so
    /// this release does not force every existing user through onboarding. The
    /// next location choice records a code and becomes strictly gated.
    var hasBrowseablePlace: Bool {
        guard let resolvedPlace else { return false }
        guard let countryCode = resolvedPlace.countryCode else { return true }
        return MarketRegion.region(countryCode: countryCode)?.marketplaceVerified == true
    }

    /// The account id this install last saw a session for. Kept only to notice
    /// that it *changed* — nothing else in the app can tell "signed back in"
    /// apart from "somebody else signed in".
    @Published var lastAccountID: String? { didSet { defaults.set(lastAccountID, forKey: Key.lastAccountID) } }

    /// Puts this install back to never-onboarded.
    ///
    /// Everything cleared here is install-shaped — asked once per device, not
    /// per account — so deleting an account drops the tokens and the server row
    /// but would otherwise leave the next person to sign in on this phone
    /// browsing the last one's city.
    func resetOnboarding() {
        hasCompletedOnboarding = false
        resolvedPlace = nil
        locationSlug = nil
        locationName = nil
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Retire the selections saved by older versions of the app.
        defaults.removeObject(forKey: "interests")
        defaults.removeObject(forKey: "lastQueryKind")
        defaults.removeObject(forKey: "lastQueryValue")
        recentSearches = defaults.stringArray(forKey: Key.recentSearches) ?? []
        searchCounts = defaults.dictionary(forKey: Key.searchCounts) as? [String: Int] ?? [:]
        hasTappedAlertsTab = defaults.bool(forKey: Key.hasTappedAlertsTab)
        // `object(forKey:)`, not `bool(forKey:)`: the latter returns false for a
        // key that was never written, silently shipping history recording off
        // for every existing install.
        recordSearchHistory = defaults.object(forKey: Key.recordSearchHistory) as? Bool ?? true
        // Off-ladder values are kept as-is. Installs still carry them from an
        // older kilometre-round ladder, and `LocationPickerSheet` renders
        // whatever is set — silently moving somebody's radius is worse than
        // showing a number the picker didn't offer.
        radiusKM = defaults.object(forKey: Key.radiusKM) as? Int ?? Self.defaultRadiusKM
        hasCompletedOnboarding = defaults.bool(forKey: Key.hasCompletedOnboarding)
        lastAccountID = defaults.string(forKey: Key.lastAccountID)
        locationName = defaults.string(forKey: Key.locationName)
        // Not validated against a curated list: segments come back from
        // Facebook's own resolvers, so a whitelist would only delete good ones
        // for cities nobody thought to curate.
        locationSlug = defaults.string(forKey: Key.locationSlug)
        resolvedPlace = (defaults.data(forKey: Key.resolvedPlace))
            .flatMap { try? JSONDecoder().decode(ResolvedPlace.self, from: $0) }
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

    /// Back to the app's defaults, not to "no filters at all": local pickup and
    /// a 10-mile radius are restored rather than cleared.
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

    /// Records a search the *user* ran, for the suggestions list.
    ///
    /// Tools-tab searches deliberately never reach here: those terms are
    /// derived from an item someone is drafting a listing for, not something
    /// they were looking to buy. The `recordSearchHistory` check lives here
    /// rather than at the call sites so a future caller can't forget it.
    func recordSearch(_ term: String) {
        guard recordSearchHistory else { return }
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchCounts[trimmed.lowercased(), default: 0] += 1
        var next = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        next.insert(trimmed, at: 0)
        recentSearches = Array(next.prefix(Self.maxRecentSearches))
    }

    func searchCount(for term: String) -> Int {
        searchCounts[term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), default: 0]
    }

    /// Frequent recent searches, with recency breaking ties. Only suggest terms
    /// that can be submitted by the alert form.
    var suggestedAlertSearches: [String] {
        recentSearches.enumerated()
            .filter { (2...300).contains($0.element.count) }
            .sorted {
                let lhsCount = searchCount(for: $0.element)
                let rhsCount = searchCount(for: $1.element)
                return lhsCount == rhsCount ? $0.offset < $1.offset : lhsCount > rhsCount
            }
            .prefix(4)
            .map(\.element)
    }

    func clearSearchHistory() {
        recentSearches = []
        searchCounts = [:]
    }

}
