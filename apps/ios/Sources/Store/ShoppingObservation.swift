import Foundation
import OpenMarketProtos

extension ShoppingFulfillment {
    init(_ value: Fulfillment) {
        self.init()
        ships = value.ships; inPerson = value.inPerson; doorPickup = value.doorPickup
        doorDropoff = value.doorDropoff; publicMeetup = value.publicMeetup
    }
    var parsed: Fulfillment? {
        var tokens: [String] = []
        if ships { tokens.append("SHIPPING_ONSITE") }
        if inPerson { tokens.append("IN_PERSON") }
        if doorPickup { tokens.append("DOOR_PICKUP") }
        if doorDropoff { tokens.append("DOOR_DROPOFF") }
        if publicMeetup { tokens.append("PUBLIC_MEETUP") }
        return Fulfillment(tokens: tokens)
    }
}

extension ShoppingListing {
    init(_ listing: Listing, source: String) {
        self.init()
        id = listing.id
        if let value = listing.title { title = value }
        if let value = listing.priceText { priceText = value }
        if let value = listing.originalPriceText { originalPriceText = value }
        if let value = listing.locationText { locationText = value }
        if let value = listing.conditionText { conditionText = value }
        if let value = listing.thumbnailURL { thumbnailURL = value.absoluteString }
        if let value = listing.badgeText { badgeText = value }
        if let value = listing.fulfillment { fulfillment = ShoppingFulfillment(value) }
        observedAtUnix = Int64(listing.capturedAt.timeIntervalSince1970)
        captureSource = source
        if let value = listing.detail {
            var d = ShoppingDetail()
            if let v = value.description { d.description_p = v }
            d.photoUrls = value.photoURLs.map(\.absoluteString)
            if let v = value.postedText { d.postedText = v }
            if let v = value.conditionText { d.conditionText = v }
            if let v = value.locationText { d.locationText = v }
            if let v = value.sellerProfileID { d.sellerProfileID = v }
            if let v = value.sellerName { d.sellerName = v }
            if let v = value.sellerJoined { d.sellerJoined = v }
            if let v = value.sellerRating { d.sellerRating = v }
            if let v = value.sellerRatingCount { d.sellerRatingCount = Int32(v) }
            if let v = value.sellerIsHighlyRated { d.sellerIsHighlyRated = v }
            if let v = value.latitude { d.latitude = v }
            if let v = value.longitude { d.longitude = v }
            if let v = value.isSold { d.isSold = v }
            if let v = value.isPending { d.isPending = v }
            if let v = value.fulfillment { d.fulfillment = ShoppingFulfillment(v) }
            detail = d
        }
    }

    var parsed: Listing {
        var value = Listing(id: id, title: hasTitle ? title : nil, priceText: hasPriceText ? priceText : nil,
                            originalPriceText: hasOriginalPriceText ? originalPriceText : nil,
                            locationText: hasLocationText ? locationText : nil,
                            conditionText: hasConditionText ? conditionText : nil,
                            fulfillment: hasFulfillment ? fulfillment.parsed : nil,
                            thumbnailURL: hasThumbnailURL ? URL(string: thumbnailURL) : nil,
                            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(id.replacingOccurrences(of: "fb:", with: ""))/"),
                            badgeText: hasBadgeText ? badgeText : nil, cardIndex: 0,
                            capturedAt: Date(timeIntervalSince1970: Double(observedAtUnix)))
        if hasDetail {
            let d = detail
            var parsed = ListingDetail()
            parsed.description = d.hasDescription_p ? d.description_p : nil
            parsed.photoURLs = d.photoUrls.compactMap(URL.init(string:))
            parsed.postedText = d.hasPostedText ? d.postedText : nil
            parsed.conditionText = d.hasConditionText ? d.conditionText : nil
            parsed.locationText = d.hasLocationText ? d.locationText : nil
            parsed.sellerProfileID = d.hasSellerProfileID ? d.sellerProfileID : nil
            parsed.sellerName = d.hasSellerName ? d.sellerName : nil
            parsed.sellerJoined = d.hasSellerJoined ? d.sellerJoined : nil
            parsed.sellerRating = d.hasSellerRating ? d.sellerRating : nil
            parsed.sellerRatingCount = d.hasSellerRatingCount ? Int(d.sellerRatingCount) : nil
            parsed.sellerIsHighlyRated = d.hasSellerIsHighlyRated ? d.sellerIsHighlyRated : nil
            parsed.latitude = d.hasLatitude ? d.latitude : nil
            parsed.longitude = d.hasLongitude ? d.longitude : nil
            parsed.isSold = d.hasIsSold ? d.isSold : nil
            parsed.isPending = d.hasIsPending ? d.isPending : nil
            parsed.fulfillment = d.hasFulfillment ? d.fulfillment.parsed : nil
            value.detail = parsed
        }
        return value
    }
}
