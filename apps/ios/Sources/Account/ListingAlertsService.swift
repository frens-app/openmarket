import Foundation
import CoreLocation

struct AlertLocation: Codable {
    var citySlug: String
    var name: String
    var radiusKM: Int
    var latitude: Double
    var longitude: Double
}

struct ListingAlert: Decodable, Identifiable {
    var id: String
    var query: String
    var minPrice: Int?
    var maxPrice: Int?
    var location: AlertLocation
    var createdAt: Date
    var alertHour: Int
    var nextCheckAt: Date
    var lastCheckedAt: Date?
    var paused: Bool
    var matchCount: Int
    var unreadCount: Int
}

struct ListingAlertAllowance: Decodable, Equatable {
    let active: Int
    let limit: Int

    var hasAvailableSlot: Bool { active < limit }
    var limitMessage: String {
        "Your limit is \(limit) active \(limit == 1 ? "alert" : "alerts"). Pause or delete an alert to free up a slot."
    }
}

struct AlertListing: Codable, Identifiable {
    var id: String
    var title: String
    var priceText: String
    var locationText: String
    var thumbnailURL: String
    var description: String
    var condition: String

    var listing: Listing {
        Listing(id: "fb:\(id)", title: title, priceText: priceText,
                locationText: locationText, conditionText: condition.isEmpty ? nil : condition,
                thumbnailURL: URL(string: thumbnailURL).flatMap { $0.scheme == "https" ? $0 : nil },
                itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(id)/"),
                cardIndex: 0, capturedAt: Date())
    }
}

struct AlertMatch: Decodable, Identifiable {
    var listing: AlertListing
    var matchedCursor: String
    var matchedAt: Date
    var viewedAt: Date?
    var id: String { listing.id }
    var displayedListing: Listing {
        var value = listing.listing
        value.capturedAt = matchedAt
        return value
    }
}

struct AlertNotificationGroup: Decodable, Identifiable {
    let id: String
    let alertID: String
    let query: String
    let createdAt: Date
    let createdCursor: String
    let matchCount: Int
    let unreadCount: Int
    var seenAt: Date? = nil
    let previews: [AlertListing]
}

struct AlertNotificationDetails: Decodable {
    let id: String
    let query: String
    let createdAt: Date
    let matchCount: Int
}

struct AlertSearchOptions: Decodable {
    var sort: SearchQuery.Sort = .bestMatch
    var delivery: SearchQuery.Delivery = .any
    var daysSinceListed: SearchQuery.Age = .any
    var conditions: [SearchQuery.Condition] = []
    var minPrice: Int?
    var maxPrice: Int?

    enum CodingKeys: String, CodingKey {
        case sort, delivery, daysSinceListed, conditions, minPrice, maxPrice
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sort = try values.decodeIfPresent(SearchQuery.Sort.self, forKey: .sort) ?? .bestMatch
        delivery = try values.decodeIfPresent(SearchQuery.Delivery.self, forKey: .delivery) ?? .any
        daysSinceListed = try values.decodeIfPresent(SearchQuery.Age.self, forKey: .daysSinceListed) ?? .any
        conditions = try values.decodeIfPresent([SearchQuery.Condition].self, forKey: .conditions) ?? []
        minPrice = try values.decodeIfPresent(Int.self, forKey: .minPrice)
        maxPrice = try values.decodeIfPresent(Int.self, forKey: .maxPrice)
        guard minPrice.map({ (0...2_147_483_647).contains($0) }) ?? true,
              maxPrice.map({ (0...2_147_483_647).contains($0) }) ?? true,
              minPrice == nil || maxPrice == nil || minPrice! <= maxPrice! else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid alert price bounds"))
        }
    }
}

struct AlertWork: Decodable {
    var id: String
    var alertID: String
    var query: String
    var location: AlertLocation
    var cursor: String?
    var actor: String?
    var pageNumber: Int
    var searchOptions: AlertSearchOptions?
    var fetchAttemptID: String?

    var searchQuery: SearchQuery {
        let options = searchOptions ?? AlertSearchOptions()
        return SearchQuery(kind: .search(query), radiusKM: location.radiusKM, citySlug: location.citySlug,
                    coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    sort: options.sort, delivery: options.delivery, age: options.daysSinceListed,
                    availability: .available, conditions: options.conditions,
                    minPrice: options.minPrice, maxPrice: options.maxPrice)
    }
}

@MainActor
final class ListingAlertsService {
    struct Request: Encodable {
        var id: String?
        var query: String?
        var location: AlertLocation?
        var paused: Bool?
        var checkID: String?
        var pageNumber: Int?
        var cursor: String?
        var actor: String?
        var complete: Bool?
        var listings: [AlertListing]?
        var listingIDs: [String]?
        var beforeID: String?
        var before: String?
        var fetchAttemptID: String?
        var trigger: String?
        var event: String?
        var failureStage: String?
        var failureCode: String?
        var alertHour: Int?
        var alertMinute: Int?
        var timeZone: String?
        var interactionID: String?
        var notificationID: String?
        var source: String?
        var listingID: String?
        var beforeAlertID: String?
        var minPrice: Int?
        var maxPrice: Int?
        var filter: String?
    }
    struct Failure: Decodable { var error: String }
    struct Empty: Decodable {}
    struct AlertList: Decodable {
        var alerts: [ListingAlert]
        // Older deployments omit this; creation still uses the server's enforcement.
        var allowance: ListingAlertAllowance?
    }
    struct Inbox: Decodable { var items: [AlertInboxItem] }
    struct NotificationFeed: Decodable { var groups: [AlertNotificationGroup] }
    struct MatchList: Decodable { var matches: [AlertMatch]; var notification: AlertNotificationDetails? }
    struct WorkList: Decodable { var work: [AlertWork] }
    struct Created: Decodable { var id: String }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else {
                throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid alert timestamp")
            }
            return date
        }
        return decoder
    }

    func call<T: Decodable>(_ action: String, _ body: Request = Request(), as type: T.Type, timeout: TimeInterval = 15) async throws -> T {
        var request = URLRequest(url: URL(string: API.baseURL + "/v1/listing-alerts/" + action)!)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, values) in try await AccountSession.shared.authorizedHeaders() {
            request.setValue(values.joined(separator: ","), forHTTPHeaderField: name)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw APIError.network }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 { throw APIError.unauthenticated }
            throw APIError.message((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Couldn't load alerts.")
        }
        return try Self.decoder().decode(type, from: data)
    }
}

struct AlertSchedule {
    var hour: Int
    var minute: Int
    var timeZone: String

    init(date: Date, calendar: Calendar = .current) {
        hour = calendar.component(.hour, from: date)
        minute = calendar.component(.minute, from: date)
        timeZone = calendar.timeZone.identifier
    }

    static func defaultTime(now: Date = Date(), calendar: Calendar = .current) -> Date {
        guard let hour = calendar.dateInterval(of: .hour, for: now) else { return now }
        return now.timeIntervalSince(hour.start) < hour.duration / 2 ? hour.start : hour.end
    }
}

struct AlertPriceInput {
    var minimum = ""
    var maximum = ""

    var minPrice: Int? { Int(minimum.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var maxPrice: Int? { Int(maximum.trimmingCharacters(in: .whitespacesAndNewlines)) }

    var validationMessage: String? {
        for text in [minimum, maximum] {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(trimmed), (0...2_147_483_647).contains(value) else {
                return "Enter whole prices from 0 to 2,147,483,647."
            }
        }
        if let minPrice, let maxPrice, minPrice > maxPrice {
            return "Minimum price must not exceed maximum price."
        }
        return nil
    }

    static func summary(min: Int?, max: Int?) -> String {
        switch (min, max) {
        case let (min?, max?): return "\(min.formatted())–\(max.formatted())"
        case let (min?, nil): return "\(min.formatted()) or more"
        case let (nil, max?): return "Up to \(max.formatted())"
        case (nil, nil): return "Any price"
        }
    }
}

struct AlertInboxItem: Decodable, Identifiable {
    let notificationID: String
    let alertID: String
    let query: String
    let listing: AlertListing
    let createdAt: Date
    let createdCursor: String
    var viewedAt: Date?
    var savedAt: Date?

    var id: String { notificationID + ":" + listing.id }
    var saveContext: AlertSaveContext { .init(alertID: alertID, notificationID: notificationID) }
    var displayedListing: Listing {
        var value = listing.listing
        value.capturedAt = createdAt
        return value
    }
}

enum AlertInboxFilter: String, CaseIterable {
    case all, unread, saved
    var title: String { rawValue.capitalized }
}
