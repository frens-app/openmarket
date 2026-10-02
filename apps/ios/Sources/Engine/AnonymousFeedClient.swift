import Foundation
import CoreLocation
import os

actor AnonymousFeedClient: GraphQLFeedLoading {
    private let session: URLSession
    private let pacer: RequestPacer

    init(pacer: RequestPacer = .shared, configuration: URLSessionConfiguration = .ephemeral) {
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        self.session = URLSession(configuration: configuration)
        self.pacer = pacer
    }

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        let request = try Self.request(for: query, cursor: cursor)
        try Task.checkCancellation()
        guard await pacer.waitForSlot() else { throw GraphQLFeedError.paused }
        try Task.checkCancellation()
        let started = ContinuousClock.now
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw GraphQLFeedError.invalidResponse }
        if http.statusCode == 403 || http.statusCode == 429 {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode >= 500 { throw URLError(.badServerResponse) }
            throw GraphQLFeedError.invalidResponse
        }
        do {
            let page = try GraphQLFeedDecoder.decode(data, kind: query.kind)
            await pacer.recordSuccess()
            let milliseconds = Int(started.duration(to: .now) / .milliseconds(1))
            let surface = query.kind == .browse ? "browse" : "search"
            Logger(subsystem: "lol.frens.openmarket", category: "anonymous-feed")
                .info("\(surface, privacy: .public): \(page.listings.count, privacy: .public) cards in \(milliseconds, privacy: .public)ms, more=\(page.hasNextPage, privacy: .public)")
            return page
        } catch GraphQLFeedError.blocked {
            await pacer.recordBlock()
            throw GraphQLFeedError.blocked
        }
    }

    // Query metadata and variables measured from the public desktop surface:
    // docs/anonymous-graphql-2026-09-30.md. Schema failures use the browser path.
    static func request(for query: SearchQuery, cursor: String?, now: Date = Date()) throws -> URLRequest {
        guard let point = query.coordinate, CLLocationCoordinate2DIsValid(point),
              point.latitude.isFinite, point.longitude.isFinite else {
            throw GraphQLFeedError.unsupportedQuery
        }
        let operation: String
        let documentID: String
        let variables: [String: Any]
        let provider = "__relay_internal__pv__GHLShouldChangeMarketplaceSponsoredDataFieldNamerelayprovider"
        switch query.kind {
        case .search(let term):
            operation = "CometMarketplaceSearchContentPaginationQuery"
            documentID = "27212616558440397"
            var browse: [String: Any] = [
                "commerce_enable_local_pickup": query.delivery != .shipping,
                "commerce_enable_shipping": query.delivery != .localPickup,
                "commerce_search_and_rp_available": query.availability != .unavailable,
                "commerce_search_and_rp_category_id": [],
                "commerce_search_and_rp_condition": query.conditions.isEmpty
                    ? NSNull() : query.conditions.map(\.rawValue).joined(separator: ",") as Any,
                "commerce_search_and_rp_ctime_days": creationDays(age: query.age, now: now) as Any? ?? NSNull(),
                "filter_location_latitude": point.latitude,
                "filter_location_longitude": point.longitude,
                "filter_price_lower_bound": try priceBound(query.minPrice, defaultValue: 0),
                "filter_price_upper_bound": try priceBound(query.maxPrice, defaultValue: 214748364700),
                "filter_radius_km": query.radiusKM > 0 ? query.radiusKM : 65
            ]
            if query.availability != .any { browse["commerce_search_and_rp_in_stock_v2"] = "" }
            if query.sort != .bestMatch { browse["commerce_search_sort_by"] = query.sort.rawValue.uppercased() }
            variables = [
                "count": 24, "cursor": cursor as Any? ?? NSNull(), "scale": 2, provider: false,
                "params": [
                    "bqf": ["callsite": "COMMERCE_MKTPLACE_WWW", "query": term],
                    "browse_request_params": browse,
                    "custom_request_params": [
                        "browse_context": NSNull(), "contextual_filters": [],
                        "referral_code": NSNull(), "referral_ui_component": NSNull(),
                        "saved_search_strid": NSNull(), "search_vertical": "C2C",
                        "seo_url": NSNull(), "serp_landing_settings": ["virtual_category_id": ""],
                        "surface": "SEARCH", "virtual_contextual_filters": []
                    ]
                ]
            ]
        case .browse:
            guard !query.hasActiveFilters else { throw GraphQLFeedError.unsupportedQuery }
            operation = "MarketplaceCometBrowseFeedLightPaginationQuery"
            documentID = "28036163469355579"
            variables = [
                "buyLocation": ["latitude": point.latitude, "longitude": point.longitude],
                "count": 1, "cursor": cursor as Any? ?? NSNull(),
                "imageWidth": 256, "mediaType": "image/jpeg", "radius": 65000,
                "scale": 2, "sizing": "cover-fill-cropped", "useSDFPath": true,
                "includePDPRelevantListings": false, "pdpListingId": NSNull(), "refinement": NSNull(),
                provider: false,
                "__relay_internal__pv__CometMarketplaceShouldShowTopPicksStrikethroughrelayprovider": false,
                "__relay_internal__pv__MarketplaceCometAdmodulerelayprovider": true,
                "__relay_internal__pv__CometMarketplaceShouldShowFeedShippingIconrelayprovider": false
            ]
        case .category:
            throw GraphQLFeedError.unsupportedQuery
        }
        let data = try JSONSerialization.data(withJSONObject: variables, options: [.sortedKeys])
        let fields = [
            "__user": "0", "av": "0", "__a": "1", "__comet_req": "15",
            "fb_api_caller_class": "RelayModern", "fb_api_req_friendly_name": operation,
            "server_timestamps": "true", "doc_id": documentID,
            "variables": String(decoding: data, as: UTF8.self)
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "="
                + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://www.facebook.com/api/graphql/")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("OpenMarket/0.0.1 (iOS)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        return request
    }

    /// Facebook's desktop search sends UTC epoch days, newest first, including
    /// both endpoints (Last month = today through today - 30, i.e. 31 values).
    /// Verified against the rendered search's Relay variables on 2026-10-02.
    /// UTC arithmetic keeps this independent of device timezone and DST.
    static func creationDays(age: SearchQuery.Age, now: Date) -> String? {
        guard age != .any else { return nil }
        let today = Int(floor(now.timeIntervalSince1970 / 86_400))
        return (0...age.rawValue).map { String(today - $0) }.joined(separator: ";")
    }

    private static func priceBound(_ price: Int?, defaultValue: Int) throws -> Int {
        guard let price else { return defaultValue }
        let (minorUnits, overflow) = price.multipliedReportingOverflow(by: 100)
        guard price >= 0, !overflow else { throw GraphQLFeedError.unsupportedQuery }
        return minorUnits
    }
}
