import Foundation

struct SellerProfile: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var photoURL: URL?
    var joinedText: String?
    var rating: Double?
    var ratingCount: Int?
    var isHighlyRated: Bool?

    init?(detail: ListingDetail) {
        guard let id = detail.sellerProfileID, !id.isEmpty,
              id.utf8.allSatisfy({ (48...57).contains($0) }),
              let name = detail.sellerName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.id = id
        self.name = name
        photoURL = detail.sellerPhotoURL
        joinedText = detail.sellerJoined
        rating = detail.sellerRating
        ratingCount = detail.sellerRatingCount
        isHighlyRated = detail.sellerIsHighlyRated
    }

    var url: URL { URL(string: "https://www.facebook.com/marketplace/profile/\(id)/")! }
    var initials: String { name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined() }

    static func validatedPhotoURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

enum SellerListingFilter: String, CaseIterable, Identifiable {
    case available, unavailable
    var id: String { rawValue }
    var title: String { self == .available ? "Available" : "Pending / sold / out of stock" }
}
