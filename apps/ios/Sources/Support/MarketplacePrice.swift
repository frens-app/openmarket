import Foundation

/// Parses source prices independently of the phone's locale. A response can
/// contain English grouping even when the selected market uses decimal commas.
struct MarketplacePrice {
    let amount: Decimal
    let symbol: String

    private static let symbols = Array(Set(MarketCurrency.all.flatMap(\.symbols)))
        .sorted { $0.count == $1.count ? $0 < $1 : $0.count > $1.count }
    private static let symbolPattern = symbols.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    private static let numberPattern = #"\p{Nd}+(?:[.,٬٫\s]\p{Nd}+)*(?:[KMB](?!\p{L}))?"#
    private static let pattern = "(?:((?:\(symbolPattern)))\\s*(\(numberPattern))|(\(numberPattern))\\s*((?:\(symbolPattern))))"
    private static let expression = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    private static let directionalMarks = CharacterSet(charactersIn: "\u{061c}\u{200e}\u{200f}\u{202a}\u{202b}\u{202c}\u{2066}\u{2067}\u{2068}\u{2069}")

    static func isFree(_ text: String) -> Bool {
        ["free", "gratuit", "gratuito", "gratis", "kostenlos", "grátis", "मुफ़्त", "বিনামূল্যে", "مجانا", "مجانًا", "ฟรี", "miễn phí", "ücretsiz"]
            .contains(clean(text).lowercased())
    }

    static func canonicalAmount(_ text: String?) -> String? {
        guard let text, text.range(of: #"\A(0|[1-9][0-9]{0,17})(\.[0-9]{1,2})?\z"#,
                                   options: .regularExpression) != nil else { return nil }
        return text
    }

    static func exactAmount(_ text: String?) -> String? {
        guard let text else { return nil }
        if isFree(text) { return "0" }
        guard let value = single(clean(text)) else { return nil }
        return canonicalAmount(NSDecimalNumber(decimal: value.amount).stringValue)
    }

    static func parse(_ text: String?) -> MarketplacePrice? {
        guard let source = text else { return nil }
        if isFree(source) { return MarketplacePrice(amount: 0, symbol: "") }
        let text = clean(source)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let match = matches.first, match.range.location == 0,
              let range = Range(match.range, in: text),
              let price = value(match, in: text) else { return nil }
        let remainder = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if remainder.isEmpty { return price }
        // A range is comparable at its lower endpoint; joined prices are only
        // accepted when they form a verified discount pair.
        if ["-", "–", "—"].contains(remainder.first.map(String.init) ?? "") {
            let upper = String(remainder.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let end = single(upper), end.symbol.caseInsensitiveCompare(price.symbol) == .orderedSame,
               end.amount >= price.amount { return price }
        }
        return split(text).flatMap { single($0.current) }
    }

    static func split(_ text: String) -> (current: String, original: String)? {
        let text = clean(text)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard matches.count == 2, let second = Range(matches[1].range, in: text) else { return nil }
        // Validate both complete halves so compact prices such as IDR550MIDR600M
        // retain the multiplier immediately before the next currency marker.
        let currentText = String(text[..<second.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let originalText = String(text[second.lowerBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = single(currentText), let original = single(originalText),
              current.symbol.caseInsensitiveCompare(original.symbol) == .orderedSame,
              original.amount > current.amount else { return nil }
        return (currentText, originalText)
    }

    static func display(_ text: String?) -> String? {
        guard let text else { return nil }
        let source = clean(text)
        guard parse(source) != nil else { return text }
        var display = source
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let symbolRange = match.range(at: match.range(at: 1).location != NSNotFound ? 1 : 4)
            guard let range = Range(symbolRange, in: display) else { continue }
            display.replaceSubrange(range, with: MarketCurrency.localSymbol(for: String(display[range])))
        }
        return display
    }

    private static func single(_ text: String) -> MarketplacePrice? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: range), match.range == range else { return nil }
        return value(match, in: text)
    }

    private static func value(_ match: NSTextCheckingResult, in text: String) -> MarketplacePrice? {
        let prefix = match.range(at: 1).location != NSNotFound
        guard let symbol = Range(match.range(at: prefix ? 1 : 4), in: text),
              let number = Range(match.range(at: prefix ? 2 : 3), in: text),
              let amount = decimal(String(text[number])) else { return nil }
        return MarketplacePrice(amount: amount, symbol: String(text[symbol]))
    }

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: directionalMarks).joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decimal(_ text: String) -> Decimal? {
        var text = text
        let multipliers: [Character: Decimal] = ["K": 1_000, "M": 1_000_000, "B": 1_000_000_000]
        let multiplier = text.uppercased().last.flatMap { multipliers[$0] }
        if multiplier != nil { text.removeLast() }
        let normalized = text.map { character -> String in
            if let digit = character.wholeNumberValue { return String(digit) }
            if character == "٬" { return "," }
            if character == "٫" { return "." }
            return character.isWhitespace ? " " : String(character)
        }.joined()
        let separators = normalized.filter { $0 == "." || $0 == "," }
        var decimalSeparator: Character?
        if let last = normalized.lastIndex(where: { $0 == "." || $0 == "," }) {
            let fraction = normalized[normalized.index(after: last)...]
            if (1...2).contains(fraction.count), fraction.allSatisfy(\.isNumber) {
                decimalSeparator = normalized[last]
            } else if separators.contains(".") && separators.contains(",") {
                return nil
            }
        }
        let parts = decimalSeparator.map { normalized.split(separator: $0, omittingEmptySubsequences: false).map(String.init) } ?? [normalized]
        guard parts.count == (decimalSeparator == nil ? 1 : 2) else { return nil }
        let integer = parts[0]
        let groups = integer.split(whereSeparator: { !$0.isNumber })
        guard !groups.isEmpty, groups.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let grouping = integer.filter { !$0.isNumber }
        if !grouping.isEmpty {
            guard Set(grouping).count == 1, groups.count == grouping.count + 1 else { return nil }
            let western = (1...3).contains(groups[0].count) && groups.dropFirst().allSatisfy { $0.count == 3 }
            let indian = groups.count >= 3 && (1...2).contains(groups[0].count)
                && groups.last?.count == 3 && groups.dropFirst().dropLast().allSatisfy { $0.count == 2 }
            guard western || indian else { return nil }
        }
        let canonical = groups.joined() + (parts.count == 2 ? "." + parts[1] : "")
        guard canonical.filter(\.isNumber).count <= 18 else { return nil }
        guard let amount = Decimal(string: canonical, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return amount * (multiplier ?? 1)
    }
}
