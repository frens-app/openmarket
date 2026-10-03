import Foundation
import CoreFoundation

struct SellerGraphQLPage {
    let profileID: String
    let items: [Listing]
    let cursor: String?
    let hasMore: Bool
}

enum SellerGraphQLDecoder {
    private typealias Object = [String: Any]

    static func decode(_ data: Data, rootKey: String, expectedID: String? = nil, unavailableInventory: Bool = false) throws -> SellerGraphQLPage {
        guard data.count <= 5_000_000, var text = String(data: data, encoding: .utf8) else {
            throw GraphQLFeedError.invalidResponse
        }
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        let records: [Object]
        if let array = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Object] { records = array }
        else if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? Object { records = [object] }
        else {
            records = try text.split(whereSeparator: \.isNewline).map {
                guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? Object else {
                    throw GraphQLFeedError.invalidResponse
                }
                return record
            }
        }
        var root: Any = Object()
        var resolvedID = expectedID
        for record in records {
            if record["error"] != nil || !(record["errors"] as? [Any] ?? []).isEmpty {
                let errors = record["errors"] as? [Object] ?? []
                let description = String(describing: record).lowercased()
                if errors.contains(where: { ($0["code"] as? Int) == 1675002 }) {
                    throw SellerInventoryError.signInRequired
                }
                if description.contains("rate limit") || description.contains("temporarily blocked") || description.contains("too many requests") {
                    throw GraphQLFeedError.blocked
                }
                throw GraphQLFeedError.invalidResponse
            }
            guard let body = record["data"] as? Object else {
                if (record["extensions"] as? Object)?["is_final"] as? Bool == true { continue }
                throw GraphQLFeedError.invalidResponse
            }
            if let path = record["path"] as? [Any] {
                guard path.count >= 2, path[0] as? String == rootKey,
                      path[1] as? String == "marketplace_listing_sets" else { throw GraphQLFeedError.invalidResponse }
                root = try patch(root, path: ArraySlice(path), body: body)
            } else {
                guard let profile = body[rootKey] as? Object,
                      let id = profile["id"] as? String, !id.isEmpty else { throw GraphQLFeedError.invalidResponse }
                if let resolvedID, resolvedID != id { throw GraphQLFeedError.invalidResponse }
                resolvedID = id
                root = merge(root, [rootKey: profile])
            }
        }
        guard let profile = (root as? Object)?[rootKey] as? Object,
              let id = profile["id"] as? String, id == resolvedID,
              let connection = profile["marketplace_listing_sets"] as? Object,
              let edges = connection["edges"] as? [Object],
              let info = connection["page_info"] as? Object,
              let hasMore = boolean(info["has_next_page"]) else { throw GraphQLFeedError.invalidResponse }
        let cursor = info["end_cursor"] as? String
        guard !hasMore || cursor?.isEmpty == false else { throw GraphQLFeedError.invalidResponse }
        var seen = Set<String>()
        let items = try edges.enumerated().compactMap { index, edge -> Listing? in
            guard let node = edge["node"] as? Object,
                  let raw = node["canonical_listing"] as? Object else { throw GraphQLFeedError.invalidResponse }
            let payload = try GraphQLFeedDecoder.payload(raw)
            guard seen.insert(payload.id).inserted else { return nil }
            var listing = payload.makeListing(cardIndex: index)
            if boolean(raw["is_sold"]) == true { listing.badgeText = "Sold" }
            else if boolean(raw["is_pending"]) == true { listing.badgeText = "Pending" }
            else if unavailableInventory, boolean(raw["is_sold"]) == false, boolean(raw["is_pending"]) == false {
                listing.badgeText = "Out of stock"
            }
            return listing
        }
        return SellerGraphQLPage(profileID: id, items: items, cursor: cursor, hasMore: hasMore)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func merge(_ old: Any, _ new: Any) -> Any {
        guard var old = old as? Object, let new = new as? Object else { return new }
        for (key, value) in new { old[key] = old[key].map { merge($0, value) } ?? value }
        return old
    }

    private static func patch(_ value: Any, path: ArraySlice<Any>, body: Object) throws -> Any {
        guard let first = path.first else { return merge(value, body) }
        if let key = first as? String, var object = value as? Object {
            object[key] = try patch(object[key] ?? Object(), path: path.dropFirst(), body: body)
            return object
        }
        if let index = first as? Int, var array = value as? [Any], index >= 0, index <= array.count {
            if index == array.count { array.append(Object()) }
            array[index] = try patch(array[index], path: path.dropFirst(), body: body)
            return array
        }
        throw GraphQLFeedError.invalidResponse
    }
}
