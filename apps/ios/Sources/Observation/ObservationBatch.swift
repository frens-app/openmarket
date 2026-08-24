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
        query: SearchQuery?,
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
        var claimed = Set<String>()
        for observation in payload.compactMap({ ObservationCapture.observation(payload: $0, currency: currency) }) {
            if claimed.insert(identity(of: observation)).inserted { observations.append(observation) }
        }
        let fromPayload = observations.count
        for observation in cards.compactMap(ObservationCapture.observation(card:)) {
            if claimed.insert(identity(of: observation)).inserted { observations.append(observation) }
        }
        guard !observations.isEmpty else { return nil }

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
        if let query, let context = queryContext(query) {
            request.query = context
        }
        request.extractorRevision = ObservationCapture.extractorRevision
        request.counts = counts(cardsSeen: max(cardsSeen, observations.count), dropReasons: dropReasons)
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
        settled: Bool,
        observedAt: Date = Date()
    ) -> SubmitObservationsRequest? {
        guard let observation = ObservationCapture.observation(detail: detail, for: listing, settled: settled) else {
            return nil
        }
        var request = SubmitObservationsRequest()
        request.context = ObservationCapture.context(
            variant: .desktop,
            route: .item,
            // The item extractor reads the rendered page and its embedded
            // objects together, which is what HYBRID names.
            method: .hybrid,
            session: session,
            observedAt: observedAt
        )
        request.extractorRevision = ObservationCapture.extractorRevision
        request.counts = counts(cardsSeen: 1, dropReasons: [])
        request.observations = [observation]
        return request
    }

    // MARK: - Pieces

    /// Both aliases together, so two cards for one listing collide here even
    /// when only one of them carries the listing id.
    ///
    /// Deliberately not "whichever key is present": a payload card has both and
    /// a mobile card has only the photo, and matching on whichever one happened
    /// to be set would let the same listing through twice.
    private static func identity(of observation: FacebookMarketplaceListingObservation) -> String {
        let key: FacebookListingKey
        switch observation.observation {
        case .search(let search): key = search.key
        case .detail(let detail): key = detail.key
        case .none: return UUID().uuidString
        }
        return "l:\(key.facebookListingID)|p:\(key.coverPhotoFbid)"
    }

    private static func counts(cardsSeen: Int, dropReasons: [String]) -> ClientExtractionCounts {
        var counts = ClientExtractionCounts()
        counts.cardsSeen = Int32(cardsSeen)
        // Deduplicated and capped: the schema takes sixteen, and a reason
        // repeated once per dropped card is the same fact fifteen times.
        counts.dropReasons = Array(Set(dropReasons)).sorted().prefix(16).map { $0 }
        return counts
    }

    /// The query, as the parameters that produced it.
    ///
    /// This is what makes a result set interpretable rather than merely
    /// present. A card carrying `is_sold` from an unfiltered query is a
    /// contradiction the server refuses, and the same card from
    /// `availability=out of stock` is the strongest public evidence of a sale
    /// there is (`docs/filter-parameters.md` §10). Only this field tells them
    /// apart.
    ///
    /// The search term is hashed here and never sent. It reaches the ingest
    /// boundary as a fingerprint so two runs of one query can be recognised as
    /// the same query, and for no other purpose.
    static func queryContext(_ query: SearchQuery) -> FacebookMarketplaceQueryContext? {
        var context = FacebookMarketplaceQueryContext()
        var carries = false

        if case .search(let term) = query.kind {
            let normalised = term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalised.isEmpty {
                context.queryTextSha256 = Data(SHA256.hash(data: Data(normalised.utf8)))
                carries = true
            }
        }
        switch query.availability {
        case .any: break
        case .available: context.availabilityFilter = .inStock; carries = true
        case .unavailable: context.availabilityFilter = .outOfStock; carries = true
        }
        if query.age != .any {
            context.daysSinceListed = Int32(query.age.rawValue)
            carries = true
        }
        if query.sort != .bestMatch {
            context.sortBy = query.sort.rawValue
            carries = true
        }
        if query.delivery != .any {
            context.deliveryMethod = query.delivery.rawValue
            carries = true
        }
        return carries ? context : nil
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
