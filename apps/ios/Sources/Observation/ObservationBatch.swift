import CryptoKit
import Foundation
import OpenMarketProtos

/// Assembling one ingest call: everything one device read off one page at one
/// moment.
///
/// The batch is the unit because capture context describes the *page*. Carrying
/// it once here rather than on every card is also what keeps the device off the
/// observations — the server attaches a per-epoch pseudonym to the batch, and a
/// card has nowhere to put one (`docs/ingest-attribution.md` §2).
enum ObservationBatch {

    /// A search or discover page.
    ///
    /// `cardsSeen` is what the extractor *found* before parsing, which is a
    /// different number from what it managed to send. Without the pair, an
    /// extractor that drops every card on a page and a page with nothing on it
    /// arrive as the same empty batch — and that is the failure the whole
    /// ingest path exists to make loud.
    static func feed(
        payload: [PayloadListing],
        cards: [Listing],
        route: FacebookMarketplacePageRoute,
        session: BrowserSession,
        /// The marketplace's own currency, read once off the page. Every card
        /// it produced shares it, and without it none of them has a number.
        currency: String?,
        cardsSeen: Int,
        dropReasons: [String],
        shapeKeys: [String],
        observedAt: Date = Date()
    ) -> SubmitObservationsRequest? {
        // The payload and rendered card are independent reads of the same
        // price. A disagreement means at least one extractor attached the
        // wrong value, so neither copy is safe to submit.
        var priceConflicts = Set<String>()
        for item in payload {
            guard let payloadPrice = priceDigits(item.priceFormatted),
                  let card = cards.first(where: {
                      listingID(of: $0) == item.id || item.listingIdentity == $0.id
                  }),
                  let renderedPrice = priceDigits(card.priceText),
                  payloadPrice != renderedPrice else { continue }
            priceConflicts.insert(item.id)
            if let identity = item.listingIdentity { priceConflicts.insert(identity) }
        }
        let safePayload = payload.filter {
            !priceConflicts.contains($0.id) && !($0.listingIdentity.map(priceConflicts.contains) ?? false)
        }
        let safeCards = cards.filter {
            !priceConflicts.contains($0.id) && !(listingID(of: $0).map(priceConflicts.contains) ?? false)
        }
        var effectiveDropReasons = dropReasons
        if !priceConflicts.isEmpty { effectiveDropReasons.append("price_disagreement") }

        // **The payload and the DOM describe the same first page.**
        //
        // `renderedCards()` returns every card on screen, which includes the
        // ~15 the embedded payload already covered. Sending both copies puts
        // two cards claiming one listing in a single batch — the exact
        // signature of an extractor attributing a neighbour's fields to a
        // listing, so the server refuses *both* and the batch merges nothing.
        //
        // Payload first, so the richer source wins the key. A rendered card is
        // only added for a listing the payload did not describe, which is the
        // same rule `ListingStore.absorb` applies to the grid.
        var observations: [FacebookMarketplaceListingObservation] = []
        var claimedListingIDs = Set<String>()
        var claimedPhotoIDs = Set<String>()
        for observation in safePayload.compactMap({ ObservationCapture.observation(payload: $0, currency: currency) }) {
            appendIfUnclaimed(
                observation,
                to: &observations,
                listingIDs: &claimedListingIDs,
                photoIDs: &claimedPhotoIDs
            )
        }
        let fromPayload = observations.count
        for observation in safeCards.compactMap(ObservationCapture.observation(card:)) {
            appendIfUnclaimed(
                observation,
                to: &observations,
                listingIDs: &claimedListingIDs,
                photoIDs: &claimedPhotoIDs
            )
        }

        // The method describes the batch, and a batch that mixes the embedded
        // payload with the rendered tail is genuinely both. Calling it
        // EMBEDDED_GRAPHQL would tell the server the tail carries an exact
        // creation_time, which is the one thing it does not.
        let method: FacebookMarketplaceExtractionMethod
        switch (fromPayload > 0, observations.count > fromPayload) {
        case (true, true): method = .hybrid
        case (true, false): method = .embeddedGraphql
        default: method = .renderedDom
        }

        var request = SubmitObservationsRequest()
        request.context = ObservationCapture.context(
            variant: .desktop,
            route: route,
            method: method,
            session: session,
            observedAt: observedAt
        )
        request.extractorRevision = ObservationCapture.extractorRevision
        request.counts = counts(cardsSeen: max(cardsSeen, observations.count), dropReasons: effectiveDropReasons)
        if let fingerprint = shapeFingerprint(shapeKeys) {
            request.shapeFingerprint = fingerprint
        }
        request.observations = observations
        return request
    }

    /// One opened listing.
    static func item(
        listing: Listing,
        detail: ListingDetail,
        session: BrowserSession,
        variant: FacebookMarketplaceBrowserVariant,
        method: FacebookMarketplaceExtractionMethod,
        settled: Bool,
        observedAt: Date = Date()
    ) -> SubmitObservationsRequest? {
        guard let observation = ObservationCapture.observation(detail: detail, for: listing, settled: settled) else {
            return nil
        }
        var request = SubmitObservationsRequest()
        request.context = ObservationCapture.context(
            variant: variant,
            route: .item,
            method: method,
            session: session,
            observedAt: observedAt
        )
        request.extractorRevision = ObservationCapture.extractorRevision
        request.counts = counts(cardsSeen: 1, dropReasons: [])
        request.observations = [observation]
        return request
    }

    // MARK: - Pieces

    private static func priceDigits(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter { $0.isNumber }
        return digits.isEmpty ? nil : digits
    }

    private static func listingID(of listing: Listing) -> String? {
        listing.itemURL?.pathComponents.last
    }

    /// Claims every alias independently. A rich payload card can carry both
    /// aliases while its DOM copy carries only one; sharing either is enough to
    /// prove they describe the same listing.
    private static func appendIfUnclaimed(
        _ observation: FacebookMarketplaceListingObservation,
        to observations: inout [FacebookMarketplaceListingObservation],
        listingIDs: inout Set<String>,
        photoIDs: inout Set<String>
    ) {
        let key: FacebookListingKey
        switch observation.observation {
        case .search(let search): key = search.key
        case .detail(let detail): key = detail.key
        case .none: return
        }
        if (!key.facebookListingID.isEmpty && listingIDs.contains(key.facebookListingID)) ||
            (!key.coverPhotoFbid.isEmpty && photoIDs.contains(key.coverPhotoFbid)) {
            return
        }
        if !key.facebookListingID.isEmpty { listingIDs.insert(key.facebookListingID) }
        if !key.coverPhotoFbid.isEmpty { photoIDs.insert(key.coverPhotoFbid) }
        observations.append(observation)
    }

    private static func counts(cardsSeen: Int, dropReasons: [String]) -> ClientExtractionCounts {
        var counts = ClientExtractionCounts()
        counts.cardsSeen = Int32(cardsSeen)
        // Deduplicated and capped: the schema takes sixteen, and a reason
        // repeated once per dropped card is the same fact fifteen times.
        counts.dropReasons = Array(Set(dropReasons)).sorted().prefix(16).map { $0 }
        return counts
    }

    /// One hash of the key names a structured payload carried, values excluded.
    ///
    /// The names are already sorted and deduplicated by the extractor, so the
    /// same page shape always produces the same digest. A digest nobody has
    /// seen before, across many devices at once, is Facebook shipping a change
    /// — and it fires whether or not anything failed to parse, which is the
    /// point: a change that still parses is the one nobody notices.
    static func shapeFingerprint(_ keys: [String]) -> Data? {
        guard !keys.isEmpty else { return nil }
        var hasher = SHA256()
        for key in keys {
            hasher.update(data: Data(key.utf8))
            // A separator that cannot appear in a JSON key name, so ["ab","c"]
            // and ["a","bc"] cannot hash the same.
            hasher.update(data: Data([0x1f]))
        }
        return Data(hasher.finalize())
    }
}
