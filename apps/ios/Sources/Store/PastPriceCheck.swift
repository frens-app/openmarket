import Foundation
import OpenMarketProtos

/// A run that already happened, as much of it as survives.
///
/// **The comparables are not in here, and never were anywhere.** Nothing has
/// ever stored them: a card that was live during the run is a 404 a week later,
/// and a strip of dead listings under a price is worse than no strip. So a past
/// check can say what it decided and roughly what from — a count and a search
/// term — and cannot show its working the way a fresh run does.
///
/// What does survive is the part people come back for. The listing copy is
/// still exactly as useful a week later as it was the minute it was written,
/// which is most of the argument for having this screen at all.
struct PastPriceCheck: Identifiable, Hashable {
    let id: String
    let ranAt: Date?
    /// What the model called it, and what the seller typed. Both are kept
    /// because either can be the empty one, and `label` picks.
    let identifiedName: String
    let described: String
    /// Whole units, as everything on the device deals in. Nil on a run that
    /// found no market — which stays in the list, because "I checked that and
    /// it found nothing" is a thing a person remembers doing and would
    /// otherwise repeat.
    let price: Int?
    let currency: String
    let compsFound: Int
    let soldFound: Int
    let searchTerm: String
    let listingTitle: String
    let listingBody: String

    init(_ summary: PriceCheckSummary) {
        id = summary.priceCheckID
        ranAt = ISO8601DateFormatter().date(from: summary.createdAt)
        identifiedName = summary.identifiedName
        described = summary.description_p
        // Minor units on the wire, whole units here, matching what the run
        // itself sends: the phone reads whole-unit prices off rendered cards
        // and multiplies on the way out, so this is that same conversion
        // backwards rather than a second opinion about precision.
        price = summary.hasRecommendedPriceMinor ? Int(summary.recommendedPriceMinor / 100) : nil
        currency = summary.currencySymbol.isEmpty ? "$" : summary.currencySymbol
        compsFound = Int(summary.compsFound)
        soldFound = Int(summary.soldFound)
        searchTerm = summary.searchQueryUsed
        listingTitle = summary.listingTitle
        listingBody = summary.listingDescription
    }

    /// What to call it in a list. The identification, or failing that what the
    /// seller typed — a row with neither is not returned by the server.
    var label: String {
        identifiedName.isEmpty ? described : identifiedName
    }

    var priceText: String? {
        price.map { "\(currency)\($0)" }
    }

    /// "2 days ago", and nothing at all for a run with no timestamp.
    ///
    /// Relative rather than a date, because the question a row answers is "is
    /// this still worth anything" — a price check from this morning is current
    /// and one from March is a curiosity, and "March 4" makes the reader do
    /// that subtraction themselves.
    var whenText: String? {
        guard let ranAt else { return nil }
        return Self.relative.localizedString(for: ranAt, relativeTo: Date())
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var hasListing: Bool { !listingTitle.isEmpty || !listingBody.isEmpty }

    /// What the price rested on, in the two numbers that were kept.
    ///
    /// Prose rather than the "15 · 13" form the fresh run uses, because this
    /// one has to finish a sentence about the listings being gone — and a
    /// middle dot reads as a label, not as something you can say.
    ///
    /// Deliberately a count and not a claim you can click: the strip of cards
    /// that justified this price is not stored. Saying how many there were is
    /// honest; implying they can be looked at again is not.
    var evidenceText: String? {
        guard compsFound > 0 || soldFound > 0 else { return nil }
        let listed = "\(compsFound) nearby listing\(compsFound == 1 ? "" : "s")"
        return soldFound > 0 ? "\(listed) and \(soldFound) sold" : listed
    }
}
