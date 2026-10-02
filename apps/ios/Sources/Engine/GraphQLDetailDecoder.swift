import Foundation
import CoreFoundation

enum GraphQLDetailDecoder {
    private typealias Object = [String: Any]

    static func core(_ data: Data, itemID: String, now: Date = Date()) throws -> ListingDetail {
        let target = try target(data, itemID: itemID)
        guard target["marketplace_listing_title"] is String,
              target.keys.contains("redacted_description") else { throw GraphQLFeedError.invalidResponse }
        let seller = target["marketplace_listing_seller"] as? Object
        let ratings = seller?["marketplace_ratings_stats_by_role_v2"] as? Object
        let stats = ratings?["seller_stats"] as? Object
        // Numeric stats can be present even when Facebook hides them on the page.
        let publicRatings = boolean(ratings?["seller_ratings_are_private"]) == false
        let count = publicRatings ? number(stats?["five_star_total_rating_count_by_role"]) : nil
        let score = publicRatings ? number(stats?["five_star_ratings_average"]) : nil
        let point = target["location"] as? Object
        let lat = number(point?["latitude"]), lon = number(point?["longitude"])
        let validPoint = lat.map { (-90...90).contains($0) } == true && lon.map { (-180...180).contains($0) } == true
        let attributes = target["attribute_data"] as? [Object] ?? []
        let badge = (target["commerce_badges_info"] as? Object)?["source_summary"] as? String
        var joined: String?
        if let timestamp = number(seller?["join_time"]), timestamp > 0, timestamp <= now.timeIntervalSince1970 {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            joined = "Joined Facebook in \(calendar.component(.year, from: Date(timeIntervalSince1970: timestamp)))"
        }
        var posted: String?
        if let timestamp = number(target["creation_time"]), timestamp > 0, timestamp <= now.timeIntervalSince1970 {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            posted = "Listed \(formatter.localizedString(for: Date(timeIntervalSince1970: timestamp), relativeTo: now))"
        }
        return ListingDetail(
            description: (target["redacted_description"] as? Object)?["text"] as? String,
            postedText: posted,
            conditionText: attributes.first { $0["attribute_name"] as? String == "Condition" }?["label"] as? String,
            locationText: (target["location_text"] as? Object)?["text"] as? String,
            sellerProfileID: seller?["id"] as? String,
            sellerName: seller?["name"] as? String,
            sellerJoined: joined,
            sellerRating: (count ?? 0) > 0 && (score ?? 0) > 0 && (score ?? 6) <= 5 ? score : nil,
            sellerRatingCount: count.flatMap { $0 >= 0 && $0 < Double(Int.max) && $0.rounded() == $0 ? Int($0) : nil },
            sellerIsHighlyRated: badge.map { $0.localizedCaseInsensitiveContains("Highly rated") },
            latitude: validPoint ? lat : nil, longitude: validPoint ? lon : nil,
            isSold: boolean(target["is_sold"]), isPending: boolean(target["is_pending"]),
            fulfillment: (target["delivery_types"] as? [String]).flatMap(Fulfillment.init(tokens:)))
    }

    static func photos(_ data: Data, itemID: String) throws -> [URL] {
        let target = try target(data, itemID: itemID)
        guard let photos = target["listing_photos"] as? [Object] else { throw GraphQLFeedError.invalidResponse }
        var seen = Set<String>()
        return try photos.compactMap { photo in
            guard let id = photo["id"] as? String,
                  let image = photo["image"] as? Object, let uri = image["uri"] as? String,
                  let url = URL(string: uri), url.scheme == "https", url.host != nil else {
                throw GraphQLFeedError.invalidResponse
            }
            return seen.insert(id).inserted ? url : nil
        }
    }

    private static func target(_ data: Data, itemID: String) throws -> Object {
        guard data.count <= 5_000_000, var text = String(data: data, encoding: .utf8) else {
            throw GraphQLFeedError.invalidResponse
        }
        if text.hasPrefix("for (;;);") { text.removeFirst(9) }
        let records: [Object]
        if let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? Object { records = [object] }
        else {
            do {
                records = try text.split(whereSeparator: \.isNewline).map {
                    guard let record = try JSONSerialization.jsonObject(with: Data($0.utf8)) as? Object else {
                        throw GraphQLFeedError.invalidResponse
                    }
                    return record
                }
            } catch { throw GraphQLFeedError.invalidResponse }
        }
        var root: Any = Object()
        let targetPath = ["viewer", "marketplace_product_details_page", "target"]
        for record in records {
            if record["error"] != nil || !(record["errors"] as? [Any] ?? []).isEmpty {
                let message = String(describing: record).lowercased()
                if message.contains("rate limit") || message.contains("too many requests") || message.contains("temporarily blocked") {
                    throw GraphQLFeedError.blocked
                }
                throw GraphQLFeedError.invalidResponse
            }
            guard let body = record["data"] as? Object else {
                if record["data"] == nil, (record["extensions"] as? Object)?["is_final"] as? Bool == true { continue }
                throw GraphQLFeedError.invalidResponse
            }
            if let path = record["path"] as? [Any] {
                guard path.count >= 3, path.prefix(3).compactMap({ $0 as? String }) == targetPath else {
                    throw GraphQLFeedError.invalidResponse
                }
                root = try patch(root, path: ArraySlice(path), body: body)
            } else { root = merge(root, body) }
            let current = ((root as? Object)?["viewer"] as? Object)?["marketplace_product_details_page"] as? Object
            if let id = (current?["target"] as? Object)?["id"] as? String, id != itemID {
                throw GraphQLFeedError.invalidResponse
            }
        }
        guard let viewer = (root as? Object)?["viewer"] as? Object,
              let page = viewer["marketplace_product_details_page"] as? Object,
              let target = page["target"] as? Object, target["id"] as? String == itemID else {
            throw GraphQLFeedError.invalidResponse
        }
        return target
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

    private static func merge(_ old: Any, _ new: Any) -> Any {
        guard var result = old as? Object, let additions = new as? Object else { return new }
        for (key, value) in additions { result[key] = result[key].map { merge($0, value) } ?? value }
        return result
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
}
