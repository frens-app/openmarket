import Connect
import Foundation
import OpenMarketProtos

/// The server half of Price Check.
///
/// **One call that thinks, and one that writes things down.** `identify` sends
/// the photo and the description to a model and gets back what the item is,
/// what to search for, and the listing to paste. Everything after that happens
/// on this device: `ComparableSearch` finds the market — it has to, because it
/// runs in a `WKWebView` against the user's own Facebook session and the server
/// cannot reach that — and `PriceGuide` turns it into a price. `complete` then
/// reports what happened, and calls nothing.
///
/// Separate from `AccountSession` deliberately. That object is the account —
/// tokens, device, sign-in state — and every screen holds it. Price Check is
/// one feature that happens to need a token, and folding its calls in would put
/// its failures inside the object that decides whether the user is signed in.
@MainActor
final class PricingService {
    /// Everything the model produced, plus the id that ties the rest of the run
    /// to it.
    struct Identification {
        let priceCheckID: String
        let name: String
        let searchQueries: [String]
        let keyAttributes: [String]
        /// The listing, ready to paste. Either may be empty — the price is
        /// arithmetic and never depended on them.
        let listingTitle: String
        let listingBody: String

        /// What to actually search. The second query is a fallback phrasing of
        /// the same item, so the first is the one to try.
        var primaryQuery: String? { searchQueries.first }
    }

    private let session: AccountSession
    private lazy var client = PricingServiceClient(client: API.makeProtocolClient())

    init(session: AccountSession) {
        self.session = session
    }

    // MARK: - The run

    func identify(description: String, photos: [ItemPhoto]) async throws -> Identification {
        var request = IdentifyItemRequest()
        request.description_p = description
        // No photos is an empty list, not an error. The server runs on the
        // description alone, which is roughly what this tool did before it
        // could see anything — so a picker the user skipped degrades the answer
        // instead of blocking it.
        //
        // Order is preserved and meaningful: the first photo is the one the
        // seller led with, and the prompt tells the model they are one item
        // from several angles rather than several items.
        request.photos = photos.map(\.jpeg)

        let response = await client.identifyItem(request: request, headers: try await session.authorizedHeaders())
        let message = try unwrap(response)

        return Identification(
            priceCheckID: message.priceCheckID,
            name: message.identifiedName,
            searchQueries: message.searchQueries,
            keyAttributes: message.keyAttributes,
            listingTitle: message.listingTitle,
            listingBody: message.listingDescription
        )
    }

    /// Reports what the market held and what this device recommended.
    ///
    /// **Nothing comes back.** The price was computed here, from comparables
    /// scraped here; the server's only job is the row. Failure is therefore not
    /// worth surfacing — the user has their answer either way — so this throws
    /// only so the caller can decide, and the caller ignores it.
    func complete(
        priceCheckID: String,
        searchQuery: String,
        compsFound: Int,
        recommendedPrice: Int,
        guide: PriceGuide,
        sold: SoldSignal
    ) async throws {
        var request = CompletePriceCheckRequest()
        request.priceCheckID = priceCheckID
        request.searchQueryUsed = searchQuery
        request.compsFound = Int32(compsFound)
        request.recommendedPriceMinor = Int64(recommendedPrice) * 100
        request.stats = Self.stats(guide: guide, sold: sold)

        let response = await client.completePriceCheck(request: request,
                                                       headers: try await session.authorizedHeaders())
        _ = try unwrap(response)
    }

    // MARK: - Signals

    /// Records the answer to "were these results helpful?".
    ///
    /// Fire and forget, and deliberately silent on failure. This is telemetry
    /// about a run that has already finished and whose answer is already on
    /// screen; surfacing an error for it would interrupt somebody to tell them
    /// their opinion of the last screen didn't send.
    func submitFeedback(priceCheckID: String, helpful: Bool) async {
        guard let headers = try? await session.authorizedHeaders() else { return }
        var request = SubmitPriceCheckFeedbackRequest()
        request.priceCheckID = priceCheckID
        request.helpful = helpful
        _ = await client.submitPriceCheckFeedback(request: request, headers: headers)
    }

    /// Records that the price was copied to the pasteboard.
    ///
    /// The strongest evidence the tool worked, and the cheapest: copying the
    /// number is the action immediately before pasting it into Facebook's price
    /// box. It arrives from everybody who gets that far, where the feedback
    /// buttons are answered by the few who stop to tap one. Same fire-and-forget
    /// treatment, for the same reason.
    /// Records one copy, carrying only what was copied.
    ///
    /// Each field is left unset rather than zeroed or emptied when it is not
    /// what the user took. They are `optional` on the wire precisely so the
    /// server can tell "not part of this copy" from "copied, and it was empty"
    /// — and so three buttons are three calls that each say one true thing.
    func recordCopy(priceCheckID: String,
                    price: Int? = nil,
                    title: String? = nil,
                    description: String? = nil) async {
        guard let headers = try? await session.authorizedHeaders() else { return }
        var request = RecordPriceCheckCopyRequest()
        request.priceCheckID = priceCheckID
        if let price { request.copiedPriceMinor = Int64(price) * 100 }
        if let title { request.copiedListingTitle = title }
        if let description { request.copiedListingDescription = description }
        _ = await client.recordPriceCheckCopy(request: request, headers: headers)
    }

    // MARK: - History

    /// The runs already done, newest first.
    ///
    /// Read from the server rather than kept on the device, and that is the
    /// cheap answer rather than a compromise: the row has been written on every
    /// run since this feature existed — before the model is called, so a run
    /// that fails is still a row — so there was nothing to build but the read.
    /// It also means a history that survives a reinstall and follows the
    /// account onto a second phone, which a local cache would not.
    func recentChecks(limit: Int = 20) async throws -> [PastPriceCheck] {
        var request = ListPriceChecksRequest()
        request.limit = Int32(limit)
        let response = await client.listPriceChecks(request: request,
                                                    headers: try await session.authorizedHeaders())
        return try unwrap(response).checks.map(PastPriceCheck.init)
    }

    // MARK: - Wire

    private func unwrap<T>(_ response: ResponseMessage<T>) throws -> T {
        if let message = response.message { return message }
        throw response.error.map { ($0 as? ConnectError)?.asAPIError ?? APIError.network } ?? APIError.network
    }

    /// The market, as this device measured it.
    ///
    /// These used to be sent so a model could pick a point inside them without
    /// having to derive them — it cannot: asked to justify its own figure
    /// against fourteen prices, the previous one wrote "you are asking CA$20
    /// more than the median price of CA$80" when the median was CA$77 and the
    /// gap was CA$33. Now `PriceGuide` picks the point too, and these travel
    /// only so the row can say what the market looked like on the day.
    private static func stats(guide: PriceGuide, sold: SoldSignal) -> MarketStats {
        var stats = MarketStats()
        stats.pricedCount = Int32(guide.count)
        stats.medianMinor = Int64(guide.median ?? 0) * 100
        stats.lowestMinor = Int64(guide.lowest ?? 0) * 100
        stats.highestMinor = Int64(guide.highest ?? 0) * 100
        if let range = guide.typicalRange {
            stats.lowerQuartileMinor = Int64(range.lowerBound) * 100
            stats.upperQuartileMinor = Int64(range.upperBound) * 100
        }
        stats.currencySymbol = guide.currency
        stats.soldCount = Int32(sold.count)
        if let days = sold.medianDaysToSell { stats.medianDaysToSell = Int32(days) }
        return stats
    }
}
