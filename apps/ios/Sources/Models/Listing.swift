import Foundation

/// A card as it appears in the results grid.
///
/// The mobile surface exposes no listing id on the grid (see
/// docs/feasibility-2026-07-31.md), so identity comes from the photo FBID
/// embedded in the thumbnail CDN URL, with a title+price hash as fallback.
/// The canonical `itemURL` is resolved lazily, when the user opens the listing.
struct Listing: Identifiable, Codable, Equatable, Hashable {
    let id: String
    var title: String?
    var priceText: String?      // kept as displayed: "Free", "$1,200", ranges
    var originalPriceText: String?
    var locationText: String?   // from the card's aria-label; detail fills gaps
    var conditionText: String?  // "Used - Good" — the card label carries it
    var thumbnailURL: URL?
    var itemURL: URL?           // nil until resolved by tapping through
    var badgeText: String?      // "Price drop", "Sold", …
    var cardIndex: Int          // position in the DOM, used to re-find the card
    var detail: ListingDetail?
    var capturedAt: Date

    var isResolved: Bool { itemURL != nil }
}

struct ListingDetail: Codable, Equatable, Hashable {
    var description: String?
    var photoURLs: [URL] = []
    var postedText: String?
    var conditionText: String?
    var locationText: String?
    var sellerName: String?
    var sellerJoined: String?      // "Joined Facebook in 2011"
    var sellerRating: Double?      // 4.8
    var sellerRatingCount: Int?    // 12
    /// Facebook's own "Highly rated on Marketplace" badge.
    ///
    /// Carried rather than derived from the score, because it is Facebook's
    /// judgement against its own bar — which it does not publish — and a
    /// threshold invented here would put the badge on sellers Facebook doesn't.
    /// Optional for the usual reason: nil is "nothing said", not "no".
    var sellerIsHighlyRated: Bool?

    /// Facebook's published approximate point for this listing, from the item
    /// page only — cards carry no coordinate. Fuzzed by Facebook and labelled
    /// "Location is approximate", so it is a neighbourhood, not an address; it
    /// is still kilometres closer than the geocoded city centroid it replaces.
    var latitude: Double?
    var longitude: Double?

    /// Whether the listing is still for sale, as the item page reported it on
    /// the last fetch.
    ///
    /// Optional on purpose, and the distinction is the whole point: `nil` means
    /// nothing has told us, which is what a card from the mobile surface or a
    /// pre-existing cache entry looks like. Only `true` may be presented as
    /// sold. Treating absent as available would be the safer-looking default
    /// and the wrong one — a stale cache would quietly show a sold listing as
    /// on the market.
    var isSold: Bool?
    /// Someone has agreed to buy it and not yet collected. Weaker than sold and
    /// worth distinguishing: a pending listing can fall through.
    var isPending: Bool?
}

extension Listing {
    /// Stable-enough identity for dedupe and the hidden-listings list.
    static func identity(thumbnailURL: URL?, title: String?, priceText: String?) -> String {
        if let fbid = thumbnailURL.flatMap(Self.photoFBID) { return "p:\(fbid)" }
        return "h:\((title ?? "") + "|" + (priceText ?? ""))".lowercased()
    }

    /// fbcdn filenames look like `729964685_1105285382678938_1161471387555069882_n.jpg`;
    /// the middle group is the photo's FBID and is stable for the listing.
    static func photoFBID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let candidate = String(parts[1])
        return candidate.allSatisfy(\.isNumber) && candidate.count >= 10 ? candidate : nil
    }
}
