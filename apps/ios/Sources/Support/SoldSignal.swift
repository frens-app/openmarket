import Foundation

/// What recently sold nearby, and how fast.
///
/// The second half of the seller's question. "What are similar things listed
/// for" tells you what you are competing with; this tells you what actually
/// moved, which is the only evidence available that a price is achievable
/// rather than merely asked.
///
/// **Three limits, all measured, all load-bearing.**
///
/// *It is still an asking price.* Facebook publishes what a sold listing was
/// listed at, never what changed hands. An accepted offer below the asking
/// price is invisible, so every number here is an upper bound on what the buyer
/// paid. That is a real step up from the active board — these are prices at
/// which somebody actually said yes — but it is not a sale price and nothing
/// here should imply it is.
///
/// *"Recently" is inferred, not published.* `creation_time` is the only time
/// field on a listing (verified 2026-08-07: no sale, close, or update
/// timestamp exists anywhere in the payload for a sold card). So the age of a
/// sold listing bounds how long it took to sell — listed then, gone now — and
/// nothing narrows it further. A dresser listed three days ago and now sold
/// took **at most** three days; it may have gone in an hour.
///
/// *The sample is small and one-sided.* The result cap is ~15 before pending
/// and free items come out, so a typical set is five to eleven. And it is
/// filtered on having sold, which is a survivor's list: the things that didn't
/// sell are exactly the ones missing, so nothing here can tell a seller a price
/// is *too high* — only that certain prices worked.
struct SoldSignal: Equatable {
    /// Sold comparables, newest listing first.
    let comps: [MarketComp]
    /// Prices of the sold ones, free items excluded.
    let guide: PriceGuide

    init(comps: [MarketComp]) {
        self.comps = comps.sorted { ($0.daysListed ?? .max) < ($1.daysListed ?? .max) }
        guide = PriceGuide(comps: comps, countingSold: true)
    }

    var isEmpty: Bool { comps.isEmpty }
    var count: Int { comps.count }

    /// Typical days between listing and disappearing, across the sold set.
    ///
    /// The median rather than the mean: one item that sat for 26 days among
    /// nine that went in under three would drag an average into describing
    /// nothing that happened.
    var medianDaysToSell: Int? {
        let ages = comps.compactMap(\.daysListed).sorted()
        guard !ages.isEmpty else { return nil }
        let middle = ages.count / 2
        return ages.count.isMultiple(of: 2) ? (ages[middle - 1] + ages[middle]) / 2 : ages[middle]
    }

    /// One line for the transcript. Leads with the speed, because that is the
    /// part the active board cannot tell you at all.
    var summary: String {
        guard !comps.isEmpty else { return "Nothing similar has sold nearby lately" }
        let sold = "\(count) sold in the last month"
        guard let days = medianDaysToSell else { return sold }
        return days <= 1
            ? "\(sold), most within a day of listing"
            : "\(sold), typically within \(days) days of listing"
    }

    /// How fast things like this go, in words rather than a number of days.
    ///
    /// "About two weeks" and "13 days" are the same fact, and only one of them
    /// is a decision somebody can act on — thirteen is a median of a handful of
    /// samples, and rendering it exactly claims a precision the sample does not
    /// have. The buckets are wide for the same reason.
    ///
    /// Nil below three sold listings: "sells within a day" off a sample of one
    /// is not a pattern, it is a coincidence with a confident voice.
    var speed: String? {
        guard comps.count >= 3, let days = medianDaysToSell else { return nil }
        switch days {
        case ..<2: return "Similar ones usually sell within a day."
        case 2...4: return "Similar ones usually sell in a few days."
        case 5...10: return "Similar ones usually sell in about a week."
        case 11...18: return "Similar ones usually sell in about two weeks."
        case 19...45: return "Similar ones usually take a few weeks to sell."
        default: return "Similar ones can take a month or more to sell."
        }
    }

    /// How this reads under the price, when there is enough of it to say
    /// anything. Kept vague about precision on purpose — with a handful of
    /// samples, a band is a suggestion and a point estimate would be a lie.
    var priceNote: String? {
        guard guide.count >= 3, let low = guide.lowest, let high = guide.highest else { return nil }
        let range = low == high ? guide.money(low) : "\(guide.money(low))–\(guide.money(high))"
        return "\(guide.count) that sold were listed at \(range)."
    }

    /// The whole "why this price" line: where it sits on the active board, then
    /// what sold. Both halves are arithmetic, so both are written here rather
    /// than by the model.
    func rationale(for price: Int, against guide: PriceGuide) -> String {
        [guide.explanation(for: price), priceNote]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}
