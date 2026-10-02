import Foundation
import WebKit
import os

/// Runs "is this a good price?" for any listing the user asks about.
///
/// Held at app level rather than by `DetailView`, and that is what makes the
/// feature non-disruptive: the run belongs to the listing, not to the screen. A
/// user can start a check, back out to a Discover feed they have scrolled a long
/// way down, and come back to a finished answer — nothing about the browse
/// engines, their scroll position, or their in-flight navigation is touched,
/// because the searches run on `MarketCheckPool`'s own webviews.
///
/// Jev checks relevance before `PriceGuide` and `SoldSignal` read the prices.
@MainActor
final class MarketCheckModel: ObservableObject {
    @Published private(set) var phases: [String: MarketCheckPhase] = [:]

    private let pool: MarketCheckPool
    private let prefs: Preferences
    private let pricing: PricingService
    /// Insertion order, for eviction. A check holds up to thirty comparables
    /// with their thumbnails, and a long browse session opens a lot of listings.
    private var order: [String] = []
    private static let capacity = 40

    init(pool: MarketCheckPool? = nil, prefs: Preferences = .shared, pricing: PricingService? = nil) {
        self.pricing = pricing ?? PricingService(session: .shared)
        self.pool = pool ?? MarketCheckPool()
        self.prefs = prefs
    }

    /// Must be in the view hierarchy for WebKit to keep rendering them — same
    /// constraint as the browse engines, same fix in `AppView`.
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
        set(listing.id, .running("Starting comparison"))
        Task { await run(listing, price: price, term: term) }
    }

    private func run(_ listing: Listing, price: Int, term: String) async {
        let startedAt = ContinuousClock.now
        var started: [String: Any] = ["listing_id": listing.id, "price": price]
        started["search_term"] = Analytics.text(term.lowercased())
        started["title"] = Analytics.text(listing.title)
        Analytics.capture(.marketCheckStarted, started)

        set(listing.id, .running(pool.hasFreeSearch
                                 ? "Checking active and recently sold listings"
                                 : "Queued behind another check"))

        let citySlug = prefs.locationSlug ?? "sanfrancisco"
        let radiusKM = prefs.radiusKM
        let coordinate = prefs.resolvedPlace.flatMap { $0.segment == citySlug ? $0.coordinate : nil }
        let pair = await pool.comparables(to: term, citySlug: citySlug, radiusKM: radiusKM,
                                         coordinate: coordinate) {
            self.set(listing.id, .running("Checking active and recently sold listings"))
        }
        var timings = pair.timings
        timings["searches_ms"] = Int(startedAt.duration(to: .now) / .milliseconds(1))
        defer {
            timings["duration_ms"] = Int(startedAt.duration(to: .now) / .milliseconds(1))
            Logger.seller.info("comparison timings: \(String(describing: timings), privacy: .public)")
        }

        switch pair.active.result {
        case .failure(let error):
            set(listing.id, .failed(Self.message(for: error)))
            var failed: [String: Any] = [
                "listing_id": listing.id,
                "reason": SellerToolsModel.reason(for: error),
                "duration_ms": Int(startedAt.duration(to: .now) / .milliseconds(1))
            ]
            failed.merge(timings) { _, new in new }
            Analytics.capture(.marketCheckFailed, failed)
        case .success(let found):
            // Sold-search failure remains nonfatal. Record it separately so
            // failed searches aren't counted as healthy empty markets in timing data.
            let soldFound = (try? pair.sold.result.get()) ?? []
            if case .failure(let error) = pair.sold.result {
                timings["sold_search_outcome"] = SellerToolsModel.reason(for: error)
            } else { timings["sold_search_outcome"] = "success" }
            let active = found.filter { !Self.isSameListing($0, as: listing) }
            let soldCandidates = soldFound.filter { !Self.isSameListing($0, as: listing) }
            set(listing.id, .running("Checking which listings are comparable"))
            let evaluated: [MarketComp]
            let relevanceStarted = ContinuousClock.now
            do {
                evaluated = try await pricing.evaluate(target: ComparisonRelevance.item(for: listing),
                                                       comps: active + soldCandidates)
            } catch {
                set(listing.id, .failed("Couldn't check which listings are comparable. " + SellerToolsModel.message(for: error)))
                timings["relevance_ms"] = Int(relevanceStarted.duration(to: .now) / .milliseconds(1))
                var failed = timings
                failed["listing_id"] = listing.id
                failed["reason"] = "relevance_failed"
                failed["duration_ms"] = Int(startedAt.duration(to: .now) / .milliseconds(1))
                Analytics.capture(.marketCheckFailed, failed)
                return
            }
            timings["relevance_ms"] = Int(relevanceStarted.duration(to: .now) / .milliseconds(1))
            let comps = Array(evaluated.prefix(active.count))
            let sold = SoldSignal(comps: Array(evaluated.dropFirst(active.count)))
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
                "duration_ms": Int(startedAt.duration(to: .now) / .milliseconds(1)),
                // Whether the check could place the price at all. A run with
                // comparables that all had unreadable prices completed and
                // answered nothing, and the average shouldn't hide it.
                "has_standing": check.standing != nil
            ]
            if let standing = check.standing { completed["standing"] = Self.name(of: standing) }
            completed["search_term"] = Analytics.text(term.lowercased())
            completed.merge(timings) { _, new in new }
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

    /// Comparison retrieval is anonymous, so signing into Browse cannot fix a
    /// wall on this isolated surface.
    private static func message(for error: ComparableSearch.Failure) -> String {
        switch error {
        case .loginWall:
            return "Facebook isn't showing comparison results right now. Try again later."
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
