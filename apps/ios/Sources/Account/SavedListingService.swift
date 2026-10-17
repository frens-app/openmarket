import Connect
import Foundation
import OpenMarketProtos
import SwiftProtobuf

struct SavedListingEntry: Codable, Equatable {
    var listing: Listing
    var savedAt: Date
}

struct AlertSaveContext {
    let alertID: String
    var notificationID: String?
    var source = "alerts_tab"
}

/// Frozen wire payloads make retries equivalent across relaunches.
struct SavedListingMutation: Codable, Equatable {
    let id: String
    let listingID: String
    let data: Data

    var savesListing: Bool { (try? SavedListingChange(serializedBytes: data))?.saved == true }
    var changesSavedState: Bool { (try? SavedListingChange(serializedBytes: data))?.hasSaved == true }

    init(listing: Listing, saved: Bool?, savedAt: Date?, alertContext: AlertSaveContext? = nil) throws {
        guard let facebookID = listing.facebookListingID else { throw APIError.network }
        id = UUID().uuidString.lowercased()
        listingID = "fb:\(facebookID)"
        var change = SavedListingChange()
        change.mutationID = id
        change.facebookListingID = facebookID
        if let saved { change.saved = saved }
        if saved != false { change.snapshot = listing.savedSnapshot }
        if let savedAt { change.savedAt = Google_Protobuf_Timestamp(date: savedAt) }
        if saved == true, let alertContext {
            var source = ListingAlertSaveSource()
            source.alertID = alertContext.alertID
            source.source = alertContext.source
            if let notificationID = alertContext.notificationID { source.notificationID = notificationID }
            change.alertSource = source
        }
        data = try change.serializedData()
    }
}

@MainActor
protocol SavedListingSyncService {
    func apply(_ changes: [SavedListingMutation], userID: String) async throws -> [String: String]
    func list(userID: String) async throws -> [SavedListingEntry]
}

@MainActor
final class SavedListingService: SavedListingSyncService {
    private let account: AccountSession
    private lazy var client = SavedListingServiceClient(client: API.makeProtocolClient())
    init(account: AccountSession? = nil) { self.account = account ?? .shared }

    private func headers(_ userID: String) async throws -> Headers {
        guard account.state.viewer?.id == userID else { throw CancellationError() }
        let value = try await account.authorizedHeaders()
        guard account.state.viewer?.id == userID else { throw CancellationError() }
        return value
    }

    private func unwrap<T>(_ response: ResponseMessage<T>) throws -> T {
        if let error = response.error { throw error.asAPIError }
        guard let message = response.message else { throw APIError.network }
        return message
    }

    func apply(_ changes: [SavedListingMutation], userID: String) async throws -> [String: String] {
        var request = ApplySavedListingChangesRequest()
        request.changes = try changes.map { try SavedListingChange(serializedBytes: $0.data) }
        let response = try unwrap(await client.applySavedListingChanges(request: request, headers: try await headers(userID)))
        let results = Dictionary(response.results.map { ($0.mutationID, $0.error) }, uniquingKeysWith: { _, last in last })
        guard changes.allSatisfy({ results[$0.id] != nil }) else { throw APIError.network }
        return results
    }

    func list(userID: String) async throws -> [SavedListingEntry] {
        var result: [SavedListingEntry] = []
        var request = ListSavedListingsRequest()
        repeat {
            let response = try unwrap(await client.listSavedListings(request: request, headers: try await headers(userID)))
            result += response.listings.map { SavedListingEntry(listing: $0.snapshot.listing, savedAt: $0.savedAt.date) }
            request.afterID = response.nextAfterID
        } while !request.afterID.isEmpty
        return result
    }
}

extension Listing {
    var hasSaveMetadata: Bool {
        facebookListingID != nil && title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    var savedSnapshot: SavedListingSnapshot {
        var s = SavedListingSnapshot()
        s.facebookListingID = facebookListingID ?? ""
        s.cardObservedAt = Google_Protobuf_Timestamp(date: capturedAt)
        s.priceObservedAt = Google_Protobuf_Timestamp(date: priceObservedAt ?? capturedAt)
        if let value = thumbnailURL.flatMap(Self.photoFBID) { s.coverPhotoFbid = value }
        if let title { s.title = title }
        if let priceText { s.priceText = priceText }
        if let originalPriceText { s.originalPriceText = originalPriceText }
        if priceText != nil {
            if let amount = exactPriceAmount { s.priceAmountDecimal = amount }
            if let code = currencyCode { s.priceCurrencyCode = code }
        }
        if originalPriceText != nil, let amount = exactOriginalPriceAmount { s.originalPriceAmountDecimal = amount }
        if let value = locationText ?? detail?.locationText { s.locationText = value }
        if let value = conditionText ?? detail?.conditionText { s.conditionText = value }
        // A card can borrow static fields from cached detail. Do not advertise
        // those fields as newer than either source when restoring them elsewhere.
        if (locationText == nil && detail?.locationText != nil)
            || (conditionText == nil && detail?.conditionText != nil)
            || (fulfillment == nil && detail?.fulfillment != nil) {
            if let detailObservedAt {
                s.cardObservedAt = Google_Protobuf_Timestamp(date: min(capturedAt, detailObservedAt))
            }
        }
        if let thumbnailURL { s.thumbnailURL = thumbnailURL.absoluteString }
        if let detail, let detailObservedAt {
            s.detailObservedAt = Google_Protobuf_Timestamp(date: detailObservedAt)
            if let value = detail.description { s.description_p = value }
            s.photoUrls = Array(detail.photoURLs.prefix(12)).map(\.absoluteString)
            if let value = detail.postedText { s.postedText = value }
            if let value = detail.latitude { s.latitude = value }
            if let value = detail.longitude { s.longitude = value }
            if let seller = SellerProfile(detail: detail) { s.seller = seller.serverProfile }
        }
        let useDetailAvailability = (detail?.isSold != nil || detail?.isPending != nil)
            && detailObservedAt != nil && (availabilityObservedAt == nil || detailObservedAt! > availabilityObservedAt!)
        if let at = useDetailAvailability ? detailObservedAt : availabilityObservedAt {
            s.availabilityObservedAt = Google_Protobuf_Timestamp(date: at)
            if let sold = useDetailAvailability ? detail?.isSold : observedSold { s.sold = sold }
            if let pending = useDetailAvailability ? detail?.isPending : observedPending { s.pending = pending }
        }
        if let fulfillment = fulfillment ?? detail?.fulfillment {
            s.ships = fulfillment.ships; s.inPerson = fulfillment.inPerson
            s.doorPickup = fulfillment.doorPickup; s.doorDropoff = fulfillment.doorDropoff
            s.publicMeetup = fulfillment.publicMeetup
        }
        return s
    }
}

extension SavedListingSnapshot {
    var listing: Listing {
        var value = Listing(id: "fb:\(facebookListingID)", title: hasTitle ? title : nil,
                            priceText: hasPriceText ? priceText : nil,
                            originalPriceText: hasOriginalPriceText ? originalPriceText : nil,
                            locationText: hasLocationText ? locationText : nil,
                            conditionText: hasConditionText ? conditionText : nil,
                            thumbnailURL: hasThumbnailURL ? URL(string: thumbnailURL) : nil,
                            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(facebookListingID)/"),
                            badgeText: hasSold && sold ? "Sold" : (hasPending && pending ? "Pending" : nil),
                            cardIndex: 0, capturedAt: cardObservedAt.date)
        value.priceObservedAt = hasPriceObservedAt ? priceObservedAt.date : nil
        value.priceAmountDecimal = hasPriceAmountDecimal ? priceAmountDecimal : nil
        value.priceCurrencyCode = hasPriceCurrencyCode ? priceCurrencyCode : nil
        value.originalPriceAmountDecimal = hasOriginalPriceAmountDecimal ? originalPriceAmountDecimal : nil
        if hasShips || hasInPerson || hasDoorPickup || hasDoorDropoff || hasPublicMeetup {
            value.fulfillment = Fulfillment(tokens: [ships ? "SHIPPING" : nil, inPerson ? "IN_PERSON" : nil,
                doorPickup ? "DOOR_PICKUP" : nil, doorDropoff ? "DOOR_DROPOFF" : nil,
                publicMeetup ? "PUBLIC_MEETUP" : nil].compactMap { $0 })
        }
        var detail = ListingDetail()
        detail.description = hasDescription_p ? description_p : nil
        detail.photoURLs = photoUrls.compactMap(URL.init(string:))
        detail.postedText = hasPostedText ? postedText : nil
        detail.conditionText = value.conditionText
        detail.locationText = value.locationText
        detail.latitude = hasLatitude ? latitude : nil
        detail.longitude = hasLongitude ? longitude : nil
        detail.isSold = hasSold ? sold : nil
        detail.isPending = hasPending ? pending : nil
        detail.fulfillment = value.fulfillment
        if hasSeller, let profile = SellerProfile(serverProfile: seller) {
            detail.sellerProfileID = profile.id; detail.sellerName = profile.name
            detail.sellerPhotoURL = profile.photoURL; detail.sellerJoined = profile.joinedText
            detail.sellerRating = profile.rating; detail.sellerRatingCount = profile.ratingCount
            detail.sellerIsHighlyRated = profile.isHighlyRated
        }
        if hasDetailObservedAt { value.detail = detail; value.detailObservedAt = detailObservedAt.date }
        value.observedSold = hasSold ? sold : nil
        value.observedPending = hasPending ? pending : nil
        value.availabilityObservedAt = hasAvailabilityObservedAt ? availabilityObservedAt.date : nil
        return value
    }
}
