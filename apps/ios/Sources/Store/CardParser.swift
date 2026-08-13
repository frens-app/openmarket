import Foundation

/// Turns WebLite's raw text runs into `Listing` values.
///
/// Cards carry no labels — just an image and a couple of text blocks — so
/// fields are identified by pattern rather than position, and every one of them
/// is optional — a card missing a field still renders.
enum CardParser {
    /// Badges Facebook overlays on the thumbnail. They arrive mixed into the
    /// card text and would otherwise be mistaken for a title.
    static let knownBadges = ["price drop", "just listed", "sold", "pending", "sponsored", "free shipping"]

    static func parse(_ card: FeedEngine.RawCard, now: Date = Date()) -> Listing? {
        // The card's own aria-label is richer than anything it renders: an
        // untruncated title, the condition, and a city that one of the two
        // search layouts omits from the visible text entirely.
        let label = card.label.flatMap(CardLabel.parse)
        let runs = normalizedRuns(card)
        guard !runs.isEmpty || label != nil else { return nil }

        let badge = runs.first { knownBadges.contains($0.lowercased()) }
        let remaining = runs.filter { $0 != badge }

        let priceRuns = remaining.filter(isPrice)
        // A struck-through original price follows the current one ("$25" "$40")
        // — when the two are separate runs at all. Inline, they arrive as one
        // ("$25$40"), which `PriceRun` takes apart below.
        let originalPrice = priceRuns.count > 1 ? priceRuns[1] : nil

        let renderedTitle = remaining
            .filter { !isPrice($0) && !isLocation($0) }
            .max(by: { $0.count < $1.count })

        // The label wins wherever it has a value. Its title is the full one
        // rather than the elided render, and its city exists on layouts where
        // no city is drawn at all. Price stays render-first because the runs
        // also carry the struck-through original, which the label omits.
        let title = label?.title ?? renderedTitle
        let location = label?.locationText ?? remaining.first(where: isLocation)
        let (price, resolvedOriginal) = PriceRun.resolve(price: priceRuns.first ?? label?.priceText,
                                                        original: originalPrice)
        let thumbnail = card.imageURL.flatMap(URL.init(string:))

        // A card with neither a price nor a title is chrome, not a listing.
        guard price != nil || title != nil else { return nil }

        return Listing(
            // Identity is unaffected by the split above wherever it matters:
            // this falls back to a title+price hash only for a card with no
            // photo, and a card with no photo has no thumbnail to lose.
            id: Listing.identity(thumbnailURL: thumbnail, title: title, priceText: price),
            title: title,
            priceText: price,
            originalPriceText: resolvedOriginal,
            locationText: location,
            conditionText: label?.conditionText,
            thumbnailURL: thumbnail,
            itemURL: nil,
            badgeText: badge,
            cardIndex: card.index,
            detail: nil,
            capturedAt: now
        )
    }

    /// The h3 runs are reliable; `fullText` is the fallback when a card's text
    /// isn't split into headings at all.
    private static func normalizedRuns(_ card: FeedEngine.RawCard) -> [String] {
        let fromHeadings = card.texts
            .flatMap { $0.components(separatedBy: .newlines) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !fromHeadings.isEmpty { return fromHeadings }
        return card.fullText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// "Free", "$1,200", "£40", "€15", "Please contact" — all stay strings.
    static func isPrice(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered == "free" { return true }
        guard text.count <= 24 else { return false }
        let symbols: Set<Character> = ["$", "£", "€", "¥", "₹", "₩"]
        return text.contains(where: symbols.contains) && text.contains(where: \.isNumber)
    }

    /// Mobile cards usually omit location, but when present it looks like
    /// "Berkeley, CA".
    static func isLocation(_ text: String) -> Bool {
        guard text.count <= 40, text.contains(",") else { return false }
        let parts = text.split(separator: ",")
        guard parts.count == 2 else { return false }
        let region = parts[1].trimmingCharacters(in: .whitespaces)
        return region.count <= 3 && region.allSatisfy { $0.isUppercase }
    }
}
