import Foundation
import os

extension Logger {
    /// Extractor-level complaints: a value came back that our model of Facebook
    /// does not account for. Its own category so the whole class is one filter
    /// away — `docs/parsing-conventions.md` §1.
    static let parse = Logger(subsystem: "lol.frens.openmarket", category: "parse")
}

/// A Facebook listing. Resolved cards use `fb:<listing ID>` locally; the server
/// assigns its own UUID independently. Old mobile DOM cards can remain unresolved
/// until opened, but their photo/text keys are never server listing identities.
struct Listing: Identifiable, Codable, Equatable, Hashable {
    var id: String
    var title: String?
    var priceText: String? { // Source text, retained independently of display.
        didSet {
            if priceText != oldValue {
                priceAmountDecimal = nil
                priceCurrencyCode = nil
            }
        }
    }
    var originalPriceText: String? {
        didSet { if originalPriceText != oldValue { originalPriceAmountDecimal = nil } }
    }
    var locationText: String?   // from the card's aria-label; detail fills gaps
    var conditionText: String?  // "Used - Good" — the card label carries it
    /// How the item changes hands, when the surface said. Card-level because
    /// the desktop search payload carries `delivery_types` per card, which lets
    /// the detail screen draw it on the first frame instead of waiting for the
    /// item page — the same reason `conditionText` lives here.
    var fulfillment: Fulfillment?
    var thumbnailURL: URL?
    var itemURL: URL?           // nil until resolved by tapping through
    var badgeText: String?      // "Price drop", "Sold", …
    var cardIndex: Int          // position in the DOM, used to re-find the card
    var detail: ListingDetail?
    var capturedAt: Date
    var priceObservedAt: Date? = nil
    var detailObservedAt: Date? = nil
    var availabilityObservedAt: Date? = nil
    var observedSold: Bool? = nil
    var observedPending: Bool? = nil
    var priceAmountDecimal: String? = nil
    var priceCurrencyCode: String? = nil
    var originalPriceAmountDecimal: String? = nil

    var exactPriceAmount: String? {
        MarketplacePrice.canonicalAmount(priceAmountDecimal) ?? MarketplacePrice.exactAmount(priceText)
    }
    var exactOriginalPriceAmount: String? {
        MarketplacePrice.canonicalAmount(originalPriceAmountDecimal) ?? MarketplacePrice.exactAmount(originalPriceText)
    }
    var currencyCode: String? {
        if let priceCurrencyCode, priceCurrencyCode.range(of: #"\A[A-Z]{3}\z"#, options: .regularExpression) != nil {
            return priceCurrencyCode
        }
        guard let symbol = MarketplacePrice.parse(priceText)?.symbol else { return nil }
        return MarketCurrency.unambiguousCurrency(symbol: symbol)?.code
    }

    var displayPrice: String? { MarketplacePrice.display(priceText) }
    var displayOriginalPrice: String? { MarketplacePrice.display(originalPriceText) }

    var isResolved: Bool { itemURL != nil }
}

struct ListingDetail: Codable, Equatable, Hashable {
    var description: String?
    var photoURLs: [URL] = []
    var postedText: String?
    var conditionText: String?
    var locationText: String?
    /// Numeric id from `/marketplace/profile/<id>` on a signed-in desktop item
    /// page. This is Facebook's stable seller key; never synthesize it by
    /// clustering names or listing coordinates.
    var sellerProfileID: String?
    var sellerName: String?
    var sellerPhotoURL: URL?
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

    /// Shipping, collection, or both — as the item page reported it.
    ///
    /// Optional for the usual reason: nil is "this surface didn't say", never
    /// "collection only". Guessing the common case would be the wrong kind of
    /// helpful, because the whole value of the field is that it is Facebook's
    /// answer rather than ours.
    var fulfillment: Fulfillment?
    /// Item GraphQL can recover a saved card whose original cache is missing.
    var title: String? = nil
}

/// How a listing can change hands, from Facebook's `delivery_types`.
///
/// Five tokens have been observed (`docs/embedded-payload.md` §4):
/// `SHIPPING_ONSITE`, `IN_PERSON`, `DOOR_PICKUP`, `DOOR_DROPOFF` and
/// `PUBLIC_MEETUP`. `SHIPPING_ONSITE` is measured hardest — it marked 24 of 24
/// cards on a shipping-filtered page and none on a local one.
///
/// Everything except `SHIPPING_ONSITE` was seen only ever *alongside*
/// `IN_PERSON`, never instead of it, so they are modelled as refinements of
/// collecting in person rather than as modes of their own. That keeps the
/// headline to the three answers someone actually wants — ships, collect, or
/// either — and leaves the arrangements as the smaller print they are.
///
/// **`DOOR_PICKUP` and `DOOR_DROPOFF` are different directions, not synonyms**,
/// which is the whole reason both are carried: one has the buyer collecting
/// from the seller's door, the other has the seller bringing it to the buyer's.
/// `DOOR_DROPOFF` is the only one of the five that is genuinely delivery
/// without being shipping, so folding it into "pickup" would state the opposite
/// of what the seller offered.
///
/// An unrecognised token is dropped from the badge but logged as an error —
/// `docs/parsing-conventions.md` §1, a rule this type is the reason for. The
/// original survey found four tokens and the `default:` here silently ate the
/// fifth for as long as it existed.
struct Fulfillment: Codable, Equatable, Hashable {
    var ships = false
    var inPerson = false
    var doorPickup = false
    var doorDropoff = false
    var publicMeetup = false

    /// Nil rather than an all-false value when nothing was recognised, so the
    /// screen can tell "Facebook says local pickup" from "nobody told us".
    /// An unrecognised token set is the second of those, not the first.
    init?(tokens: [String]) {
        for token in tokens {
            switch token.uppercased() {
            case "SHIPPING_ONSITE", "SHIPPING": ships = true
            case "IN_PERSON": inPerson = true
            case "DOOR_PICKUP": doorPickup = true
            case "DOOR_DROPOFF": doorDropoff = true
            case "PUBLIC_MEETUP": publicMeetup = true
            default:
                // Still dropped — but on the record. See the type's note above.
                Logger.parse.error("unknown delivery_type: \(token, privacy: .public)")
                continue
            }
        }
        guard ships || collectsInPerson else { return nil }
    }

    var collectsInPerson: Bool { inPerson || doorPickup || doorDropoff || publicMeetup }

    /// The one line worth reading. Deliberately not four separate badges: a
    /// buyer is deciding whether they have to drive somewhere, and that is a
    /// three-way question.
    var headline: String {
        switch (ships, collectsInPerson) {
        case (true, true): "Ships or local pickup"
        case (true, false): "Ships to you"
        default: "Local pickup"
        }
    }

    var symbol: String { ships ? "shippingbox" : "figure.walk" }

    /// The arrangements underneath the headline, in Facebook's own terms.
    ///
    /// Ordered by how much they change the buyer's day: being brought the item
    /// beats collecting it from a doorstep, which beats arranging to meet.
    var refinements: [String] {
        var out: [String] = []
        if doorDropoff { out.append("Seller drops off") }
        if doorPickup { out.append("Doorstep pickup") }
        if publicMeetup { out.append("Meets in public") }
        return out
    }

    /// Read as one phrase, so VoiceOver doesn't spell out a row of pills.
    var accessibilityDescription: String {
        ([headline] + refinements).joined(separator: ", ")
    }
}

extension Listing {
    var facebookListingID: String? {
        if id.hasPrefix("fb:"), Self.validFacebookID(String(id.dropFirst(3))) {
            return String(id.dropFirst(3))
        }
        return itemURL.flatMap(Self.facebookListingID(from:))
    }

    static func validFacebookID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    static func facebookListingID(from url: URL) -> String? {
        guard url.scheme == "https", url.user == nil,
              let host = url.host?.lowercased(), host == "facebook.com" || host.hasSuffix(".facebook.com") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, parts[0] == "marketplace", parts[1] == "item", validFacebookID(parts[2]) else { return nil }
        return parts[2]
    }

    var canonicalized: Listing {
        guard let facebookListingID else { return self }
        var value = self
        value.id = "fb:\(facebookListingID)"
        value.itemURL = URL(string: "https://www.facebook.com/marketplace/item/\(facebookListingID)/")
        return value
    }

    /// Temporary identity only for the legacy mobile DOM route. Never uploaded.
    static func identity(thumbnailURL: URL?, title: String?, priceText: String?) -> String {
        if let fbid = thumbnailURL.flatMap(Self.photoFBID) { return "p:\(fbid)" }
        return "h:\((title ?? "") + "|" + (priceText ?? ""))".lowercased()
    }

    /// fbcdn filenames look like `729964685_1105285382678938_1161471387555069882_n.jpg`;
    /// the middle group is the photo's FBID, retained as media metadata.
    static func photoFBID(_ url: URL) -> String? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let candidate = String(parts[1])
        return candidate.allSatisfy(\.isNumber) && candidate.count >= 10 ? candidate : nil
    }
}
