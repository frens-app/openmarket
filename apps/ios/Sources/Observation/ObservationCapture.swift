import Foundation
import OpenMarketProtos
import SwiftProtobuf

/// Turning what an extractor read into what the server stores.
///
/// Two rules govern everything here, and both are about what is *not* built.
///
/// **Only a live read mints an observation.** `ListingStore.enrich` paints from
/// `ListingCache` before it revalidates, and returns the cached value when the
/// live read fails. So nothing in this file is reachable from the cache branch:
/// the call sites are the live paths, and a provenance on the value is what
/// keeps that true as the store changes (`docs/ingest-attribution.md` §2.4).
///
/// **Absent and empty stay different.** Every optional here is left unset when
/// the surface did not say, because the server reads an absent field as "this
/// capture could not see it" and an empty one as "Facebook said nothing is
/// there". Collapsing the two would let a signed-out capture erase a signed-in
/// fact.
enum ObservationCapture {

    /// Identifies the parser, not the app.
    ///
    /// **Bump this whenever an extractor changes what it reads or how.** It is
    /// what the server's circuit breaker groups by, so a fix for a Facebook
    /// change has to arrive under a new revision or it inherits the quarantine
    /// rate of the version it replaced and is switched off on its first batch.
    ///
    /// Not the app build: Debug pins that to 1 (`docs/data-model.md` §2), so it
    /// cannot tell two parsers apart on a developer's phone.
    static let extractorRevision = "desktop-2026-08-23"

    // MARK: - Context

    static func context(
        variant: FacebookMarketplaceBrowserVariant,
        route: FacebookMarketplacePageRoute,
        method: FacebookMarketplaceExtractionMethod,
        session: BrowserSession,
        observedAt: Date
    ) -> FacebookMarketplaceObservationContext {
        var context = FacebookMarketplaceObservationContext()
        context.browserVariant = variant
        context.pageRoute = route
        context.extractionMethod = method
        context.facebookAuthenticationState = session == .authed ? .signedIn : .signedOut
        context.observedAt = Google_Protobuf_Timestamp(date: observedAt)
        return context
    }

    // MARK: - Search cards

    /// A card from the embedded `MarketplaceSearch` payload.
    ///
    /// This is the richest search observation there is: an exact
    /// `creation_time`, a decimal price, delivery types and sold state, none of
    /// which the rendered tail carries.
    static func observation(
        payload item: PayloadListing,
        currency: String?
    ) -> FacebookMarketplaceListingObservation? {
        var search = FacebookMarketplaceSearchListingObservation()
        guard let key = key(facebookListingID: item.id, coverPhotoURL: item.photoURL.flatMap(URL.init(string:))) else {
            return nil
        }
        search.key = key

        if let title = item.title, !title.isEmpty { search.title = title }
        if let categoryID = item.categoryID { search.facebookCategoryID = categoryID }
        if let created = item.createdWithSellerApp { search.createdWithSellerApp = created }
        if let postedAt = item.postedAt { search.listedAt = Google_Protobuf_Timestamp(date: postedAt) }
        search.deliveryTypes = item.deliveryTypes

        var price = FacebookMarketplacePriceObservation()
        var carriesPrice = false
        if let amount = item.priceAmount { price.amountDecimal = amount; carriesPrice = true }
        if let formatted = item.priceFormatted { price.formattedAmount = formatted; carriesPrice = true }
        if let amount = item.strikethroughAmount { price.previousAmountDecimal = amount; carriesPrice = true }
        if let strike = item.strikethroughFormatted { price.previousFormattedAmount = strike; carriesPrice = true }
        // The page's currency, stamped on every card it produced. The decimal
        // above is unusable without it: scaling major units to minor needs the
        // currency's exponent, and `listing_price` publishes no code.
        //
        // Not read from the symbol in `formatted_amount` — "$" is CAD, AUD and
        // MXN as readily as USD.
        if let currency = currencyCode(currency) { price.currencyCode = currency; carriesPrice = true }
        if carriesPrice { search.price = price }

        if let place = place(city: item.city, region: item.state, placeID: item.cityPageID) {
            search.listingLocation = place
        }
        if let availability = availability(sold: item.isSold, pending: item.isPending, live: item.isLive) {
            search.availability = availability
        }
        if let photo = media(url: item.photoURL.flatMap(URL.init(string:)), position: 0) {
            search.primaryPhoto = photo
        }

        var observation = FacebookMarketplaceListingObservation()
        observation.search = search
        return observation
    }

    /// A card read out of the rendered DOM, past the payload's first page.
    ///
    /// Thinner on purpose. It carries no timestamp, no delivery types and no
    /// sold state, and the server ranks it below the payload for exactly those
    /// fields — so what it must not do is guess at any of them.
    static func observation(card listing: Listing) -> FacebookMarketplaceListingObservation? {
        var search = FacebookMarketplaceSearchListingObservation()
        guard let key = key(facebookListingID: facebookListingID(from: listing.itemURL),
                            coverPhotoURL: listing.thumbnailURL) else { return nil }
        search.key = key

        if let title = listing.title, !title.isEmpty { search.title = title }
        if let condition = listing.conditionText { search.condition = condition }
        if let text = listing.locationText {
            var place = FacebookMarketplacePlaceObservation()
            place.displayText = text
            search.listingLocation = place
        }
        if let priceText = listing.priceText {
            var price = FacebookMarketplacePriceObservation()
            // Rendered, not structured: "$20 - $40" and "Free" are both real
            // here, so the formatted string is the only honest field to fill.
            price.formattedAmount = priceText
            if let original = listing.originalPriceText { price.previousFormattedAmount = original }
            search.price = price
        }
        if let photo = media(url: listing.thumbnailURL, position: 0) {
            search.primaryPhoto = photo
        }

        var observation = FacebookMarketplaceListingObservation()
        observation.search = search
        return observation
    }

    // MARK: - Item pages

    /// One opened listing, from a live item-page read.
    ///
    /// `settled` is the caller's statement that the gallery finished loading
    /// and the seller re-poll completed. An unsettled capture may still add
    /// facts; the server will not let it shrink a gallery, because a truncated
    /// read and a listing whose photos were deleted look identical
    /// (`docs/ingest-attribution.md` §5.6).
    static func observation(
        detail: ListingDetail,
        for listing: Listing,
        settled: Bool
    ) -> FacebookMarketplaceListingObservation? {
        var item = FacebookMarketplaceListingDetailObservation()
        guard let key = key(facebookListingID: facebookListingID(from: listing.itemURL),
                            coverPhotoURL: listing.thumbnailURL) else { return nil }
        item.key = key
        item.captureSettled = settled

        if let title = listing.title, !title.isEmpty { item.title = title }
        if let description = detail.description, !description.isEmpty { item.description_p = description }
        if let condition = detail.conditionText { item.condition = condition }
        if let posted = detail.postedText { item.listedAtText = posted }
        if let fulfillment = detail.fulfillment ?? listing.fulfillment {
            item.deliveryTypes = deliveryTokens(fulfillment)
        }
        if let availability = availability(sold: detail.isSold, pending: detail.isPending, live: nil) {
            item.availability = availability
        }

        var place = FacebookMarketplacePlaceObservation()
        var carriesPlace = false
        if let text = detail.locationText ?? listing.locationText { place.displayText = text; carriesPlace = true }
        // Facebook's approximate point for the *listing*. It is never read as
        // the seller's, which is why nothing below copies it into the seller
        // message.
        if let latitude = detail.latitude, let longitude = detail.longitude {
            place.latitude = latitude
            place.longitude = longitude
            carriesPlace = true
        }
        if carriesPlace { item.listingLocation = place }

        if let priceText = listing.priceText {
            var price = FacebookMarketplacePriceObservation()
            price.formattedAmount = priceText
            if let original = listing.originalPriceText { price.previousFormattedAmount = original }
            item.price = price
        }

        item.media = detail.photoURLs.enumerated().compactMap { index, url in
            media(url: url, position: Int32(index))
        }
        item.seller = seller(from: detail)

        var observation = FacebookMarketplaceListingObservation()
        observation.detail = item
        return observation
    }

    // MARK: - Pieces

    /// The seller block, or a status saying why there isn't one.
    ///
    /// Signed out, the desktop item page has no seller section at all, so its
    /// absence there is `UNAVAILABLE` — unknown, not evidence that no seller
    /// exists. Signed in it is `NOT_OBSERVED`, which is an extraction gap worth
    /// logging rather than a fact about the listing.
    private static func seller(from detail: ListingDetail) -> FacebookMarketplaceSellerObservation {
        var seller = FacebookMarketplaceSellerObservation()

        let carriesSomething = detail.sellerName != nil
            || detail.sellerProfileID != nil
            || detail.sellerRating != nil
            || detail.sellerJoined != nil
        guard carriesSomething else {
            seller.sectionStatus = .notObserved
            return seller
        }

        seller.sectionStatus = .observed
        // Sent, never stored. The server hashes it into a cluster key and
        // discards the value.
        if let profileID = detail.sellerProfileID { seller.facebookProfileID = profileID }
        if let name = detail.sellerName { seller.displayName = name }
        if let joined = detail.sellerJoined {
            seller.joinedText = joined
            if let year = joinedYear(from: joined) { seller.joinedYear = year }
        }
        if let rating = detail.sellerRating { seller.rating = rating }
        if let count = detail.sellerRatingCount { seller.ratingCount = Int32(count) }
        if let highlyRated = detail.sellerIsHighlyRated { seller.highlyRated = highlyRated }
        return seller
    }

    /// The year out of "Joined Facebook in 2011".
    ///
    /// The raw string travels beside it. A year we failed to read and a page
    /// that carried none are different facts, and only the string tells them
    /// apart.
    private static func joinedYear(from text: String) -> Int32? {
        let digits = text.split(whereSeparator: { !$0.isNumber })
        guard let candidate = digits.last(where: { $0.count == 4 }),
              let year = Int32(candidate),
              (2004...2200).contains(year)
        else { return nil }
        return year
    }

    /// At least one Facebook key, or there is no observation to make.
    ///
    /// Desktop cards expose the listing id in every item href. A mobile card
    /// may only ever have the cover photo's FBID until it is opened, which is
    /// why that is an alias rather than a fallback.
    private static func key(facebookListingID: String?, coverPhotoURL: URL?) -> FacebookListingKey? {
        var key = FacebookListingKey()
        var identified = false
        if let id = facebookListingID, isFacebookID(id) {
            key.facebookListingID = id
            identified = true
        }
        if let url = coverPhotoURL, let fbid = Listing.photoFBID(url), isFacebookID(fbid) {
            key.coverPhotoFbid = fbid
            identified = true
        }
        return identified ? key : nil
    }

    /// The schema's own rule, applied before the request is built: eight digits
    /// or more. A value that fails it fails the whole card server-side, and
    /// spending a round trip to be told so helps nobody.
    private static func isFacebookID(_ value: String) -> Bool {
        value.count >= 8 && value.allSatisfy(\.isNumber)
    }

    /// The listing id out of a canonical item URL.
    static func facebookListingID(from url: URL?) -> String? {
        guard let url else { return nil }
        let parts = url.pathComponents
        guard let marker = parts.firstIndex(of: "item"), parts.index(after: marker) < parts.endIndex else {
            return nil
        }
        let candidate = parts[parts.index(after: marker)]
        return isFacebookID(candidate) ? candidate : nil
    }

    /// Three letters, or nothing. The schema requires exactly three, so a
    /// value of any other shape is dropped here rather than failing the card at
    /// the server for a field the card had no say in.
    private static func currencyCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let code = raw.trimmingCharacters(in: .whitespaces).uppercased()
        guard code.count == 3, code.allSatisfy(\.isLetter) else { return nil }
        return code
    }

    private static func place(city: String?, region: String?, placeID: String?) -> FacebookMarketplacePlaceObservation? {
        var place = FacebookMarketplacePlaceObservation()
        var carries = false
        if let city { place.city = city; carries = true }
        if let region { place.region = region; carries = true }
        if let placeID, isFacebookID(placeID) { place.facebookPlaceID = placeID; carries = true }
        if let city {
            place.displayText = region.map { "\(city), \($0)" } ?? city
        }
        return carries ? place : nil
    }

    /// Facebook's three independent booleans, carried as three.
    ///
    /// Nothing is defaulted. `is_live` travels because it is part of the raw
    /// record, and the server does not derive availability from it: it has been
    /// observed true on sold cards.
    private static func availability(sold: Bool?, pending: Bool?, live: Bool?) -> FacebookMarketplaceAvailabilityObservation? {
        guard sold != nil || pending != nil || live != nil else { return nil }
        var availability = FacebookMarketplaceAvailabilityObservation()
        if let sold { availability.sold = sold }
        if let pending { availability.pending = pending }
        if let live { availability.live = live }
        return availability
    }

    /// A photo the server can name.
    ///
    /// An fbcdn URL expires; the FBID in its filename does not. A photo whose
    /// filename yields no id is skipped rather than sent, because the server
    /// cannot deduplicate it and would grow the gallery by one on every capture.
    private static func media(url: URL?, position: Int32) -> FacebookMarketplaceMediaObservation? {
        guard let url, let fbid = Listing.photoFBID(url) else { return nil }
        var media = FacebookMarketplaceMediaObservation()
        media.facebookPhotoID = fbid
        media.url = url.absoluteString
        media.position = position
        return media
    }

    /// Back to Facebook's own tokens.
    ///
    /// `Fulfillment` is a parsed summary and the server wants the source
    /// vocabulary, so this reverses the mapping in `Fulfillment.init(tokens:)`.
    /// A token that parser did not recognise is already lost by this point —
    /// it is logged where it is dropped (`docs/parsing-conventions.md` §1).
    private static func deliveryTokens(_ fulfillment: Fulfillment) -> [String] {
        var tokens: [String] = []
        if fulfillment.ships { tokens.append("SHIPPING_ONSITE") }
        if fulfillment.inPerson { tokens.append("IN_PERSON") }
        if fulfillment.doorPickup { tokens.append("DOOR_PICKUP") }
        if fulfillment.doorDropoff { tokens.append("DOOR_DROPOFF") }
        if fulfillment.publicMeetup { tokens.append("PUBLIC_MEETUP") }
        return tokens
    }
}
