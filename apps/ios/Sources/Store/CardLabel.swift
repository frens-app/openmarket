import Foundation

/// Parses a WebLite card's `aria-label`.
///
/// Search cards label themselves with much more than they render:
///
///     Desk for sale - Used - Good - $75 in Oakland, CA
///     Free Computer desk for sale - Used - Like New in El Sobrante, CA
///
/// The label is the only place the *untruncated* title, the condition, and —
/// on one of the two search layouts — the city appear at all.
///
/// The format is dash-separated and a seller may well put a dash in their own
/// title ("IKEA MALM - white desk"), so splitting on "-" is not safe. Three
/// things make it parseable anyway:
///
///   • ` for sale ` and ` in ` are fixed separators the seller can't forge into
///     the wrong position, and the pattern is anchored at both ends;
///   • the condition comes from a closed vocabulary, so it's matched
///     *literally* — "Used - Like New" is one token, not two fields and a
///     delimiter;
///   • the title is captured greedily, so it absorbs any dashes the seller
///     wrote, and even a second "for sale", by binding to the last occurrence.
///
/// A label whose condition we don't recognise still yields its title and city
/// through `loosePattern`, because losing the city to an unfamiliar vocabulary
/// word would be a bad trade.
enum CardLabel {

    struct Parsed: Equatable {
        var title: String?
        var conditionText: String?
        var priceText: String?
        var locationText: String?
    }

    /// Facebook's vocabulary as observed. Ordered longest-first so that
    /// "Used - Like New" is preferred over the "New" nested inside it.
    static let conditions = [
        "Used - Like New",
        "Used - Good",
        "Used - Fair",
        "Refurbished",
        "New",
    ]

    static func parse(_ label: String) -> Parsed? {
        let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Facebook Logo" and other chrome labels never reach the parser.
        guard text.count > 12,
              text.range(of: " for sale", options: .caseInsensitive) != nil else { return nil }

        if let g = match(text, pricedPattern), g.count == 6 {
            return Parsed(title: trimmed(g[1]),
                          conditionText: canonicalCondition(g[2]),
                          priceText: trimmed(g[3]),
                          locationText: place(g[4], g[5]))
        }
        // Free listings prefix "Free " to the title and omit the price segment
        // entirely. Tried second so "Free weights for sale - … - $50 in …"
        // keeps "Free weights" as its title rather than losing the first word.
        if let g = match(text, freePattern), g.count == 5 {
            return Parsed(title: trimmed(g[1]),
                          conditionText: canonicalCondition(g[2]),
                          priceText: "Free",
                          locationText: place(g[3], g[4]))
        }
        if let g = match(text, loosePattern), g.count == 4 {
            return Parsed(title: trimmed(g[1]),
                          conditionText: nil,
                          priceText: nil,
                          locationText: place(g[2], g[3]))
        }
        return nil
    }

    // MARK: - Patterns

    /// En and em dashes both appear in Facebook's own copy.
    private static let dash = "\\s*[-\u{2013}\u{2014}]\\s*"

    private static var conditionAlternation: String {
        conditions
            .map { $0.replacingOccurrences(of: " - ", with: dash) }
            .joined(separator: "|")
    }

    private static let tail = "\\s+in\\s+([^,]{1,60}),\\s*([A-Za-z]{2})\\s*$"

    private static var pricePrefixAlternation: String {
        MarketRegion.supportedPricePrefixes
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
    }

    private static var pricedPattern: String {
        "^(.*) for sale\(dash)(\(conditionAlternation))\(dash)((?:\(pricePrefixAlternation))[\\d,]+(?:\\.\\d{2})?)\(tail)"
    }

    private static var freePattern: String {
        "^Free\\s+(.*) for sale\(dash)(\(conditionAlternation))\(tail)"
    }

    /// Condition unrecognised — still recover the title and the city, both of
    /// which are anchored on separators rather than on vocabulary.
    private static var loosePattern: String {
        "^(?:Free\\s+)?(.*) for sale\\b.*?\(tail)"
    }

    // MARK: - Helpers

    private static func match(_ text: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let full = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: full) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// The matched text is from the closed set by construction, but may carry a
    /// different dash or spacing than our spelling.
    private static func canonicalCondition(_ raw: String) -> String? {
        let normalized = raw
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return conditions.first { $0.caseInsensitiveCompare(normalized) == .orderedSame } ?? normalized
    }

    private static func place(_ city: String, _ region: String) -> String? {
        let c = trimmed(city), r = trimmed(region)
        guard let c, let r else { return nil }
        return "\(c), \(r.uppercased())"
    }

    private static func trimmed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
