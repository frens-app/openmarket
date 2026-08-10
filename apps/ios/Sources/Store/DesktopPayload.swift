import Foundation

/// The `MarketplaceSearch` GraphQL response, which desktop pages embed verbatim
/// in the HTML they already serve us.
///
/// This is the whole reason search moves to desktop. One page load yields a
/// structured object per card carrying an exact `creation_time`, a numeric
/// price, `delivery_types`, sold state, the city's place id, the untruncated
/// title, and the listing id — none of which the mobile surface has at any
/// depth. See `docs/embedded-payload.md`.
///
/// Two limits are load-bearing and are enforced here rather than discovered
/// later:
///
/// * **The payload covers only the first ~15 cards.** Anything past the first
///   server-rendered page is markup, signed in or out, so `PayloadListing`
///   describes a minority of a long result set and callers must cope with cards
///   that have none.
/// * **Nothing here is trustworthy without an id match.** Item pages carry ~20
///   *other* listings' payload objects in the "Today's picks" rail, and reading
///   the nearest one is how a neighbour's coordinates or timestamp end up
///   attributed to the listing being viewed.
struct PayloadListing: Decodable, Equatable {
    let id: String
    let title: String?
    let creationTime: Double?
    let priceAmount: String?
    let priceFormatted: String?
    let strikethroughFormatted: String?
    let photoURL: String?
    let photoID: String?
    let city: String?
    let state: String?
    let cityPageID: String?
    let deliveryTypes: [String]
    let isSold: Bool?
    let isLive: Bool?
    let categoryID: String?
    let createdWithSellerApp: Bool?

    /// Exact posting time, which is the field nothing else provides. Facebook's
    /// own UI rounds this to "2 weeks ago" where the payload is precise to the
    /// second.
    var postedAt: Date? {
        guard let creationTime, creationTime > 1_000_000_000 else { return nil }
        return Date(timeIntervalSince1970: creationTime)
    }

    var price: Decimal? {
        guard let priceAmount else { return nil }
        return Decimal(string: priceAmount)
    }

    /// `SHIPPING_ONSITE` marked 24 of 24 cards on a shipping-filtered page and
    /// none on a local one. Note it is not exclusive: most shipping listings
    /// also offer collection, so "ships" and "ships only" are different
    /// questions and both are worth asking.
    var shipsToBuyer: Bool { deliveryTypes.contains("SHIPPING_ONSITE") }
    var offersLocalPickup: Bool { deliveryTypes.contains("IN_PERSON") }
    var isShippingOnly: Bool { shipsToBuyer && !offersLocalPickup }

    /// The same tokens as the model the screens read. Nil past the first
    /// ~15 cards, where there is no payload to carry them.
    var fulfillment: Fulfillment? { Fulfillment(tokens: deliveryTypes) }

    /// The identity the rest of the app uses. Built from the fbcdn filename
    /// segment, **not** `photoID` — those are adjacent but different numbers
    /// (6 of 6 sampled differ), and the filename segment is the one that is
    /// byte-identical across the mobile and desktop surfaces, which is what
    /// makes cross-surface dedupe an equality check. See
    /// `docs/surface-strategy.md` §5a.
    var listingIdentity: String? {
        guard let photoURL, let url = URL(string: photoURL) else { return nil }
        return Listing.photoFBID(url).map { "p:\($0)" }
    }

    var locationText: String? {
        guard let city else { return nil }
        guard let state else { return city }
        return "\(city), \(state)"
    }
}

/// One card's worth of payload plus the auth state it was captured under.
///
/// The pairing matters: a missing seller rating captured while signed out means
/// *unknown*, not *absent*, and ratings are a primary signal for the
/// business-seller filter. Conflating the two would corrupt it quietly. The
/// result *set* differs by auth too — a San Francisco query returned 15 San
/// Francisco listings signed in, where signed out it spread to Martinez,
/// Vallejo and Oakland — so this belongs in cache keys, not only on records.
struct CaptureContext: Codable, Equatable, Hashable {
    var session: BrowserSession
    var surface: Surface
    var capturedAt: Date

    var wasAuthenticated: Bool { session == .authed }

    /// Seller identity is only exposed to a signed-in desktop session, so a
    /// record captured any other way has *unknown* seller fields rather than
    /// empty ones, and is worth re-fetching once a session exists.
    var canCarrySellerIdentity: Bool { session == .authed && surface == .desktop }
}

extension PayloadListing {
    /// Builds a grid card from the payload.
    ///
    /// Identity comes from the photo filename rather than the listing id, so a
    /// card built here matches one built from a mobile card for the same
    /// listing — that equality is what makes merging the two surfaces a lookup
    /// instead of a fuzzy title comparison (`docs/surface-strategy.md` §5a).
    /// Falls back to the listing id only when there is no usable photo.
    func makeListing(cardIndex: Int) -> Listing {
        Listing(
            id: listingIdentity ?? "fb:\(id)",
            title: title,
            priceText: priceFormatted,
            originalPriceText: strikethroughFormatted,
            locationText: locationText,
            conditionText: nil,          // desktop cards don't carry it; the item page does
            fulfillment: fulfillment,
            thumbnailURL: photoURL.flatMap(URL.init(string:)),
            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(id)/"),
            badgeText: (isSold == true) ? "Sold" : nil,
            cardIndex: cardIndex,
            detail: nil,
            capturedAt: Date()
        )
    }

    /// Merges into a card, filling only what the payload actually knows.
    ///
    /// Never overwrites a known value with nil — a listing enriched from an
    /// earlier capture keeps what it had, which is what lets an unauthenticated
    /// record be upgraded in place once the user signs in.
    func apply(to listing: inout Listing) {
        if let title, !title.isEmpty { listing.title = title }
        if let priceFormatted { listing.priceText = priceFormatted }
        if let strikethroughFormatted { listing.originalPriceText = strikethroughFormatted }
        if let locationText { listing.locationText = locationText }
        if let fulfillment { listing.fulfillment = fulfillment }
        if listing.itemURL == nil {
            listing.itemURL = URL(string: "https://www.facebook.com/marketplace/item/\(id)/")
        }
    }
}
