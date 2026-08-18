import Foundation

/// Splits a price run that arrived as one string but means two prices.
///
/// A marked-down card renders its new price and its struck-through old one as
/// *inline* spans inside the same block, so `innerText` joins them with no
/// separator at all and the card's price line comes back as a single run:
///
///     $50$60          <- $50 now, was $60
///     $250$1,000
///     $0$25
///
/// Every parse route then read the whole thing as the price, because each one
/// tests a run with something like `hasPrefix("$")` — which "$50$60" satisfies.
/// The card drew "$50$60" in one bold string, with no strikethrough and no
/// second price, and so did the detail screen under it. Observed on the browse
/// feed signed in, 2026-08-09.
///
/// This is deliberately the only place that knows the shape, because three
/// routes produce listings — the desktop label, the desktop line text, and the
/// mobile runs — and only the JSON payload route (`DesktopPayload`) gets a
/// separate `strikethroughFormatted` field for free.
enum PriceRun {
    static func isPrice(_ text: String) -> Bool {
        text.caseInsensitiveCompare("free") == .orderedSame
            || currencySymbol(in: text) != nil
    }

    private static func currencySymbol(in text: String) -> String? {
        guard let symbol = PriceGuide.currencySymbol(in: text),
              MarketRegion.supportedPricePrefixes.contains(where: {
                  $0.caseInsensitiveCompare(symbol) == .orderedSame
              }) else { return nil }
        return symbol
    }

    /// `("$50", "$60")` for `"$50$60"`, and nil for anything that isn't exactly
    /// two amounts back to back.
    ///
    /// Strict on purpose. A run only splits when it is *nothing but* two
    /// amounts, optionally separated by whitespace — so a range ("$20 - $40"),
    /// a single price, "Free", and anything carrying a word are all left
    /// exactly as they are. Inventing a "was" price that Facebook never showed
    /// is a worse failure than leaving a rare odd string unsplit: it would
    /// claim a discount on a listing that has none.
    static func split(_ text: String) -> (current: String, original: String)? {
        var parts: [String] = []
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            // `currencySymbol` accepts both one-character symbols and the
            // country-qualified forms Facebook uses outside the US, such as
            // `CA$`. Anything else keeps ranges and prose out.
            let remainder = String(text[index...])
            guard let symbol = currencySymbol(in: remainder) else { return nil }

            var end = text.index(index, offsetBy: symbol.count)
            while end < text.endIndex, text[end].isNumber || text[end] == "," || text[end] == "." {
                end = text.index(after: end)
            }

            parts.append(String(text[index..<end]))
            guard parts.count <= 2 else { return nil }
            index = end
        }

        guard parts.count == 2 else { return nil }

        // Order is the claim being made — Facebook draws the price you'd pay
        // first and the struck-through old one second — and the amounts have to
        // agree with it. A pair that doesn't ascend isn't a markdown, so it's
        // left alone rather than relabelled into one.
        guard let current = amount(in: parts[0]),
              let original = amount(in: parts[1]),
              original > current else { return nil }

        return (parts[0], parts[1])
    }

    private static func amount(in text: String) -> Decimal? {
        guard let symbol = currencySymbol(in: text) else { return nil }
        return Decimal(string: text.dropFirst(symbol.count).replacingOccurrences(of: ",", with: ""))
    }

    /// Applies `split` to a price that may or may not need it.
    ///
    /// Returns the price unchanged and the original untouched when there's
    /// nothing to split, so call sites don't each repeat the nil dance. An
    /// original that was already found elsewhere — desktop's "reduced from"
    /// segment, or a second price line — always wins: it came from a field
    /// Facebook labelled, where this is inferred from a string's shape.
    static func resolve(price: String?, original: String?) -> (price: String?, original: String?) {
        guard original == nil, let price, let pair = split(price) else { return (price, original) }
        return (pair.current, pair.original)
    }
}
