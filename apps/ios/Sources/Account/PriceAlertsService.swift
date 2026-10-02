import Foundation
import CoreLocation

struct AlertLocation: Codable {
    var citySlug: String
    var name: String
    var radiusKM: Int
    var latitude: Double
    var longitude: Double
}

struct PriceAlert: Decodable, Identifiable {
    var id: String
    var query: String
    var location: AlertLocation
    var createdAt: Date
    var alertHour: Int
    var nextCheckAt: Date
    var lastCheckedAt: Date?
    var paused: Bool
    var matchCount: Int
    var unreadCount: Int
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
                thumbnailURL: URL(string: thumbnailURL),
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
}

struct AlertWork: Decodable {
    var id: String
    var alertID: String
    var query: String
    var location: AlertLocation
    var cursor: String?
    var actor: String?
    var pageNumber: Int

    var searchQuery: SearchQuery {
        SearchQuery(kind: .search(query), radiusKM: location.radiusKM, citySlug: location.citySlug,
                    coordinate: CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude),
                    sort: .newest, availability: .available)
    }
}

@MainActor
final class PriceAlertsService {
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
    }
    struct Failure: Decodable { var error: String }
    struct Empty: Decodable {}
    struct AlertList: Decodable { var alerts: [PriceAlert] }
    struct MatchList: Decodable { var matches: [AlertMatch] }
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

    func call<T: Decodable>(_ action: String, _ body: Request = Request(), as type: T.Type) async throws -> T {
        var request = URLRequest(url: URL(string: API.baseURL + "/v1/price-alerts/" + action)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
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
            throw APIError.message((try? JSONDecoder().decode(Failure.self, from: data).error) ?? "Couldn't load price alerts.")
        }
        return try Self.decoder().decode(type, from: data)
    }
}
