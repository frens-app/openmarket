import Foundation
import CoreLocation

/// A search, and the filters applied to it.
///
/// The filters are the reason search moved to the desktop surface: Facebook
/// honours every one of them there and strips all of them on mobile
/// (`docs/filter-parameters.md`). They are applied *server-side*, so the ~15
/// structured results a desktop page returns are drawn from the whole filtered
/// corpus rather than being the first 15 of an unfiltered list — which is what
/// makes a 15-result surface viable as the primary search path.
///
/// Parameter names and values were read off Facebook's own controls rather than
/// guessed, by driving them and watching `location.href`.
struct SearchQuery: Equatable {
    enum Kind: Equatable {
        case search(String)
        case category(String)
        /// No search term: Facebook's own Marketplace feed for a place.
        ///
        /// Back, after being removed once, and now the whole of Discover.
        ///
        /// It was dropped because logged out it is a rotating popularity pool
        /// rather than a recommendation — three loads of the identical URL gave
        /// 0 of 5 cards in common, then 17 of 20, then a revert to the first
        /// (`docs/discover.md` §3). That measurement still stands; what changed
        /// is what it is being compared against. The replacement was three of
        /// the user's own searches re-run per fill, which cost three page loads
        /// before anything could be drawn and could never show a category the
        /// user hadn't already asked for.
        ///
        /// With an account behind it the objection lifts as well: Facebook has
        /// the user's own history to rank against, and the feed scrolls
        /// indefinitely rather than stopping at ~24 cards.
        ///
        /// Note what this URL carries: **nothing**. No sort, no delivery
        /// method, no price bounds — this is the default Discover screen as
        /// Facebook serves it, and those parameters have never been verified on
        /// a browse path anyway (README's surface table lists them `?`). The one
        /// constraint that survives is the radius, applied on the device like
        /// everywhere else.
        case browse
    }

    /// Verified against result sets, not just parameter survival.
    /// `creation_time_descend` is genuinely newest-first — the first and last of
    /// 24 results were listed one and nine hours ago.
    enum Sort: String, Equatable, CaseIterable {
        case bestMatch = "best_match"
        case newest = "creation_time_descend"
        case nearest = "distance_ascend"
        case priceLowest = "price_ascend"
        case priceHighest = "price_descend"

        var label: String {
            switch self {
            case .bestMatch: return "Suggested"
            case .newest: return "Newest first"
            case .nearest: return "Nearest first"
            case .priceLowest: return "Price: low to high"
            case .priceHighest: return "Price: high to low"
            }
        }
    }

    /// `SHIPPING_ONSITE` marked 24 of 24 cards on a shipping-filtered page and
    /// none on a local one, so this is a real server-side split rather than a
    /// relabelling.
    enum Delivery: String, Equatable {
        case any = ""
        case localPickup = "local_pick_up"
        case shipping = "shipping"
    }

    /// Facebook offers exactly these three windows.
    ///
    /// This is the better recency lever for a local browser: `daysSinceListed=1`
    /// kept 10 of 15 results in the requested city, where
    /// `sortBy=creation_time_descend` returned a fresher but far-flung set
    /// (Stockton, Davis, Sacramento). Freshness without losing locality.
    enum Age: Int, Equatable, CaseIterable {
        case any = 0
        case day = 1
        case week = 7
        case month = 30

        var label: String {
            switch self {
            case .any: return "Any time"
            case .day: return "Last 24 hours"
            case .week: return "Last week"
            case .month: return "Last month"
            }
        }
    }

    /// Whether the item is still for sale.
    ///
    /// The one parameter that reaches listings the default search will not show
    /// you at all: a plain search returns 0 sold and 0 pending cards, so
    /// everything the app has ever seen is by construction still available.
    ///
    /// `out of stock` means *unavailable*, which is Pending **and** Sold
    /// together — the caller has to separate them on `is_sold`, and the mix
    /// depends heavily on how it is combined (`docs/filter-parameters.md` §10).
    enum Availability: String, Equatable {
        case any = ""
        case available = "in stock"
        case unavailable = "out of stock"
    }

    enum Condition: String, Equatable, CaseIterable {
        case new
        case usedLikeNew = "used_like_new"
        case usedGood = "used_good"
        case usedFair = "used_fair"

        var label: String {
            switch self {
            case .new: return "New"
            case .usedLikeNew: return "Used - Like New"
            case .usedGood: return "Used - Good"
            case .usedFair: return "Used - Fair"
            }
        }
    }

    var kind: Kind
    var radiusKM: Int
    var citySlug: String
    var coordinate: CLLocationCoordinate2D?

    var sort: Sort = .bestMatch
    var delivery: Delivery = .any
    var age: Age = .any
    var availability: Availability = .any
    var conditions: [Condition] = []
    var minPrice: Int?
    var maxPrice: Int?

    static func == (lhs: SearchQuery, rhs: SearchQuery) -> Bool {
        lhs.kind == rhs.kind && lhs.radiusKM == rhs.radiusKM && lhs.citySlug == rhs.citySlug
            && lhs.sort == rhs.sort && lhs.delivery == rhs.delivery && lhs.age == rhs.age
            && lhs.availability == rhs.availability && lhs.conditions == rhs.conditions
            && lhs.minPrice == rhs.minPrice && lhs.maxPrice == rhs.maxPrice
            && lhs.coordinate?.latitude == rhs.coordinate?.latitude
            && lhs.coordinate?.longitude == rhs.coordinate?.longitude
    }

    var displayName: String {
        switch kind {
        case .search(let term): return term
        case .category(let name): return name
        case .browse: return "Nearby"
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"

        var items: [URLQueryItem] = []
        switch kind {
        case .search(let term):
            components.path = "/marketplace/\(citySlug)/search/"
            items.append(URLQueryItem(name: "query", value: term))
        case .category(let name):
            components.path = "/marketplace/\(citySlug)/\(Self.categorySlug(name))/"
        case .browse:
            // Bare, and returned early: the point of this path is to be the
            // screen Facebook would have shown, so it carries no parameters at
            // all — not even the `radius` that every other query sends for
            // shape. Distance is enforced on the device.
            components.path = "/marketplace/\(citySlug)/"
            return components.url!
        }

        if sort != .bestMatch {
            items.append(URLQueryItem(name: "sortBy", value: sort.rawValue))
        }
        if delivery != .any {
            items.append(URLQueryItem(name: "deliveryMethod", value: delivery.rawValue))
        }
        if age != .any {
            items.append(URLQueryItem(name: "daysSinceListed", value: String(age.rawValue)))
        }
        // Spaces and all — "out of stock" is the literal value Facebook's own
        // control emits, and `URLComponents` percent-encodes it correctly.
        if availability != .any {
            items.append(URLQueryItem(name: "availability", value: availability.rawValue))
        }
        if !conditions.isEmpty {
            // Comma-separated, no spaces — the shape Facebook's own checkboxes
            // produce.
            items.append(URLQueryItem(name: "itemCondition",
                                      value: conditions.map(\.rawValue).joined(separator: ",")))
        }
        if let minPrice {
            items.append(URLQueryItem(name: "minPrice", value: String(minPrice)))
        }
        if let maxPrice {
            items.append(URLQueryItem(name: "maxPrice", value: String(maxPrice)))
        }

        // Kilometres, despite the UI showing miles — and inert. Mobile strips it
        // outright, and desktop only repaints its own chip: `radius=8` and
        // `radius=161` return the same 15 listings, and a search labelled
        // "Within 5 mi" comes back with results 60 mi out. Sent because it costs
        // nothing and is the shape Facebook expects; distance is enforced
        // client-side against per-listing coordinates.
        // See docs/filter-parameters.md §3.
        items.append(URLQueryItem(name: "radius", value: String(radiusKM)))

        // No latitude/longitude: Facebook discards them and falls back to the
        // IP-inferred place. The city slug in the path is what actually moves
        // the result set; the user's coordinate is only needed locally, to
        // compute distances.
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    /// True when anything beyond the search term is narrowing the results.
    var hasActiveFilters: Bool {
        sort != .bestMatch || delivery != .any || age != .any || availability != .any
            || !conditions.isEmpty || minPrice != nil || maxPrice != nil
    }

    static func categorySlug(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: " ", with: "")
    }

    static func kilometresToMiles(_ km: Int) -> Int {
        Int((Double(km) * 0.621371).rounded())
    }

    /// The inverse, for the places that think in miles because the user does.
    ///
    /// Round-trips stably across the range in use — 10 mi → 16 km → 10 mi,
    /// 15 → 24 → 15, 25 → 40 → 25 — so a radius set in miles reads back as the
    /// same number of miles rather than drifting a mile per conversion.
    static func milesToKilometres(_ miles: Int) -> Int {
        Int((Double(miles) / 0.621371).rounded())
    }
}
