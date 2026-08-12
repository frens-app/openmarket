import Foundation

/// An item page's fields exactly as `WebLiteScripts.extractDetail` returns
/// them, plus the mapping into the model.
///
/// Two engines produce this now. The feed webview harvests it in place after a
/// tap — WebLite routes the tap client-side and the whole page is in the DOM
/// milliseconds later — and `DetailEngine` loads the page separately for cards
/// the tap can't reach. Neither owns the shape, so it lives here.
struct RawDetail: Decodable {
    let itemId: String?
    /// Seller fields are `var` because they arrive later than everything else
    /// and get merged in from a second read — see `DetailEngine.loadDetail`.
    /// Nothing else about this struct is mutable, and nothing else should be.
    var sellerProfileID: String?
    var sellerName: String?
    var sellerJoined: String?
    var sellerRatingText: String?
    var sellerRatingCount: String?
    let description: String?
    let photoURLs: [String]
    let postedText: String?
    let conditionText: String?
    let locationText: String?
    let latitude: String?
    let longitude: String?
    /// Whether the listing is still for sale, read from the item page itself.
    ///
    /// Optional because WebLite's extractor doesn't produce it — nil means
    /// "this surface didn't say", never "still available".
    let isSold: Bool?
    let isPending: Bool?
    /// Facebook's `delivery_types` for this listing, verbatim.
    ///
    /// Optional, and the difference from `[]` is the point: nil means the
    /// extractor found no delivery information at all on this surface, where an
    /// empty array would mean it found the field and it named nothing. Both
    /// produce no badge, but only the first is a gap worth chasing in the log.
    let deliveryTypes: [String]?
    let loginWall: Bool
    /// Facebook's "Highly rated on Marketplace" badge, when the section says so.
    var sellerIsHighlyRated: Bool?
    /// What the seller-section finder saw, for the log only.
    ///
    /// Seller identity is signed-in-only and therefore the least-exercised
    /// extractor in the app (`logged-in-findings.md` §7.2). "No seller shown"
    /// has three causes that look identical on screen — the section wasn't in
    /// the DOM, it was there and didn't parse, or the seller genuinely has no
    /// public details — and this is what tells them apart.
    var sellerSection: String?

    /// "Has something worth showing" and "has everything" are different
    /// questions, and the gap between them is seconds: the description lands
    /// well before the gallery resolves. Waiting for both before rendering
    /// anything is what made the screen feel slower than it was.
    var hasText: Bool { description != nil }
    var isComplete: Bool { description != nil && !photoURLs.isEmpty }

    var listingDetail: ListingDetail {
        ListingDetail(
            description: description,
            photoURLs: photoURLs.compactMap(URL.init(string:)),
            postedText: postedText,
            conditionText: conditionText,
            locationText: locationText,
            sellerProfileID: sellerProfileID,
            sellerName: sellerName,
            sellerJoined: sellerJoined,
            sellerRating: sellerRatingText.flatMap(Double.init),
            sellerRatingCount: sellerRatingCount.flatMap(Int.init),
            sellerIsHighlyRated: sellerIsHighlyRated,
            latitude: latitude.flatMap(Double.init),
            longitude: longitude.flatMap(Double.init),
            isSold: isSold,
            isPending: isPending,
            fulfillment: deliveryTypes.flatMap(Fulfillment.init(tokens:))
        )
    }

    /// The id the page reports for itself, from `location.pathname`. A redirect,
    /// a wall or Marketplace's own landing page all render and extract cleanly,
    /// so every consumer checks this against the id it asked for.
    func matches(_ expectedID: String?) -> Bool {
        guard let expectedID else { return true }
        return itemId == expectedID
    }
}

extension URL {
    /// The listing id out of a `/marketplace/item/{id}/` path.
    var marketplaceItemID: String? {
        pathComponents.first { $0.count > 8 && $0.allSatisfy(\.isNumber) }
    }
}
