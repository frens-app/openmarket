import Foundation

/// What the market says about one listing's asking price.
///
/// The buyer's half of the seller tab's question. Same two searches — what is
/// listed nearby, what has recently sold — and the same arithmetic, pointed at a
/// price somebody else set instead of one being chosen.
///
/// **Nothing here is a verdict on the listing.** It reports where the price sits
/// among comparable asks and what sold at what, and stops: an item genuinely
/// better than everything else listed should be asking more than all of them,
/// and this cannot see condition, age or completeness. Same stance as
/// `PriceRangeBar`, which is why nothing on this screen turns red.
struct MarketCheck: Equatable {
    /// Where the price falls against the comparable asks.
    enum Standing: Equatable { case below, around, above }

    /// What was searched — shown, because a comparison is only as good as the
    /// set behind it and the user is the one who can tell whether it was sane.
    let term: String
    /// The listing's own price, as parsed from what Facebook drew on the card.
    let price: Int
    /// Active listings nearby, this one removed.
    let comps: [MarketComp]
    let sold: SoldSignal
    let guide: PriceGuide
    let marketName: String

    init(term: String, price: Int, comps: [MarketComp], sold: SoldSignal, marketName: String) {
        self.term = term
        self.price = price
        self.comps = comps
        self.sold = sold
        self.marketName = marketName
        guide = PriceGuide(comps: comps)
    }

    /// Quartiles where the sample supports them, the median where it doesn't.
    /// Nil when nothing comparable carried a price, which is a real outcome and
    /// not a failure.
    var standing: Standing? {
        guard let median = guide.median else { return nil }
        if let band = guide.typicalRange {
            if price < band.lowerBound { return .below }
            if price > band.upperBound { return .above }
            return .around
        }
        if price < median { return .below }
        if price > median { return .above }
        return .around
    }

    /// The answer, in the words the evidence supports. Descriptive on purpose —
    /// "cheap" and "overpriced" are conclusions about an object this never saw.
    var headline: String {
        switch standing {
        case .below: "Less than most nearby"
        case .around: "About what others are asking"
        case .above: "More than most nearby"
        case nil: "Nothing nearby to compare it against"
        }
    }

    var symbol: String {
        switch standing {
        case .below: "arrow.down"
        case .around: "equal"
        case .above: "arrow.up"
        case nil: "questionmark"
        }
    }

    /// Where it sits, in one phrase — `PriceGuide` already writes this, and it
    /// is the same sentence the seller tab shows about its own recommendation.
    var position: String? { guide.position(for: price) }

    /// What sold, when there is enough of it to say anything. Both halves are
    /// nil below three samples; a speed read off one listing is a coincidence
    /// with a confident voice (`SoldSignal.speed`).
    var soldLine: String? {
        let parts = [sold.priceNote, sold.speed].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Where one listing's check has got to.
enum MarketCheckPhase: Equatable {
    /// Carries what it is doing, because the two searches take a few seconds
    /// each and "checking" for eight of them reads as stuck.
    case running(String)
    case done(MarketCheck)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var result: MarketCheck? {
        if case .done(let check) = self { return check }
        return nil
    }
}
