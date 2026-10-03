import Foundation

/// Reads only the requested feed connection and its streamed edges. Related
/// listings elsewhere in a response must never become cards in this feed.
enum GraphQLFeedDecoder {
    private typealias Object = [String: Any]

    static func decode(_ data: Data, kind: SearchQuery.Kind) throws -> GraphQLFeedPage {
        guard data.count <= 5_000_000, var text = String(data: data, encoding: .utf8) else {
            throw GraphQLFeedError.invalidResponse
        }
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        let records: [Object]
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? Object {
            records = [object]
        } else {
            do {
                records = try text.split(whereSeparator: \.isNewline).map {
                    guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? Object else {
                        throw GraphQLFeedError.invalidResponse
                    }
                    return record
                }
            } catch { throw GraphQLFeedError.invalidResponse }
        }
        let isBrowse: Bool
        switch kind {
        case .browse: isBrowse = true
        case .search: isBrowse = false
        case .category: throw GraphQLFeedError.unsupportedQuery
        }
        var edges: [Int: Object] = [:]
        var info: Object?
        var sawConnection = false
        for record in records {
            if record["error"] != nil || !(record["errors"] as? [Any] ?? []).isEmpty {
                let description = String(describing: record["errors"] ?? record["error"]!).lowercased()
                if description.contains("rate limit") || description.contains("too many requests")
                    || description.contains("temporarily blocked") {
                    throw GraphQLFeedError.blocked
                }
                throw GraphQLFeedError.invalidResponse
            }
            guard let body = record["data"] as? Object else { throw GraphQLFeedError.invalidResponse }
            if let path = record["path"] as? [Any] {
                // Signed-in feeds stream video metadata under ad stories after
                // the listing edges. These patches contain no listing fields.
                let root = isBrowse ? ["marketplace_home_feed"] : ["marketplace_search", "feed_units"]
                let offset = root.count
                if path.count > offset + 3,
                   Array(path.prefix(offset)).compactMap({ $0 as? String }) == root,
                   path[offset] as? String == "edges", let index = path[offset + 1] as? Int,
                   path[offset + 2] as? String == "node", path[offset + 3] as? String == "story",
                   (edges[index]?["node"] as? Object)?["__typename"] as? String == "MarketplaceFeedAdStory" {
                    continue
                }
                guard isBrowse, path.first as? String == "marketplace_home_feed" else {
                    throw GraphQLFeedError.invalidResponse
                }
                if path.count == 3, path[1] as? String == "edges", let index = path[2] as? Int {
                    edges[index] = body
                } else if path.count == 1, let pageInfo = body["page_info"] as? Object {
                    info = pageInfo
                } else { throw GraphQLFeedError.invalidResponse }
            } else {
                let connection = isBrowse ? body["marketplace_home_feed"] as? Object
                    : (body["marketplace_search"] as? Object)?["feed_units"] as? Object
                guard let connection, let initial = connection["edges"] as? [Object] else {
                    throw GraphQLFeedError.invalidResponse
                }
                sawConnection = true
                for (index, edge) in initial.enumerated() { edges[index] = edge }
                if let pageInfo = connection["page_info"] as? Object { info = pageInfo }
            }
        }
        guard sawConnection, let info, let hasNext = info["has_next_page"] as? Bool else {
            throw GraphQLFeedError.invalidResponse
        }
        let cursor = info["end_cursor"] as? String
        guard !hasNext || cursor?.isEmpty == false else { throw GraphQLFeedError.invalidResponse }
        var listings: [PayloadListing] = []
        for index in edges.keys.sorted() {
            guard let node = edges[index]?["node"] as? Object else { throw GraphQLFeedError.invalidResponse }
            if !isBrowse {
                if let listing = node["listing"] as? Object { listings.append(try payload(listing)) }
            } else if let picks = node["marketplace_listings"] as? [Object] {
                listings += try picks.map(payload)
            } else if node["__typename"] as? String == "MarketplaceFeedGeneralListingObject" {
                listings.append(try generalListing(node))
            }
        }
        return GraphQLFeedPage(listings: listings, endCursor: cursor, hasNextPage: hasNext)
    }

    static func payload(_ object: [String: Any]) throws -> PayloadListing {
        guard let id = identifier(object["id"]), let title = object["marketplace_listing_title"] as? String,
              !title.isEmpty else { throw GraphQLFeedError.invalidResponse }
        let photo = object["primary_listing_photo"] as? Object ?? [:]
        let price = object["listing_price"] as? Object ?? [:]
        let previous = object["strikethrough_price"] as? Object
        let location = (object["location"] as? Object)?["reverse_geocode"] as? Object ?? [:]
        let cityPage = location["city_page"] as? Object ?? [:]
        return PayloadListing(
            id: id, title: title, creationTime: object["creation_time"] as? Double,
            priceAmount: price["amount"] as? String,
            priceFormatted: price["formatted_amount"] as? String
                ?? price["formatted_amount_without_decimals"] as? String
                ?? (object["formatted_price"] as? Object)?["text"] as? String,
            strikethroughFormatted: previous?["formatted_amount"] as? String,
            photoURL: (photo["image"] as? Object)?["uri"] as? String,
            photoID: photo["id"] as? String,
            city: location["city"] as? String, state: location["state"] as? String,
            cityPageID: cityPage["id"] as? String,
            deliveryTypes: object["delivery_types"] as? [String] ?? [],
            isSold: object["is_sold"] as? Bool, isLive: object["is_live"] as? Bool,
            categoryID: object["marketplace_listing_category_id"] as? String,
            createdWithSellerApp: object["created_with_seller_app"] as? Bool
        )
    }

    private static func generalListing(_ node: Object) throws -> PayloadListing {
        guard var listing = node["listing"] as? Object,
              let content = node["data"] as? Object,
              let price = content["price"] as? Object,
              let currency = price["currency"] as? String,
              ["USD", "CAD", "GBP", "EUR", "AUD", "NZD"].contains(currency),
              let raw = price["amount_with_offset"] as? String,
              let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else {
            throw GraphQLFeedError.invalidResponse
        }
        // These are the app's verified markets; all six currencies use cents.
        // Unknown currencies fall back instead of assuming their minor units.
        let number = NSDecimalNumber(decimal: amount / 100)
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        let entity = node["entity"] as? Object ?? [:]
        let photo = node["photo"] as? Object ?? [:]
        listing["marketplace_listing_title"] = content["title"]
        listing["listing_price"] = ["amount": number.stringValue,
                                     "formatted_amount": formatter.string(from: number) ?? "\(currency) \(number)"]
        listing["location"] = entity["location"]
        listing["created_with_seller_app"] = entity["created_with_seller_app"]
        listing["primary_listing_photo"] = ["id": photo["id"] ?? NSNull(),
                                             "image": photo["default_image"] ?? NSNull()]
        return try payload(listing)
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let id = value as? String, !id.isEmpty,
              id.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return id
    }
}
