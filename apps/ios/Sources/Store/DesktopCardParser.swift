import Foundation

/// One rendered desktop card, before classification.
struct DesktopRawCard: Decodable {
    let id: String
    let label: String
    let imageURL: String
    let text: String
    /// The card's own visible text, one entry per rendered line. The only
    /// source of fields for cards past the first server-rendered page, which
    /// carry no `aria-label` — see `DesktopCardParser.parse(lines:)`.
    var lines: [String] = []
}

/// Turns a desktop card's `aria-label` into a listing.
///
/// The label is the whole reason the markup-only tail is usable. Desktop packs
/// title, price, an optional was-price, city and the listing id into one
/// string:
///
///     "Black L-Shaped Corner Desk with Monitor Shelf, $40, San Francisco, CA, listing 1054280080442808"
///     "Wooden writing desk with gray hutch, $50, reduced from $70, San Francisco, CA, listing 1624050395351390"
///     "Office desk, $80, , listing 2508057202946956"          <- shipping: city segment empty
///
/// Parsing is in Swift rather than JavaScript so the rules are testable outside
/// a webview, and it works from the *end* backwards because the title is
/// the only field that can itself contain commas.
enum DesktopCardParser {

    static func parse(_ raw: DesktopRawCard, cardIndex: Int) -> Listing? {
        parseLabel(raw, cardIndex: cardIndex) ?? parseLines(raw, cardIndex: cardIndex)
    }

    /// Cards past the first server-rendered page, which have no `aria-label`.
    ///
    /// **Infinite scroll produces a different card.** The label route above only
    /// ever works on what the server rendered; every card the feed lazy-inserts
    /// has `aria-label=""` while its anchor, image and text are all present.
    /// Reading only the label meant that past the first ~20 cards the app
    /// harvested nothing at all — measured signed in, 16-of-16 and 23-of-23
    /// cards rejected per screen while the feed happily paginated.
    ///
    /// The visible text is laid out one field per line, in a fixed order:
    ///
    ///     $300
    ///     6 foot LED crouching warewolf animatronic Halloween display
    ///     Vancouver, WA
    ///
    /// Matched by *shape* rather than position, because the leading line is
    /// sometimes a badge and the trailing city is absent on shipping listings.
    /// No listing id is needed — the caller already has it from the href.
    static func parseLines(_ raw: DesktopRawCard, cardIndex: Int) -> Listing? {
        var lines = raw.lines.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        lines.removeAll { line in
            CardParser.knownBadges.contains(line.lowercased())
        }

        // Price: the first line that is one. Free is spelled both ways across
        // surfaces, hence the case-insensitive compare the label path also uses.
        var priceText: String?
        if let index = lines.firstIndex(where: { isPrice($0) }) {
            priceText = lines[index]
            lines.remove(at: index)
        }

        // A was-price sits immediately after the price and is also a price. Take
        // it only if one was already found, so a lone "$70" stays the price.
        var originalPriceText: String?
        if priceText != nil, let index = lines.firstIndex(where: { isPrice($0) }) {
            originalPriceText = lines[index]
            lines.remove(at: index)
        }

        // …but on a marked-down card the two aren't separate lines at all: the
        // struck-through original is an inline span, so `innerText` hands over
        // "$50$60" as one run and the loop above finds no second price to take.
        (priceText, originalPriceText) = PriceRun.resolve(price: priceText, original: originalPriceText)

        // A place is only removed when another line remains for the title;
        // titles routinely contain commas too.
        var locationText: String?
        if lines.count >= 2, let index = lines.lastIndex(where: { isPlace($0) }) {
            locationText = lines[index]
            lines.remove(at: index)
        }

        // Whatever is left, longest first: badges ("Price drop", "Just listed")
        // are short and the title is the substantial line.
        guard let title = lines.max(by: { $0.count < $1.count }), title.count > 2 else { return nil }

        let thumbnail = raw.imageURL.isEmpty ? nil : URL(string: raw.imageURL)
        return Listing(
            id: thumbnail.flatMap(Listing.photoFBID).map { "p:\($0)" } ?? "fb:\(raw.id)",
            title: title,
            priceText: priceText,
            originalPriceText: originalPriceText,
            locationText: locationText,
            conditionText: nil,
            thumbnailURL: thumbnail,
            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(raw.id)/"),
            // No empty-city signal on this route — a shipping listing simply has
            // no place line, which is also what a card mid-render looks like. So
            // this route never claims `Ships`, rather than guessing.
            badgeText: nil,
            cardIndex: cardIndex,
            detail: nil,
            capturedAt: Date()
        )
    }

    private static func isPrice(_ line: String) -> Bool {
        PriceRun.isPrice(line)
    }

    /// A rendered place has at least a city and a region or country.
    private static func isPlace(_ line: String) -> Bool {
        let parts = line.components(separatedBy: ",")
        guard parts.count >= 2, let suffix = parts.last?.trimmingCharacters(in: .whitespaces),
              !suffix.isEmpty, suffix.count <= 32 else { return false }
        return suffix.allSatisfy { $0.isLetter || $0.isWhitespace }
    }

    static func parseLabel(_ raw: DesktopRawCard, cardIndex: Int) -> Listing? {
        var segments = raw.label
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard segments.count >= 2 else { return nil }

        // Trailing "listing <id>" — present on every real card, and its absence
        // means this anchor is something else entirely.
        guard let last = segments.last, last.hasPrefix("listing ") else { return nil }
        segments.removeLast()

        let shipsOnly = segments.last?.isEmpty == true
        if shipsOnly { segments.removeLast() }

        var locationText: String?
        var originalPriceText: String?
        var priceText: String?
        var titleSegments = segments

        // Price is the boundary between the comma-bearing title and whatever
        // geography this market renders. Unlike a North American state suffix,
        // that boundary survives "London, United Kingdom" and "Dublin, Ireland".
        if let priceIndex = segments.lastIndex(where: PriceRun.isPrice) {
            priceText = segments[priceIndex]
            titleSegments = Array(segments[..<priceIndex])
            var trailing = Array(segments[segments.index(after: priceIndex)...])
            if let first = trailing.first,
               first.lowercased().hasPrefix("reduced from ") {
                let candidate = String(first.dropFirst("reduced from ".count))
                if PriceRun.isPrice(candidate) {
                    originalPriceText = candidate
                    trailing.removeFirst()
                }
            }
            if !trailing.isEmpty {
                locationText = trailing.joined(separator: ", ")
            }
        } else if let last = segments.last {
            locationText = last
            titleSegments.removeLast()
        }

        // The label normally spells a markdown out ("reduced from $70") and is
        // handled above, but it is built from the same rendered text, so the
        // run-together form can reach here too.
        (priceText, originalPriceText) = PriceRun.resolve(price: priceText, original: originalPriceText)

        // Whatever is left is the title, commas and all.
        let title = titleSegments.joined(separator: ", ")
        guard !title.isEmpty else { return nil }

        let thumbnail = raw.imageURL.isEmpty ? nil : URL(string: raw.imageURL)

        return Listing(
            // Photo identity where possible, so a desktop card and a mobile
            // card for the same listing collide rather than duplicating
            // (docs/surface-strategy.md §5a). Falls back to the listing id,
            // which desktop always has and mobile never does.
            id: thumbnail.flatMap(Listing.photoFBID).map { "p:\($0)" } ?? "fb:\(raw.id)",
            title: title,
            priceText: priceText,
            originalPriceText: originalPriceText,
            locationText: locationText,
            conditionText: nil,
            thumbnailURL: thumbnail,
            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(raw.id)/"),
            badgeText: shipsOnly ? "Ships" : nil,
            cardIndex: cardIndex,
            detail: nil,
            capturedAt: Date()
        )
    }
}
