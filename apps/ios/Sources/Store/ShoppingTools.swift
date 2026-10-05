import CoreLocation
import Foundation
import OpenMarketProtos
import WebKit

@MainActor
final class ShoppingTools: ObservableObject {
    struct Area: Equatable {
        let slug: String
        let name: String
        let latitude: Double?
        let longitude: Double?
        let radiusKM: Int
        var coordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        var summary: String { "\(name), \(radiusKM == 0 ? "any distance" : "within \(radiusKM) km"). Distances may be approximate." }
        @MainActor init?(prefs: Preferences) {
            guard let slug = prefs.locationSlug, !slug.isEmpty else { return nil }
            self.slug = slug; name = prefs.locationName ?? slug
            latitude = prefs.resolvedPlace?.coordinate.latitude
            longitude = prefs.resolvedPlace?.coordinate.longitude
            radiusKM = prefs.radiusKM
        }
    }
    @MainActor private final class Search {
        let query: SearchQuery
        let actor: String
        let engine = DesktopFeedEngine(session: .authed)
        lazy var client = AuthenticatedFeedClient(webView: engine.webView)
        var pagination = GraphQLFeedPagination()
        var browser = false
        var seen = Set<String>()
        var emptyPages = 0
        init(query: SearchQuery, actor: String) { self.query = query; self.actor = actor }
    }
    @Published private(set) var webViews: [WKWebView] = []
    private let detail = DetailEngine(session: .authed)
    private let feedLoader: (any GraphQLFeedLoading)?
    private let actorProvider: @MainActor () async -> String?
    private let detailLoader: (@MainActor (Listing) async -> ListingDetail?)?
    private var searches: [Search] = []
    private var cursors: [String: Search] = [:]
    private(set) var listings: [String: Listing] = [:]
    private var area: Area?
    private var completedResults: [String: ShoppingToolResult] = [:]

    init(feedLoader: (any GraphQLFeedLoading)? = nil,
         actorProvider: @escaping @MainActor () async -> String? = { await SessionState.facebookActor() },
         detailLoader: (@MainActor (Listing) async -> ListingDetail?)? = nil) {
        self.feedLoader = feedLoader
        self.actorProvider = actorProvider
        self.detailLoader = detailLoader
        webViews = [detail.webView]
    }
    func begin(_ area: Area) {
        self.area = area
        searches = []; cursors = [:]; completedResults = [:]; listings = [:]
        webViews = [detail.webView]
    }
    func reset() {
        stopLoading(); searches = []; cursors = [:]; listings = [:]; area = nil; completedResults = [:]
        webViews = [detail.webView]
    }
    func stopLoading() { webViews.forEach { $0.stopLoading() } }
    func remember(_ observations: [ShoppingListing]) {
        for observation in observations { listings[observation.id] = observation.parsed }
    }
    static func query(_ q: ShoppingSearch, area: Area) throws -> SearchQuery {
        guard !q.query.isEmpty else { throw APIError.message("Search needs a query.") }
        let sort: SearchQuery.Sort
        switch q.sort {
        case "", "best_match": sort = .bestMatch
        case "newest": sort = .newest
        case "nearest": sort = .nearest
        case "price_lowest": sort = .priceLowest
        case "price_highest": sort = .priceHighest
        default: throw APIError.message("Unsupported search sort.")
        }
        let delivery: SearchQuery.Delivery
        switch q.delivery {
        case "", "any": delivery = .any
        case "local_pickup": delivery = .localPickup
        case "shipping": delivery = .shipping
        default: throw APIError.message("Unsupported delivery filter.")
        }
        let availability: SearchQuery.Availability
        switch q.availability {
        case "", "available": availability = .available
        case "any": availability = .any
        case "unavailable": availability = .unavailable
        default: throw APIError.message("Unsupported availability filter.")
        }
        guard let age = SearchQuery.Age(rawValue: Int(q.listedWithinDays)) else { throw APIError.message("Unsupported listing age.") }
        let conditions = q.conditions.compactMap(SearchQuery.Condition.init(rawValue:))
        guard conditions.count == q.conditions.count, (!q.hasMinPrice || q.minPrice >= 0),
              (!q.hasMaxPrice || q.maxPrice >= 0),
              !(q.hasMinPrice && q.hasMaxPrice && q.minPrice > q.maxPrice) else { throw APIError.message("Invalid search filters.") }
        return SearchQuery(kind: .search(q.query), radiusKM: area.radiusKM, citySlug: area.slug,
                           coordinate: area.coordinate, sort: sort, delivery: delivery, age: age,
                           availability: availability, conditions: conditions,
                           minPrice: q.hasMinPrice ? Int(q.minPrice) : nil,
                           maxPrice: q.hasMaxPrice ? Int(q.maxPrice) : nil)
    }

    func execute(_ call: ShoppingToolCall) async throws -> ShoppingToolResult {
        try Task.checkCancellation()
        if let cached = completedResults[call.id] { return cached }
        guard await actorProvider() != nil else { throw APIError.message("Connect Facebook to continue.") }
        var result = ShoppingToolResult()
        result.callID = call.id
        switch call.action {
        case .search(let args):
            result = try await search(args, callID: call.id)
        case .inspect(let args):
            guard var listing = listings[args.listingID], let url = listing.itemURL else { throw APIError.message("This product is no longer in the chat.") }
            let loaded: ListingDetail?
            if let detailLoader { loaded = await detailLoader(listing) }
            else { loaded = await detail.loadDetail(id: listing.id, url: url) }
            guard let parsed = loaded else { throw APIError.message("Couldn't load this listing's details.") }
            listing.detail = parsed
            listing.capturedAt = Date()
            if listing.locationText == nil { listing.locationText = parsed.locationText }
            listings[listing.id] = listing
            result.listings = [ShoppingListing(listing, source: "item_detail")]
        case .display(let args):
            guard args.products.allSatisfy({ listings[$0.listingID] != nil }) else { throw APIError.message("A displayed product is missing.") }
            result.displayedIds = args.products.map(\.listingID)
        case nil: throw APIError.message("Unsupported assistant action.")
        }
        guard (try result.serializedData()).count <= 250_000,
              try result.listings.allSatisfy({ try $0.serializedData().count <= 49_000 }) else {
            throw APIError.message("The listing data is too large to send completely.")
        }
        completedResults[call.id] = result
        try Task.checkCancellation()
        return result
    }

    private func search(_ args: ShoppingSearch, callID: String) async throws -> ShoppingToolResult {
        guard let area, let actor = await actorProvider() else { throw APIError.message("Set a location and connect Facebook first.") }
        let query = try Self.query(args, area: area)
        let search: Search
        if args.cursor.isEmpty {
            guard searches.count < 6 else { throw APIError.message("Search limit reached.") }
            search = Search(query: query, actor: actor)
            searches.append(search)
            webViews.append(search.engine.webView)
            await Task.yield()
        } else {
            guard let existing = cursors[args.cursor], existing.query == query, existing.actor == actor else {
                throw APIError.message("This page cursor expired. Start at page one.")
            }
            search = existing
        }
        var page: [Listing] = []
        var more = false
        var source = "authenticated_graphql"
        if !search.browser {
            do {
                let response = try await (feedLoader ?? search.client).page(for: query, cursor: search.pagination.cursor)
                let payload = try search.pagination.accept(response)
                page = payload.enumerated().map { Self.canonical($0.element.makeListing(cardIndex: $0.offset)) }
                more = response.hasNextPage
            } catch let error as GraphQLFeedError where error.permitsBrowserFallback && args.cursor.isEmpty {
                search.browser = true
            }
        }
        if search.browser {
            source = "browser_search"
            if args.cursor.isEmpty {
                let payload = await search.engine.load(query)
                page = payload.enumerated().map { Self.canonical($0.element.makeListing(cardIndex: $0.offset)) }
                if page.isEmpty {
                    page = await search.engine.renderedCards().enumerated().compactMap {
                        DesktopCardParser.parse($0.element, cardIndex: $0.offset).map(Self.canonical)
                    }
                }
                more = search.engine.canLoadMore
            } else {
                switch await search.engine.scrollOnce() {
                case .advanced: more = true
                case .exhausted: more = false
                case .indeterminate: throw APIError.message("Could not confirm the next page. Try a new search.")
                }
                page = await search.engine.renderedCards().enumerated().compactMap {
                    DesktopCardParser.parse($0.element, cardIndex: $0.offset).map(Self.canonical)
                }
            }
            if case .loginWall = search.engine.state { throw APIError.message("Facebook needs you to sign in again.") }
            if case .failed = search.engine.state { throw APIError.message("Marketplace search could not load.") }
        }
        try Task.checkCancellation()
        page = page.filter { $0.itemURL?.marketplaceItemID != nil && $0.title?.isEmpty == false && search.seen.insert($0.id).inserted }
        search.emptyPages = page.isEmpty ? search.emptyPages + 1 : 0
        if search.emptyPages >= 2 && more { throw APIError.message("Pagination stopped making progress. Try another search.") }
        await DistanceResolver.shared.resolveAll(page.map(\.locationText))
        if area.radiusKM > 0, let origin = area.coordinate {
            let center = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            page = page.filter { listing in
                guard let point = DistanceResolver.shared.coordinate(for: listing.locationText) else { return true }
                return CLLocation(latitude: point.latitude, longitude: point.longitude).distance(from: center) <= Double(area.radiusKM) * 1000
            }
        }
        for listing in page { listings[listing.id] = listing }
        var result = ShoppingToolResult()
        result.callID = callID
        result.listings = page.map { ShoppingListing($0, source: source) }
        result.hasMore_p = more
        result.paginationStatus = more ? "more" : "exhausted"
        if more { let handle = UUID().uuidString; cursors[handle] = search; result.nextCursor = handle }
        if !args.cursor.isEmpty { cursors.removeValue(forKey: args.cursor) }
        result.appliedSettings = "\(area.summary) Query: \(args.query); sort: \(query.sort.rawValue); delivery: \(query.delivery.rawValue); price: \(query.minPrice.map(String.init) ?? "any")–\(query.maxPrice.map(String.init) ?? "any"); conditions: \(args.conditions.joined(separator: ",")); age: \(args.listedWithinDays); availability: \(query.availability.rawValue). Source filters may be approximate; verify details. Unknown distances are retained."
        return result
    }
    private static func canonical(_ listing: Listing) -> Listing {
        guard let id = listing.itemURL?.marketplaceItemID else { return listing }
        var value = Listing(id: "fb:\(id)", title: listing.title, priceText: listing.priceText,
                            originalPriceText: listing.originalPriceText, locationText: listing.locationText,
                            conditionText: listing.conditionText, fulfillment: listing.fulfillment,
                            thumbnailURL: listing.thumbnailURL, itemURL: listing.itemURL,
                            badgeText: listing.badgeText, cardIndex: listing.cardIndex, capturedAt: listing.capturedAt)
        value.detail = listing.detail
        return value
    }
}
