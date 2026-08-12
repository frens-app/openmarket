import Foundation

/// What comparable listings are asking, reduced to numbers.
///
/// Computed in Swift and handed to the model rather than left for it to work
/// out. Language models are poor at arithmetic and excellent at prose, so the
/// split is deliberate: this file decides *what the market looks like* and the
/// model only decides where inside it to sit and how to say so. It is also the
/// fallback — with no model on the device there is still a median, which is a
/// defensible recommendation on its own.
///
/// **These are asking prices, not sale prices.** Facebook exposes what sellers
/// want, never what buyers paid, and nothing here can close that gap. Every
/// surface that shows these numbers says so.
struct PriceGuide: Equatable {
    /// Usable asking prices, ascending.
    let prices: [Int]
    /// Comparables that carried no price we could read, or none worth counting
    /// — free items and sold cards. Reported rather than silently dropped: a
    /// guide built from four of fifteen listings is a different claim from one
    /// built from all fifteen.
    let skipped: Int

    /// What the market quotes in, taken from the cards themselves.
    ///
    /// Not cosmetic. Facebook prices in the currency of the place being
    /// browsed, so a Toronto search comes back as "CA$80" — and a
    /// recommendation rendered as "$80" beside a strip of CA$ comparables is
    /// quietly wrong by about a third. Nothing here converts anything; the
    /// arithmetic is done on the numbers as listed, and this just makes sure
    /// the answer is labelled the same way the evidence is.
    let currency: String

    var count: Int { prices.count }
    var isEmpty: Bool { prices.isEmpty }

    var lowest: Int? { prices.first }
    var highest: Int? { prices.last }

    /// Proper median — the mean of the middle pair on an even count — because
    /// this is the number shown to the user when there is no model to reason
    /// about it, and "the 8th of 14" is not the middle of anything.
    var median: Int? {
        guard !prices.isEmpty else { return nil }
        let middle = prices.count / 2
        if prices.count.isMultiple(of: 2) {
            return (prices[middle - 1] + prices[middle]) / 2
        }
        return prices[middle]
    }

    /// Nearest-rank quartiles. Crude, and right for a sample this small: with
    /// twelve numbers, interpolating between them invents precision the sample
    /// doesn't have.
    var lowerQuartile: Int? { percentile(0.25) }
    var upperQuartile: Int? { percentile(0.75) }

    private func percentile(_ p: Double) -> Int? {
        guard !prices.isEmpty else { return nil }
        let rank = max(1, min(prices.count, Int((p * Double(prices.count)).rounded(.up))))
        return prices[rank - 1]
    }

    /// The band a price should normally land in. Nil below four samples, where
    /// quartiles of three numbers are just the three numbers.
    var typicalRange: ClosedRange<Int>? {
        guard prices.count >= 4, let low = lowerQuartile, let high = upperQuartile,
              low <= high else { return nil }
        return low...high
    }

    /// Built from whatever the market search returned.
    ///
    /// **Free and $0 listings are always excluded.** A giveaway is not a data
    /// point about what a thing is worth, and one of them in a sample of eight
    /// moves the median a long way. This matters far more on the sold side than
    /// it looks: of twelve recently-sold couches in San Francisco, **seven were
    /// free**. Free things sell, so they are wildly over-represented in
    /// anything filtered on having sold. (Category-dependent — only one of
    /// eleven sold dressers was free — which is exactly why it has to be
    /// handled rather than eyeballed.)
    ///
    /// - Parameter countingSold: whether sold cards count. False for a guide
    ///   about what the seller is *competing with*, where a listing that
    ///   stopped being one isn't competition. True for a guide about what
    ///   actually moved, where they are the entire point.
    init(comps: [MarketComp], countingSold: Bool = false) {
        var usable: [Int] = []
        var dropped = 0
        for comp in comps {
            guard countingSold || !comp.isSold, let price = comp.price, price > 0 else {
                dropped += 1
                continue
            }
            usable.append(price)
        }
        prices = usable.sorted()
        skipped = dropped
        currency = Self.dominantCurrency(among: comps) ?? "$"
    }

    /// A price written the way the comparables are written.
    func money(_ amount: Int) -> String { "\(currency)\(amount)" }

    /// Holds a recommendation inside the evidence that produced it.
    ///
    /// The model is told to stay in the interquartile band and mostly does, but
    /// it is a 3-billion-parameter model doing a judgement call, and across
    /// repeated runs on identical input it returned 100, 110 and 140 for the
    /// same dresser. The band is guidance, this is a floor and a ceiling: a
    /// recommendation outside the *observed* prices isn't a bolder opinion
    /// about the market, it's a number with nothing behind it.
    ///
    /// Deliberately the full range rather than the quartiles — an item that
    /// genuinely is the best one listed should be allowed to ask what the best
    /// one listed is asking.
    func clamped(_ price: Int) -> Int {
        guard let lowest, let highest else { return price }
        return min(max(price, lowest), highest)
    }

    /// Where a price sits, in one short phrase.
    ///
    /// The short form exists because the numbers moved. `explanation(for:)`
    /// below spells out the lowest, the median, the middle half and the count,
    /// which was right when prose was the only way to say them — the screen now
    /// draws them as a bar with its own labels, and repeating them underneath in
    /// a sentence is the same data twice.
    ///
    /// What a bar cannot say is what the position *means*, which is this.
    func position(for price: Int) -> String? {
        guard let median, count > 0 else { return nil }
        let asks = "\(count) nearby ask\(count == 1 ? "" : "s")"

        if let range = typicalRange, price >= range.lowerBound, price <= range.upperBound {
            return price == median
                ? "Right in the middle of \(asks)."
                : "In the range most of \(asks) sit in."
        }
        if price > median {
            return "Above most of \(asks)."
        }
        return "Below most of \(asks)."
    }

    /// Why this price, in numbers that are true by construction.
    ///
    /// Written here rather than by the model, and that is a correctness fix
    /// rather than a preference. Asked to justify its own figure, the model
    /// produced "you are asking CA$20 more than the median price of CA$80"
    /// against a measured median of CA$77 — a confident sentence, wrong in both
    /// numbers. Arithmetic about the sample belongs to whoever computed the
    /// sample.
    func explanation(for price: Int) -> String {
        guard let median, let lowest, let highest, count > 0 else {
            return "Nothing comparable nearby had a price to go on."
        }
        var sentences = [
            "\(count) nearby asking price\(count == 1 ? "" : "s"), \(money(lowest)) to \(money(highest)), with a median of \(money(median))."
        ]
        if let range = typicalRange {
            sentences.append("The middle half sits between \(money(range.lowerBound)) and \(money(range.upperBound)).")
        }
        if price > median {
            sentences.append("This asks above the middle of them.")
        } else if price < median {
            sentences.append("This asks below the middle of them.")
        } else {
            sentences.append("This is the middle of them.")
        }
        return sentences.joined(separator: " ")
    }

    /// The symbol most of the cards used.
    ///
    /// A vote rather than a read of the first card: one oddly-formatted price
    /// among fifteen shouldn't relabel the whole guide.
    static func dominantCurrency(among comps: [MarketComp]) -> String? {
        var counts: [String: Int] = [:]
        for comp in comps {
            guard let symbol = currencySymbol(in: comp.listing.priceText) else { continue }
            counts[symbol, default: 0] += 1
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Whatever sits in front of the number — `$`, `CA$`, `£`, `€`.
    ///
    /// Requires a digit immediately after it, which is what keeps "Free" from
    /// being read as a four-character currency symbol.
    static func currencySymbol(in text: String?) -> String? {
        guard let text else { return nil }
        let symbol = text.prefix { !$0.isNumber && !$0.isWhitespace }
        guard !symbol.isEmpty, symbol.count <= 4,
              text.dropFirst(symbol.count).first?.isNumber == true else { return nil }
        return String(symbol)
    }

    /// Reads a price out of the text Facebook renders on a card.
    ///
    /// The formatted string is parsed rather than the payload's numeric
    /// `listing_price.amount`, deliberately. That field's unit is unverified —
    /// Facebook's price objects carry both a major-unit `amount` and a
    /// minor-unit `amount_with_offset`, and we have never confirmed which one
    /// this extractor is reading. A hundredfold error in a price
    /// recommendation is the worst bug this feature could have, and the
    /// displayed text has no such ambiguity: it is what the user is looking at
    /// on the card beside it.
    ///
    /// It is also the only price the markup fallback has, so parsing it keeps
    /// one code path instead of two.
    static func parse(_ text: String?) -> Int? {
        guard let text else { return nil }
        if text.localizedCaseInsensitiveContains("free") { return 0 }
        // First run of digits, with thousands separators folded in. Ranges
        // ("$20 - $40") therefore take the lower bound, which is the one a
        // buyer is comparing against.
        var digits = ""
        var started = false
        for character in text {
            if character.isNumber {
                digits.append(character)
                started = true
            } else if character == "," && started {
                continue
            } else if started {
                break
            }
        }
        return Int(digits)
    }
}
