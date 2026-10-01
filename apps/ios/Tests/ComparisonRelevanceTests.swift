import XCTest
import OpenMarketProtos
@testable import OpenMarket

final class ComparisonRelevanceTests: XCTestCase {
    func testRejectedAndUncheckedPricesCannotAffectEstimateOrCurrency() {
        let comps = [comp("match", price: "$100", relevance: .included),
                     comp("accessory", price: "CA$10", relevance: .excluded),
                     comp("other", price: "CA$900", relevance: .excluded),
                     comp("unchecked", price: "CA$2000", relevance: .unchecked)]
        let guide = PriceGuide(comps: comps)
        XCTAssertEqual(guide.median, 100)
        XCTAssertEqual(guide.lowest, 100)
        XCTAssertEqual(guide.highest, 100)
        XCTAssertEqual(guide.currency, "$")
        XCTAssertEqual(guide.count, 1)
        XCTAssertEqual(guide.skipped, 3)
    }

    func testAllRejectedStillAppearWithoutPriceOrSoldClaims() {
        let rejected = comp("wrong item", price: "$500", relevance: .excluded, days: 1)
        let check = MarketCheck(term: "desk", price: 100, comps: [rejected],
                                sold: SoldSignal(comps: [rejected]), marketName: "Test")
        XCTAssertNil(check.standing)
        XCTAssertEqual(check.comps.count, 1)
        XCTAssertEqual(check.sold.comps.count, 1)
        XCTAssertTrue(check.sold.isEmpty)
        XCTAssertNil(check.sold.medianDaysToSell)
        XCTAssertNil(check.sold.speed)
        XCTAssertTrue(check.sold.guide.isEmpty)
    }

    func testSoldStatisticsAndStableCarouselOrdering() {
        let comps = [comp("rejected1", price: "$1000", relevance: .excluded, days: 1),
                     comp("accepted1", price: "$100", relevance: .included, days: 10),
                     comp("rejected2", price: "$2000", relevance: .excluded, days: 2),
                     comp("accepted2", price: "$200", relevance: .included, days: 20)]
        XCTAssertEqual(MarketComp.comparableFirst(comps).map(\.id),
                       ["accepted1", "accepted2", "rejected1", "rejected2"])
        let sold = SoldSignal(comps: comps)
        XCTAssertEqual(sold.count, 2)
        XCTAssertEqual(sold.guide.median, 150)
        XCTAssertEqual(sold.medianDaysToSell, 15)
        XCTAssertNil(sold.speed)
        XCTAssertEqual(sold.comps.map(\.id), ["accepted1", "accepted2", "rejected1", "rejected2"])
    }

    func testResponsesMapByIDAndMissingTitlesAreExcluded() throws {
        var missingTitle = comp("untitled", price: "$300", relevance: .unchecked)
        missingTitle.listing.title = nil
        let comps = [comp("a", price: "$100", relevance: .unchecked), missingTitle,
                     comp("b", price: "$200", relevance: .unchecked)]
        let candidates = ComparisonRelevance.candidates(from: comps)
        XCTAssertEqual(candidates.map(\.id), ["0", "2"])
        let evaluated = try ComparisonRelevance.apply([decision("2", include: false), decision("0", include: true)],
                                                      to: comps, candidates: candidates)
        XCTAssertEqual(evaluated.map(\.relevance), [.included, .excluded, .excluded])
    }

    func testIncompleteDuplicateAndInvalidResponsesFailClosed() {
        let comps = [comp("a", price: "$100", relevance: .unchecked),
                     comp("b", price: "$200", relevance: .unchecked)]
        let candidates = ComparisonRelevance.candidates(from: comps)
        var invalid = decision("1", include: true)
        invalid.probability = .nan
        for decisions in [[decision("0", include: true)],
                          [decision("0", include: true), decision("0", include: true)],
                          [decision("0", include: true), decision("unexpected", include: true)],
                          [decision("0", include: true), invalid]] {
            XCTAssertThrowsError(try ComparisonRelevance.apply(decisions, to: comps, candidates: candidates))
        }
    }

    func testTargetIncludesLoadedDescriptionAndCondition() {
        var listing = comp("target", price: "$100", relevance: .unchecked).listing
        listing.detail = ListingDetail(description: "Disc edition, controller included", conditionText: "Used - Good")
        let target = ComparisonRelevance.item(for: listing)
        XCTAssertEqual(target.description_p, "Disc edition, controller included")
        XCTAssertEqual(target.condition, "Used - Good")
    }

    private func decision(_ id: String, include: Bool) -> ComparableDecision {
        var decision = ComparableDecision()
        decision.id = id
        decision.useInComparison = include
        decision.probability = include ? 0.95 : 0.1
        return decision
    }

    private func comp(_ id: String, price: String, relevance: MarketComp.Relevance, days: Int? = nil) -> MarketComp {
        var comp = MarketComp(listing: Listing(id: id, title: id, priceText: price, cardIndex: 0, capturedAt: Date()))
        comp.relevance = relevance
        if let days {
            comp.isSold = true
            comp.postedAt = Date().addingTimeInterval(-Double(days) * 86_400)
        }
        return comp
    }
}
