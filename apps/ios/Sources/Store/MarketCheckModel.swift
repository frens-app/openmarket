import Foundation
import WebKit

/// Runs "is this a good price?" for any listing the user asks about.
///
/// Held at app level rather than by `DetailView`, and that is what makes the
/// feature non-disruptive: the run belongs to the listing, not to the screen. A
/// user can start a check, back out to a Discover feed they have scrolled a long
/// way down, and come back to a finished answer — nothing about the browse
/// engines, their scroll position, or their in-flight navigation is touched,
/// because the searches run on `MarketCheckPool`'s own webviews.
///
/// No model is involved anywhere. The query is `SearchTerm`, the comparison is
/// `PriceGuide` and `SoldSignal`, and every number shown was read off a card.
@MainActor
final class MarketCheckModel: ObservableObject {
    @Published private(set) var phases: [String: MarketCheckPhase] = [:]

    private let pool: MarketCheckPool
    private let prefs: Preferences
    /// Insertion order, for eviction. A check holds up to thirty comparables
    /// with their thumbnails, and a long browse session opens a lot of listings.
    private var order: [String] = []
    private static let capacity = 40

    init(pool: MarketCheckPool? = nil, prefs: Preferences = .shared) {
        self.pool = pool ?? MarketCheckPool()
        self.prefs = prefs
    }

    /// Must be in the view hierarchy for WebKit to keep rendering them — same
    /// constraint as the browse engines, same fix in `SignedInView`.
    var webViews: [WKWebView] { pool.webViews }

    func phase(for listing: Listing) -> MarketCheckPhase? { phases[listing.id] }

    /// Whether the question can be asked about this listing at all.
    ///
    /// A price of zero is excluded along with an unreadable one: "is Free a good
    /// price" has no answer, and `PriceGuide` drops giveaways from every sample
    /// anyway, so there would be nothing to place it against.
    static func canCheck(_ listing: Listing) -> Bool {
        guard let price = PriceGuide.parse(listing.priceText), price > 0 else { return false }
        return !SearchTerm.from(listing.title ?? "").isEmpty
    }

    /// Starts a check, or does nothing if this listing already has one.
    ///
    /// Re-entrant by design: the button stays on screen while the run goes, and
    /// a second tap must not spend two more page loads on an answer already
    /// arriving. A failed check *can* be re-run — that is the retry.
    func check(_ listing: Listing) {
        guard let price = PriceGuide.parse(listing.priceText), price > 0 else { return }
        let term = SearchTerm.from(listing.title ?? "")
        guard !term.isEmpty else { return }
        switch phases[listing.id] {
        case .running, .done: return
        case .failed, nil: break
        }
        Task { await run(listing, price: price, term: term) }
    }

    private func run(_ listing: Listing, price: Int, term: String) async {
        let startedAt = Date()
        var started: [String: Any] = ["listing_id": listing.id, "price": price]
        started["search_term"] = Analytics.text(term.lowercased())
        started["title"] = Analytics.text(listing.title)
        Analytics.capture(.marketCheckStarted, started)

        set(listing.id, .running(pool.hasFreeSearch
                                 ? "Checking what similar things are listed for"
                                 : "Queued behind another check"))

        let citySlug = prefs.locationSlug ?? "sanfrancisco"
        let radiusKM = prefs.radiusKM
        let outcome = await pool.withSearch { search -> Result<([MarketComp], SoldSignal), ComparableSearch.Failure> in
            self.set(listing.id, .running("Checking what similar things are listed for"))
            let active = await search.comparables(to: term, citySlug: citySlug, radiusKM: radiusKM)
            switch active {
            case .failure(let error):
                return .failure(error)
            case .success(let found):
                self.set(listing.id, .running("Checking what's actually been selling"))
                let soldResult = await search.soldComparables(to: term, citySlug: citySlug, radiusKM: radiusKM)
                // Non-fatal, as in `SellerToolsModel`: plenty of things have
                // nothing sold near you in a month, and that is a fact about
                // the item rather than a broken run.
                let sold = (try? soldResult.get()) ?? []
                return .success((found, SoldSignal(comps: sold)))
            }
        }

        switch outcome {
        case .failure(let error):
            set(listing.id, .failed(Self.message(for: error)))
            Analytics.capture(.marketCheckFailed, [
                "listing_id": listing.id,
                "reason": SellerToolsModel.reason(for: error),
                "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
            ])
        case .success(let (found, sold)):
            let comps = found.filter { !Self.isSameListing($0, as: listing) }
            let check = MarketCheck(term: term,
                                    price: price,
                                    comps: comps,
                                    sold: sold,
                                    marketName: prefs.locationName ?? "your area")
            set(listing.id, .done(check))

            var completed: [String: Any] = [
                "listing_id": listing.id,
                "price": price,
                "comps_found": comps.count,
                "sold_count": sold.count,
                "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
                // Whether the check could place the price at all. A run with
                // comparables that all had unreadable prices completed and
                // answered nothing, and the average shouldn't hide it.
                "has_standing": check.standing != nil
            ]
            if let standing = check.standing { completed["standing"] = Self.name(of: standing) }
            completed["search_term"] = Analytics.text(term.lowercased())
            Analytics.capture(.marketCheckCompleted, completed)
        }
    }

    private func set(_ id: String, _ phase: MarketCheckPhase) {
        if phases[id] == nil { order.append(id) }
        phases[id] = phase
        guard order.count > Self.capacity else { return }
        // The oldest *finished* one, and at most one per call — which is what
        // makes this terminate. Skipping a running entry and retrying spins
        // forever the moment every entry is running, and a running check has to
        // be skipped: evicting it leaves its task writing into a dictionary
        // nothing reads any more.
        guard let victim = order.firstIndex(where: { phases[$0]?.isRunning != true }) else { return }
        phases[order.remove(at: victim)] = nil
    }

    /// The listing's own card, when the search hands it back.
    ///
    /// Two keys, because the two ids can disagree. Identity is the photo FBID
    /// where the thumbnail has one and Facebook's listing id otherwise
    /// (`DesktopCardParser`), so a listing captured off a different surface —
    /// or before its URL resolved — matches on the item id in the URL instead.
    private static func isSameListing(_ comp: MarketComp, as listing: Listing) -> Bool {
        if comp.listing.id == listing.id { return true }
        guard let a = itemID(comp.listing.itemURL), let b = itemID(listing.itemURL) else { return false }
        return a == b
    }

    private static func itemID(_ url: URL?) -> String? {
        guard let url, url.path.contains("/marketplace/item/") else { return nil }
        return url.pathComponents.last { !$0.isEmpty && $0 != "/" }
    }

    /// Its own copy rather than `SellerToolsModel.message(for:)`, because the
    /// thing to do next differs: a seller is told to go and sign in on Browse,
    /// and this reader is already there.
    private static func message(for error: ComparableSearch.Failure) -> String {
        switch error {
        case .loginWall:
            return "Facebook won't show these results without a login. Sign in and try again."
        case .nothingFound:
            return "Nothing similar is listed nearby to compare this against."
        case .engine(let message):
            return message
        }
    }

    private static func name(of standing: MarketCheck.Standing) -> String {
        switch standing {
        case .below: "below"
        case .around: "around"
        case .above: "above"
        }
    }
}
