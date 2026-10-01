import Foundation
import WebKit
import os

extension Logger {
    static let seller = Logger(subsystem: "lol.frens.openmarket", category: "seller")
}

/// One listing being used as evidence about price.
struct MarketComp: Identifiable, Equatable {
    enum Relevance: Equatable { case unchecked, included, excluded }
    var relevance: Relevance = .unchecked
    var relevanceProbability: Double?
    var isComparable: Bool { relevance == .included }

    static func comparableFirst(_ comps: [MarketComp]) -> [MarketComp] {
        comps.filter(\.isComparable) + comps.filter { !$0.isComparable }
    }

    var listing: Listing
    /// Whole dollars, parsed from the displayed price. Nil when the card had no
    /// readable price at all.
    var price: Int?
    /// Seller-marked, so it means "no longer for sale", not "sold for this".
    var isSold: Bool
    var postedAt: Date?

    var id: String { listing.id }

    /// How long this had been listed, as of now.
    ///
    /// On a **sold** card this is the useful one: it is an upper bound on how
    /// long the item took to sell, because it was listed then and is gone now.
    /// Facebook publishes no sale date — `creation_time` is the only time field
    /// on a listing, sold or not (verified 2026-08-07) — so this inference is
    /// the whole of what "recently sold" can mean here.
    var daysListed: Int? {
        guard let postedAt else { return nil }
        return max(0, Int(Date().timeIntervalSince(postedAt) / 86_400))
    }

    init(payload: PayloadListing, cardIndex: Int) {
        listing = payload.makeListing(cardIndex: cardIndex)
        price = PriceGuide.parse(payload.priceFormatted)
        isSold = payload.isSold == true
        postedAt = payload.postedAt

        // The numeric field is not used (see `PriceGuide.parse`), but a
        // disagreement with the text is worth knowing about, and this is the
        // one place both are in hand. Costs nothing and turns an assumption
        // about Facebook's units into a measurement the first time anyone
        // sells something.
        if let price, let amount = payload.price {
            let numeric = NSDecimalNumber(decimal: amount).intValue
            if numeric != price {
                Logger.seller.info("price fields disagree: formatted \(price, privacy: .public) vs amount \(numeric, privacy: .public)")
            }
        }
    }

    init(listing: Listing) {
        self.listing = listing
        price = PriceGuide.parse(listing.priceText)
        isSold = listing.badgeText?.lowercased() == "sold"
        postedAt = nil
    }
}

/// Runs the market search behind the seller tab.
///
/// **Its own engine, deliberately.** Sharing the browse tab's `DesktopFeedEngine`
/// would mean drafting a listing navigated the results the user was reading out
/// from under them — same webview, same DOM — and `loadMore` would then be
/// paging a search nobody asked for. A second engine costs one more idle
/// webview and keeps the two tabs independent.
///
/// It does *not* cost extra request budget: `RequestPacer` is a shared actor,
/// so this engine's loads count against the same session cap and obey the same
/// backoff as every other request the app makes.
///
/// **One page load per draft, and no item pages.** Comparables are read from
/// the search results only — title, price, photo, city. Opening fifteen item
/// pages to price a dresser is exactly the automation-shaped traffic the app
/// removed everywhere else (`docs/decision-desktop-primary.md`). If the user
/// taps a comparable, that opens it, because a person asked.
@MainActor
final class ComparableSearch {
    enum Failure: Error, Equatable {
        /// Facebook wants a session before it will show anything.
        case loginWall
        /// The search ran and returned nothing to compare against.
        case nothingFound
        /// The load failed, or the pacer refused it. Carries the engine's own
        /// message, which already distinguishes the two.
        case engine(String)
    }

    private let engine: DesktopFeedEngine

    /// Has to be in the view hierarchy for WebKit to render it — see
    /// `RootView`. Same constraint as the browse engines.
    var webView: WKWebView { engine.webView }

    init(engine: DesktopFeedEngine? = nil) {
        self.engine = engine ?? DesktopFeedEngine()
    }

    /// The first page of results for a term, as evidence.
    ///
    /// Filters are the app's own rather than the browse tab's, and that is a
    /// correctness point, not tidiness: someone browsing with "over $100" set
    /// would otherwise get a price guide computed from a corpus that excludes
    /// everything cheap, and it would read as the market rather than as their
    /// filter. Local pickup stays on — a private seller with a dresser is
    /// competing with other people's dressers in the same city, not with
    /// shipped ones.
    func comparables(to term: String,
                     citySlug: String,
                     radiusKM: Int,
                     limit: Int = 15) async -> Result<[MarketComp], Failure> {
        let query = SearchQuery(
            kind: .search(term),
            // Sent for shape only; no surface honours it (`SearchQuery.url`).
            radiusKM: radiusKM == 0 ? 40 : radiusKM,
            citySlug: citySlug,
            coordinate: nil,
            sort: .bestMatch,
            delivery: .localPickup
        )
        return await run(query, limit: limit)
    }

    /// What has actually sold nearby, lately.
    ///
    /// The one thing the rest of the app has never been able to see. A default
    /// search returns **0 sold and 0 pending** — measured, not assumed — so
    /// every listing the app has shown anyone is by construction still for
    /// sale. `availability=out of stock` is the only way past that.
    ///
    /// Two measurements shape the call (`docs/filter-parameters.md` §10):
    ///
    /// * **`out of stock` is Pending *and* Sold**, and the proportion is not a
    ///   detail. Without a day filter a couch search came back 2 sold against
    ///   12 pending — a strip of things that haven't sold. Adding
    ///   `daysSinceListed` inverted it to 12 sold against 3. Recently-listed
    ///   unavailable items have mostly sold outright; older ones are sitting in
    ///   Pending. So the window is not optional here, and pending cards are
    ///   dropped rather than shown.
    /// * **Thirty days, not seven.** Seven is a tighter recency claim and it
    ///   works, but the result cap is ~15 before pending is removed, and a
    ///   narrow query with a narrow window returns nothing at all. Thirty keeps
    ///   the sample usable, and each card carries its own age so the claim made
    ///   about it stays specific.
    func soldComparables(to term: String,
                         citySlug: String,
                         radiusKM: Int,
                         limit: Int = 15) async -> Result<[MarketComp], Failure> {
        let query = SearchQuery(
            kind: .search(term),
            radiusKM: radiusKM == 0 ? 40 : radiusKM,
            citySlug: citySlug,
            coordinate: nil,
            sort: .bestMatch,
            delivery: .localPickup,
            age: .month,
            availability: .unavailable
        )
        return await run(query, limit: limit).map { comps in
            // Sold only. A pending listing is an item someone has agreed to buy
            // and not yet collected — it is evidence of interest, not of a
            // completed sale, and mixing the two would let "recently sold" mean
            // "recently spoken for".
            comps.filter(\.isSold)
        }
    }

    private func run(_ query: SearchQuery, limit: Int) async -> Result<[MarketComp], Failure> {
        let payload = await engine.load(query)
        if case .loginWall = engine.state { return .failure(.loginWall) }

        var comps = payload.prefix(limit).enumerated().map { index, item in
            MarketComp(payload: item, cardIndex: index)
        }

        // The payload is absent often enough to plan for — a page served
        // entirely client-side renders cards with no embedded listing block at
        // all. The markup carries titles and prices, which is all this needs.
        if comps.isEmpty {
            comps = await engine.renderedCards().enumerated()
                .compactMap { index, card in DesktopCardParser.parse(card, cardIndex: index) }
                .prefix(limit)
                .map(MarketComp.init(listing:))
        }

        guard !comps.isEmpty else {
            if case .failed(let message) = engine.state { return .failure(.engine(message)) }
            return .failure(.nothingFound)
        }
        Logger.seller.info("comps for \(query.displayName, privacy: .public) [\(query.availability.rawValue, privacy: .public)]: \(comps.count, privacy: .public), \(comps.filter(\.isSold).count, privacy: .public) sold")
        return .success(comps)
    }
}
