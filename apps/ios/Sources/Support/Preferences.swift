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
        static let lastAccountID = "lastAccountID"
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
    /// A matter between the search field and its own suggestions again, now
    /// that Discover no longer seeds from it — but the toggle stays, because
    /// the suggestion list is still a list of what you looked for, drawn on
    /// screen whenever the field takes focus. Someone looking for a gift needs
    /// a way to run that search without it waiting for them the next time.
    ///
    /// Off does not clear anything — existing history stays until cleared
    /// explicitly, which is the honest reading of "stop recording".
    @Published var recordSearchHistory: Bool { didSet { defaults.set(recordSearchHistory, forKey: Key.recordSearchHistory) } }
    @Published var radiusKM: Int { didSet { defaults.set(radiusKM, forKey: Key.radiusKM) } }

    /// The categories the user said they shop for, as `Interest` ids.
    ///
    /// Long-term storage on purpose: this is a standing statement about the
    /// person, not about a session, and it is the only thing the search field
    /// has to offer before they've searched for anything. Order is the order
    /// they were picked in.
    @Published var interests: [String] { didSet { defaults.set(interests, forKey: Key.interests) } }

    /// Whether this install considers onboarding done.
    ///
    /// A stored flag rather than a purely derived one because the derived
    /// condition would go true the moment the last answer landed, tearing the
    /// screen away before the user could press the button under it.
    ///
    /// Written from the server's `viewer.onboardingCompleted` on every sign-in —
    /// the account is the authority — and cleared by `resetOnboarding`.
    @Published var hasCompletedOnboarding: Bool { didSet { defaults.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    // `hasAskedFacebook`, `hasChosenLocation` and `hasAskedNotifications` used to
    // live here. They recorded which onboarding steps had been *put to the user*,
    // and `OnboardingView` derived its position from them — which is exactly the
    // thing that made the flow jump. It runs a fixed sequence now and nothing
    // else ever read them, so they are gone rather than left to drift.

    /// Human-readable place name for the UI ("San Francisco, CA").
    @Published var locationName: String? { didSet { defaults.set(locationName, forKey: Key.locationName) } }
    /// Facebook's place segment used in the search path — a slug or numeric id.
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
        let previous = resolvedPlace
        resolvedPlace = place
        locationSlug = place.segment
        locationName = place.name

        // The only writer of a slug in the app, which makes it the only place a
        // change of city can be counted without every route — onboarding, the
        // filter sheet, the location sheet, the "change location" way out of an
        // empty grid — having to remember to.
        //
        // The city goes up — registered as a super property, so every later
        // event can be broken down by market — and the coordinate does not. That
        // is not the old §8 rule, which no longer governs this: a city is a fact
        // about a *search*, and a latitude and longitude to six decimal places
        // is a fact about where somebody sleeps. Nothing here is improved by
        // having the second one.
        Analytics.register(["city_slug": place.segment])
        // Both spelled out rather than passed through `rawValue`: those raw
        // values are storage keys in camelCase, and letting them become
        // breakdown rows would leave one chart in this workspace reading
        // "deviceFix" while every other property value is snake_case.
        Analytics.capture(.locationChanged, [
            "source": place.origin == .deviceFix ? "device_fix" : "searched_city",
            "segment_kind": place.segmentKind == .placeID ? "place_id" : "slug",
            "is_verified": place.isVerified,
            // A first place is onboarding finishing; a later one is somebody
            // deciding this app is looking in the wrong town. Same write, two
            // completely different findings.
            "is_first": previous == nil,
            "radius_km": radiusKM
        ])
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
    /// Usually empty now, so the fallback is the normal path rather than the
    /// safety net it started as.
    ///
    /// Two changes landed on the same day and they compound. Discover stopped
    /// reading interests at all — it loads Facebook's own browse page for
    /// everyone now (`discover.md` §0) — which left them feeding only the search
    /// field's "Try" list. Onboarding then stopped asking for them, because a
    /// required question about taste is a lot to charge for a row of
    /// suggestions. `Interest.defaults` fills that row for anyone who never
    /// visits Settings, and the user's own history takes over the moment they
    /// search for anything.
    var chosenInterests: [Interest] {
        let resolved = Interest.resolve(interests)
        return resolved.isEmpty ? Interest.defaults : resolved
    }

    /// Whether onboarding still has something to do.
    ///
    /// One requirement now, where there were two: somewhere to search. The
    /// interests clause went with the interests step — it was enforcing an
    /// answer nothing reads on the home screen any more.
    ///
    /// The place is re-checked on every launch rather than trusted to the flag
    /// alone, because it is the one answer the app genuinely cannot work
    /// without — every search is centred on it, and an install that somehow
    /// ends up without one would otherwise land on a home screen centred on
    /// nowhere. `hasCompletedOnboarding` is what keeps the flow on screen while
    /// the rest is being filled in.
    ///
    /// The skippable steps are deliberately not part of this. A "no" to Facebook
    /// or to notifications must not read as unfinished business, or declining
    /// would put the whole flow back on screen at every launch.
    var needsOnboarding: Bool {
        !hasCompletedOnboarding || resolvedPlace == nil
    }

    /// The account id this install last saw a session for.
    ///
    /// Kept only to notice that it *changed*. The install-shaped answers below —
    /// a place, whether Facebook was offered, whether notifications were asked
    /// for — belong to whoever is holding the phone, not to the device, and
    /// nothing else in the app can tell "signed back in" apart from "somebody
    /// else signed in".
    @Published var lastAccountID: String? { didSet { defaults.set(lastAccountID, forKey: Key.lastAccountID) } }

    /// Puts this install back to never-onboarded.
    ///
    /// Everything cleared here is *install*-shaped — asked once per device
    /// rather than once per account — which is exactly why it has to be cleared
    /// deliberately. Deleting an account drops the tokens and the server row,
    /// and would otherwise leave the next person to sign in on this phone
    /// browsing the last one's city, having never been asked where they are.
    ///
    /// The place goes with the rest. It is the one answer `needsOnboarding`
    /// re-checks, so leaving it behind would mean the flow reopened and then
    /// dismissed itself the moment a session existed.
    func resetOnboarding() {
        hasCompletedOnboarding = false
        resolvedPlace = nil
        locationSlug = nil
        locationName = nil
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
        lastAccountID = defaults.string(forKey: Key.lastAccountID)
        locationName = defaults.string(forKey: Key.locationName)
        // Kept as-is, with no validation against a curated list any more.
        //
        // That check existed because the app used to *guess* slugs, and five of
        // the twelve it shipped were not places Facebook recognises — a
        // rejected slug doesn't fail, it silently serves the IP-inferred city
        // (`docs/location-targeting.md` §1). Segments now come back from
        // Facebook's own location resolvers, so they are valid by construction,
        // and a whitelist would do nothing but delete perfectly good ones the
        // moment a user picked a city nobody thought to curate.
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

    /// Records a search the *user* ran, for the suggestions list.
    ///
    /// Two things never reach here, and both are deliberate:
    ///
    /// * **Anything the Tools tab searches.** Those terms are derived from the
    ///   item someone is drafting a listing for — they are the app asking a
    ///   question on the user's behalf, not the user looking for something to
    ///   buy, and offering them back as suggestions would answer a question
    ///   nobody asked. `SellerToolsModel` reads `Preferences` for location and
    ///   filters and never calls this.
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
