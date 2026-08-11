import Connect
import Foundation
import OpenMarketProtos

/// The server half of Price Check.
///
/// Two calls with the phone's own work between them, because the comparable
/// search cannot move off the device: it runs in a `WKWebView` against the
/// user's own Facebook session, and the server has no way to reach that. So
/// this identifies the item, hands back what to search for, and is called again
/// once `ComparableSearch` has a market.
///
/// Separate from `AccountSession` deliberately. That object is the account —
/// tokens, device, sign-in state — and every screen holds it. Price Check is
/// one feature that happens to need a token, and folding its calls in would put
/// its failures inside the object that decides whether the user is signed in.
@MainActor
final class PricingService {
    /// What the identify call came back with, plus the id that ties the rest of
    /// the run to it.
    struct Identification {
        let priceCheckID: String
        let name: String
        let searchQueries: [String]
        let condition: ItemCondition
        let keyAttributes: [String]

        /// What to actually search. The second query is a fallback phrasing of
        /// the same item, so the first is the one to try.
        var primaryQuery: String? { searchQueries.first }
    }

    /// The listing, as written.
    ///
    /// Named `Draft` rather than `Listing`: the app already has a `Listing`,
    /// and it means something quite different — a card read off Facebook. This
    /// is text on its way *to* Facebook, and nothing has been posted.
    struct Draft {
        /// Whole units, converted back from the minor units the wire carries.
        let price: Int
        let title: String
        let body: String
    }

    private let session: AccountSession
    private lazy var client = PricingServiceClient(client: API.makeProtocolClient())

    init(session: AccountSession) {
        self.session = session
    }

    // MARK: - The run

    func identify(description: String, photo: ItemPhoto?) async throws -> Identification {
        var request = IdentifyItemRequest()
        request.description_p = description
        // A missing photo is an empty list, not an error. The server runs on
        // the description alone, which is roughly what this tool did before it
        // could see anything — so a picker the user skipped degrades the answer
        // instead of blocking it.
        request.photos = photo.map { [$0.jpeg] } ?? []

        let response = await client.identifyItem(request: request, headers: try await session.authorizedHeaders())
        let message = try unwrap(response)

        return Identification(
            priceCheckID: message.priceCheckID,
            name: message.identifiedName,
            searchQueries: message.searchQueries,
            condition: message.condition,
            keyAttributes: message.keyAttributes
        )
    }

    func price(
        priceCheckID: String,
        searchQuery: String,
        marketName: String,
        comparables: [MarketComp],
        guide: PriceGuide,
        sold: SoldSignal
    ) async throws -> Draft {
        var request = PriceItemRequest()
        request.priceCheckID = priceCheckID
        request.searchQueryUsed = searchQuery
        request.marketName = marketName
        request.comparables = comparables.map(Self.proto(from:))
        request.stats = Self.stats(guide: guide, sold: sold)

        let response = await client.priceItem(request: request, headers: try await session.authorizedHeaders())
        let message = try unwrap(response)

        return Draft(
            price: Int(message.recommendedPriceMinor / 100),
            title: message.title,
            body: message.description_p
        )
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
    func recordPriceCopied(priceCheckID: String) async {
        guard let headers = try? await session.authorizedHeaders() else { return }
        var request = RecordPriceCopiedRequest()
        request.priceCheckID = priceCheckID
        _ = await client.recordPriceCopied(request: request, headers: headers)
    }

    // MARK: - Wire

    private func unwrap<T>(_ response: ResponseMessage<T>) throws -> T {
        if let message = response.message { return message }
        throw response.error.map { ($0 as? ConnectError)?.asAPIError ?? APIError.network } ?? APIError.network
    }

    private static func proto(from comp: MarketComp) -> ProtoComparable {
        var out = ProtoComparable()
        out.title = comp.listing.title ?? ""
        // Minor units on the wire. Absent stays absent: a card with no readable
        // price is a different fact from a card priced at nothing, and Free is
        // what zero means.
        if let price = comp.price { out.priceMinor = Int64(price) * 100 }
        out.isSold = comp.isSold
        if let days = comp.daysListed { out.daysListed = Int32(days) }
        if let city = comp.listing.locationText { out.city = city }
        return out
    }

    /// The numbers, computed here and sent rather than left to be worked out.
    ///
    /// This is the load-bearing half of the request. A model cannot do
    /// arithmetic about evidence it was just shown — asked to justify its own
    /// figure against fourteen prices, the previous one wrote "you are asking
    /// CA$20 more than the median price of CA$80" when the median was CA$77 and
    /// the gap was CA$33. So `PriceGuide` decides what the market looks like,
    /// and the model only decides where inside it to sit.
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
