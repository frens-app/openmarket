import Foundation
import SwiftUI
import WebKit

/// Everything behind the Seller tab: search the market, read the prices, work
/// out what to ask.
///
/// Held at app level rather than by the screen, so a result survives switching
/// to Browse and back. Someone pricing a dresser is very likely to go and look
/// at the dressers.
///
/// The run is four steps — identify, search, check what sold, read the prices —
/// and exactly one of them leaves this device to reach a model. The search
/// cannot move off the phone at all: it is a `WKWebView` against the user's own
/// Facebook session.
///
/// The model is deliberately kept away from the arithmetic (README, "The
/// on-device writer"). It is never shown a comparable: `PriceGuide` computes the
/// numbers and picks the median, and the item is named and the listing written
/// from the photo alone, before any comparable exists. Nothing needs clamping to
/// the observed range, because the median is inside it by construction.
@MainActor
final class SellerToolsModel: ObservableObject {
    /// One line of the transcript.
    ///
    /// The work is four distinct things — understand, search, check what sold,
    /// price — and each takes long enough to be worth naming. A single spinner
    /// for the whole run would hide that the app went and looked at the actual
    /// market, which is the part worth trusting.
    struct Step: Identifiable, Equatable {
        enum Kind: Hashable { case identify, search, sold, price }
        enum State: Equatable { case running, done, failed }

        let kind: Kind
        var text: String
        var state: State

        var id: Kind { kind }
    }

    enum Phase: Equatable {
        case idle
        case running
        case done
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    /// What the last run was asked about. Written when a run starts, and
    /// deliberately **not** bound to the text field.
    ///
    /// This object republishes constantly once a run is going, and a SwiftUI
    /// `TextField` re-rendered from its binding while the keyboard has an
    /// uncommitted autocorrect composition open loses that composition: the
    /// field blanks and hands back the marked substring doubled, which is how a
    /// search for "anthurium" went out as "anthuriumium" (FRE-6471). The field
    /// owns its own text and hands it over once, on the tap that starts the run.
    @Published private(set) var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [Step] = []
    @Published private(set) var comps: [MarketComp] = []
    @Published private(set) var guide: PriceGuide?
    /// What sold nearby in the last month. Empty is an ordinary outcome, not a
    /// failure — plenty of things simply haven't sold near you lately.
    @Published private(set) var sold = SoldSignal(comps: [])
    /// What we recommended: the median of what similar things are listed for.
    /// Fixed for the run, and the number the server records.
    @Published private(set) var recommendedPrice: Int?
    /// What the user settled on, which starts as the recommendation and moves
    /// when they use the stepper. Kept separate from `recommendedPrice` rather
    /// than replacing it: the gap between the two is what would tell us the
    /// median is the wrong statistic, and overwriting erases that evidence.
    @Published private(set) var askingPrice: Int?
    @Published private(set) var priceRationale: String?
    /// What we actually searched for, which is usually not what the user typed.
    /// Shown, because a price guide is only as good as the comparables behind
    /// it and the user is the one who can tell whether we searched sensibly.
    @Published private(set) var searchTerm: String?

    /// What the model made of the photo. Shown for the same reason as the
    /// search term: it is checkable by the person holding the object, and a
    /// price for the wrong item is worse than no price.
    @Published private(set) var identifiedName: String?

    /// The listing, ready to paste. Absent when the writing step failed — which
    /// leaves the price standing, because the price never depended on it.
    @Published private(set) var listingTitle: String?
    @Published private(set) var listingBody: String?

    /// The answer to "were these helpful?", or nil for unanswered. Three
    /// states, not two: somebody who said no and somebody who never looked are
    /// not the same person, and a Bool defaulting to false would merge them.
    @Published private(set) var feedback: Bool?

    /// Ties this run to its row on the server, for the price call and for both
    /// feedback signals afterwards. Nil until the identify call returns.
    private(set) var priceCheckID: String?

    /// The runs already done, newest first. Read from the server rather than
    /// remembered here: the row is written on every run before the model is
    /// called, so a device-side copy would only disagree with it after the first
    /// reinstall.
    @Published private(set) var recent: [PastPriceCheck] = []
    /// True only for the first load, so an empty list can tell "nothing yet"
    /// from "we haven't looked". A refresh behind an already-populated list is
    /// silent — nobody needs a spinner over rows they can already read.
    @Published private(set) var isLoadingRecent = false

    private let search: ComparableSearch
    private let pricing: PricingService
    /// Read from, never written to — specifically, this tab must never call
    /// `prefs.recordSearch`. Its terms are derived from what the user is
    /// drafting a listing for, so recording them would put the thing they are
    /// trying to *sell* into their own search suggestions.
    private let prefs: Preferences
    private var task: Task<Void, Never>?

    /// Has to be in the view hierarchy for WebKit to keep rendering it — same
    /// constraint as the browse engines, same fix in `RootView`.
    var webView: WKWebView { search.webView }

    init(search: ComparableSearch? = nil,
         pricing: PricingService? = nil,
         prefs: Preferences = .shared) {
        self.search = search ?? ComparableSearch()
        self.pricing = pricing ?? PricingService(session: .shared)
        self.prefs = prefs
    }

    /// Where the comparables come from, for the screen to state up front.
    var marketName: String { prefs.locationName ?? "your area" }

    var hasResult: Bool { recommendedPrice != nil }

    // MARK: - The run

    /// Needs three characters of description **or** at least one photo. Photos
    /// alone are a real run — a vision model naming an item from an image is
    /// the thing this feature is built on — so the guard is on having something
    /// to send, not on having words.
    func start(_ text: String, photos: [ItemPhoto] = []) {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.count >= 3 || !photos.isEmpty else { return }
        input = item
        task?.cancel()
        task = Task { await run(item, photos: photos) }
    }

    // MARK: - Afterwards

    /// Moves the asking price one step, and rewrites the sentence under it.
    ///
    /// Clamped to the observed prices, deliberately the full range rather than
    /// the middle half: an item that genuinely is the best one listed should be
    /// allowed to ask what the best one listed is asking. Outside the observed
    /// range there is no evidence at all, and the bar has nowhere to draw it.
    func nudgePrice(by direction: Int) {
        guard let guide, let current = askingPrice else { return }
        let stepped = current + direction * Self.step(around: current)
        let next = guide.clamped(stepped)
        guard next != current else { return }
        askingPrice = next
        priceRationale = sold.rationale(for: next, against: guide)
    }

    /// Round numbers, scaled to what is being sold.
    ///
    /// A $5 step is right for a $150 grill and absurd for a $4,000 piano —
    /// eight hundred taps to cross its own range. Roughly 3% of the price,
    /// rounded to something a person would actually write on a listing.
    static func step(around price: Int) -> Int {
        switch price {
        case ..<50: 1
        case 50..<200: 5
        case 200..<1_000: 10
        case 1_000..<5_000: 50
        default: 100
        }
    }

    /// Whether the stepper can still move in a direction — so a button that
    /// would do nothing is disabled rather than silently ignoring a tap.
    func canNudge(_ direction: Int) -> Bool {
        guard let guide, let current = askingPrice else { return false }
        return guide.clamped(current + direction * Self.step(around: current)) != current
    }

    /// Records the answer to the helpful question, and keeps it on screen.
    ///
    /// Optimistic: the button fills in immediately and the call goes out behind
    /// it. Somebody's opinion of a finished screen is not worth a spinner, and a
    /// failure here costs one row of telemetry.
    func recordFeedback(helpful: Bool) {
        guard let priceCheckID, feedback != helpful else { return }
        feedback = helpful
        Task { await pricing.submitFeedback(priceCheckID: priceCheckID, helpful: helpful) }
        // Deliberately duplicated: the server row joins to the run, the event
        // joins to everything else that person did.
        Analytics.capture(.priceCheckFeedbackSubmitted, [
            "helpful": helpful,
            "comps_found": comps.count,
            // "Your price was right" vs "wrong, and here's what I fixed it to".
            "was_adjusted": askingPrice != recommendedPrice
        ])
    }

    /// Records that the price was copied, **and which price it was**.
    ///
    /// The signal worth having: copying the number is what somebody does right
    /// before pasting it into Facebook's price box, and it arrives from everyone
    /// rather than the few who answer a question. Since the number is
    /// adjustable, what they copied differs from what we recommended, and
    /// sending it beside `recommended_price_minor` makes the gap queryable.
    func recordPriceCopied() {
        guard let priceCheckID else { return }
        let copied = askingPrice
        Task { await pricing.recordCopy(priceCheckID: priceCheckID, price: copied) }

        // Both numbers and the gap between them: "sellers move our price up 20%
        // on average" is the finding that would retire the median, and it needs
        // them side by side.
        var properties: [String: Any] = [
            "source": Analytics.Surface.priceCheckRun.rawValue,
            "comps_found": comps.count,
            "sold_count": sold.count
        ]
        properties.merge(itemDescriptors) { current, _ in current }
        if let recommended = recommendedPrice {
            properties["recommended_price"] = recommended
            if let copied {
                properties["asking_price"] = copied
                properties["was_adjusted"] = copied != recommended
                if recommended > 0 {
                    let shift = Double(copied - recommended) / Double(recommended) * 100
                    properties["adjustment_pct"] = (shift * 10).rounded() / 10
                }
            }
        }
        Analytics.capture(.priceCheckPriceCopied, properties)
    }

    /// Records the listing text as it was copied, edited or not.
    ///
    /// Sent even when it is word-for-word what the model wrote: "they read it
    /// and used it unchanged" is the result this feature is hoping for, and it
    /// has to be distinguishable from "they never copied it at all". A null
    /// column means the latter.
    func recordListingCopied(title: String? = nil, description: String? = nil) {
        guard let priceCheckID else { return }
        Task { await pricing.recordCopy(priceCheckID: priceCheckID, title: title, description: description) }

        // The verdict only — the text goes to our server, which holds both what
        // the model wrote and what got pasted, and is the only place the diff
        // can be taken.
        var properties: [String: Any] = [
            "source": Analytics.Surface.priceCheckRun.rawValue,
            "field": title != nil ? "title" : "description",
            "was_edited": title.map { $0 != listingTitle } ?? (description != listingBody)
        ]
        properties["identified_name"] = Analytics.text(identifiedName)
        Analytics.capture(.priceCheckListingCopied, properties)
    }

    /// Refreshes the recent list, quietly.
    ///
    /// A failure leaves whatever was already there and says nothing. This is a
    /// list of things the user has already seen once; an error banner over it
    /// would interrupt somebody who came here to price a chair, about a
    /// convenience they had not asked for yet.
    func loadRecent() async {
        if recent.isEmpty { isLoadingRecent = true }
        defer { isLoadingRecent = false }
        guard let checks = try? await pricing.recentChecks() else { return }
        recent = checks
    }

    /// The same three signals, from a run that finished some time ago. Separate
    /// from the two above only because it names its subject: those read
    /// `priceCheckID`, the run in progress, and a copy taken off the history
    /// screen belongs to a different row.
    func recordCopy(of check: PastPriceCheck,
                    price: Int? = nil,
                    title: String? = nil,
                    description: String? = nil) {
        Task {
            await pricing.recordCopy(priceCheckID: check.id,
                                     price: price,
                                     title: title,
                                     description: description)
        }

        // The same two events as a fresh run, told apart by `source` rather
        // than a third event name — "the price got copied" is one question.
        if let price {
            var properties: [String: Any] = [
                "source": Analytics.Surface.priceCheckHistory.rawValue,
                "asking_price": price,
                // A stored run keeps its price but not the range behind it, so
                // there is no adjustment to compute.
                "was_adjusted": false
            ]
            properties["identified_name"] = Analytics.text(check.label)
            properties["search_term"] = Analytics.text(check.searchTerm.lowercased())
            Analytics.capture(.priceCheckPriceCopied, properties)
        }
        if title != nil || description != nil {
            var properties: [String: Any] = [
                "source": Analytics.Surface.priceCheckHistory.rawValue,
                "field": title != nil ? "title" : "description",
                "was_edited": title.map { $0 != check.listingTitle }
                    ?? (description != check.listingBody)
            ]
            properties["identified_name"] = Analytics.text(check.label)
            Analytics.capture(.priceCheckListingCopied, properties)
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase.isRunning { phase = .idle }
    }

    private func clearResults() {
        steps = []
        comps = []
        guide = nil
        sold = SoldSignal(comps: [])
        recommendedPrice = nil
        askingPrice = nil
        priceRationale = nil
        searchTerm = nil
        identifiedName = nil
        listingTitle = nil
        listingBody = nil
        feedback = nil
        priceCheckID = nil
    }

    private func run(_ item: String, photos: [ItemPhoto]) async {
        clearResults()
        phase = .running

        let startedAt = Date()
        photoCount = photos.count
        // Photos aren't sent — they are megabytes, and already stored against
        // the run's row on the server.
        var started: [String: Any] = [
            "photo_count": photos.count,
            "has_description": !item.isEmpty,
            "description_length": item.count
        ]
        started["description"] = Analytics.text(item)
        Analytics.capture(.priceCheckStarted, started)

        // 1 — what this is, and what to search for. Its own step because it can
        // be wrong in a way the user can see and correct: "we think this is a
        // Vitamix 5200, searching for vitamix 5200 blender" is checkable where
        // "found 14 listings" is not. Load-bearing — no query, no search.
        begin(.identify, Self.identifyStepText(photoCount: photos.count))
        let term: String
        do {
            let identified = try await pricing.identify(description: item, photos: photos)
            guard !Task.isCancelled else { return }
            priceCheckID = identified.priceCheckID
            identifiedName = identified.name.isEmpty ? nil : identified.name
            // An empty term is not a weak search, it is a search for the entire
            // marketplace, so a photo-only run with no server query stops here.
            let typed = SearchTerm.from(item)
            guard let query = identified.primaryQuery ?? (typed.isEmpty ? nil : typed) else {
                let message = "Couldn't work out what this is. Try adding a description."
                fail(.identify, message)
                phase = .failed(message)
                captureRunFailed(.identify, reason: "no_query", startedAt: startedAt)
                return
            }
            term = query
            // The listing arrives with the identification because both are read
            // off the same photograph. Nothing later can improve them, and one
            // thing later could poison them — see `IdentifiedItem` in pkg/llm.
            listingTitle = identified.listingTitle.isEmpty ? nil : identified.listingTitle
            listingBody = identified.listingBody.isEmpty ? nil : identified.listingBody
        } catch {
            guard !Task.isCancelled else { return }
            let message = Self.message(for: error)
            fail(.identify, message)
            phase = .failed(message)
            captureRunFailed(.identify, reason: Self.reason(for: error), startedAt: startedAt)
            return
        }
        searchTerm = term
        finish(.identify, identifiedName.map { "\($0) — searching for “\(term)”" }
               ?? "Searching for “\(term)”")

        // 2 — the market itself. One page load.
        begin(.search, "Checking what similar things are listed for in \(marketName)")
        let result = await search.comparables(to: term,
                                              citySlug: prefs.locationSlug ?? "sanfrancisco",
                                              radiusKM: prefs.radiusKM)
        guard !Task.isCancelled else { return }
        switch result {
        case .failure(let error):
            fail(.search, Self.message(for: error))
            phase = .failed(Self.message(for: error))
            captureRunFailed(.search, reason: Self.reason(for: error), startedAt: startedAt)
            return
        case .success(let found):
            comps = found
        }
        finish(.search, comps.count == 1
               ? "Found 1 nearby listing to compare against"
               : "Found \(comps.count) nearby listings to compare against")

        // 3 — what actually sold. A second page load, and the only one in the
        // app that reaches listings no longer for sale.
        //
        // Non-fatal by design: a narrow item may have nothing sold nearby in a
        // month, and that is information rather than an error.
        begin(.sold, "Checking what's actually been selling")
        let soldResult = await search.soldComparables(to: term,
                                                      citySlug: prefs.locationSlug ?? "sanfrancisco",
                                                      radiusKM: prefs.radiusKM)
        guard !Task.isCancelled else { return }
        if case .success(let found) = soldResult { sold = SoldSignal(comps: found) }
        finish(.sold, sold.summary)

        // 4 — arithmetic, in Swift, instantly, and this is the answer. No model:
        // asked for a number it returned this same median four seconds and 1300
        // tokens later, moving ±10–20% only where the seller had written
        // something about condition — a judgement the user can make from the
        // range on screen and this code cannot check.
        begin(.price, "Reading the prices")
        let computed = PriceGuide(comps: comps)
        guide = computed
        guard let median = computed.median else {
            fail(.price, "None of them had a price to compare")
            phase = .done
            // Completed, not failed — `phase` agrees. Comparables with no
            // readable price is a fact about the listings. `has_price` splits it
            // from a run that produced a number.
            captureRunCompleted(startedAt: startedAt, price: nil)
            return
        }
        recommendedPrice = median
        askingPrice = median
        priceRationale = sold.rationale(for: median, against: computed)
        finish(.price, "\(Self.summary(of: computed)) — suggesting \(computed.money(median))")

        phase = .done
        captureRunCompleted(startedAt: startedAt, price: median)

        // 5 — bookkeeping, after `phase = .done`, because nothing here is
        // something the user is waiting on. A failure loses one row of telemetry.
        await record(compsFound: comps.count, price: median, guide: computed)

        // Fetched now rather than when the input screen reappears: the user is
        // still reading the answer, so the list is populated before they press
        // Back.
        await loadRecent()
    }

    /// Reports the finished run. Silent on failure, by the reasoning above.
    private func record(compsFound: Int, price: Int, guide: PriceGuide) async {
        guard let priceCheckID else { return }
        try? await pricing.complete(
            priceCheckID: priceCheckID,
            searchQuery: searchTerm ?? "",
            compsFound: compsFound,
            recommendedPrice: price,
            guide: guide,
            sold: sold
        )
    }

    // MARK: - Analytics

    private func captureRunCompleted(startedAt: Date, price: Int?) {
        var properties: [String: Any] = [
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "photo_count": photoCount,
            "comps_found": comps.count,
            "sold_count": sold.count,
            "has_price": price != nil,
            "has_listing_copy": listingTitle != nil || listingBody != nil
        ]
        // Omitted rather than zeroed: a run that found no market did not
        // recommend $0, and the average shouldn't say it did.
        if let price { properties["recommended_price"] = price }
        properties.merge(itemDescriptors) { current, _ in current }
        Analytics.capture(.priceCheckCompleted, properties)
    }

    private func captureRunFailed(_ step: Step.Kind, reason: String, startedAt: Date) {
        var properties: [String: Any] = [
            "step": Self.name(of: step),
            "reason": reason,
            "photo_count": photoCount,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
        ]
        properties.merge(itemDescriptors) { current, _ in current }
        Analytics.capture(.priceCheckFailed, properties)
    }

    /// What was typed, what the model called it, what got searched. The chain a
    /// wrong price went wrong somewhere in, so every price-check event carries
    /// whichever links exist yet.
    private var itemDescriptors: [String: Any] {
        var descriptors: [String: Any] = [:]
        descriptors["description"] = Analytics.text(input)
        descriptors["identified_name"] = Analytics.text(identifiedName)
        descriptors["search_term"] = Analytics.text(searchTerm?.lowercased())
        return descriptors
    }

    /// Held because `PriceCheckView` empties its photo strip on submit, and a
    /// finished run has nowhere else to read this from.
    private var photoCount = 0

    private static func name(of step: Step.Kind) -> String {
        switch step {
        case .identify: return "identify"
        case .search: return "search"
        case .sold: return "sold"
        case .price: return "price"
        }
    }

    /// A stable code rather than the sentence shown on screen, which can carry
    /// server text and isn't worth grouping on.
    static func reason(for error: Error) -> String {
        switch error as? APIError {
        case .rateLimited: return "rate_limited"
        case .unauthenticated: return "unauthenticated"
        case .message: return "rejected"
        case .network, .none: return "network"
        }
    }

    static func reason(for error: ComparableSearch.Failure) -> String {
        switch error {
        case .loginWall: return "login_wall"
        case .nothingFound: return "nothing_found"
        case .engine: return "engine"
        }
    }

    // MARK: - Transcript

    private func begin(_ kind: Step.Kind, _ text: String) {
        withAnimation(.easeOut(duration: 0.2)) {
            steps.append(Step(kind: kind, text: text, state: .running))
        }
    }

    private func finish(_ kind: Step.Kind, _ text: String) {
        update(kind) { $0.text = text; $0.state = .done }
    }

    private func fail(_ kind: Step.Kind, _ text: String) {
        update(kind) { $0.text = text; $0.state = .failed }
    }

    private func update(_ kind: Step.Kind, _ change: (inout Step) -> Void) {
        guard let index = steps.firstIndex(where: { $0.kind == kind }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { change(&steps[index]) }
    }

    // MARK: - Words for things

    /// What the first step calls itself, which depends on what was sent.
    /// "Looking at your photos" is a claim the user can check against what they
    /// attached, over the four or five seconds the model call takes.
    static func identifyStepText(photoCount: Int) -> String {
        switch photoCount {
        case 0: "Working out what you're selling"
        case 1: "Looking at your photo"
        default: "Looking at your \(photoCount) photos"
        }
    }

    /// States the count as well as the band. "Found 15 nearby listings" followed
    /// by "most asking $55–$125" implies the same fifteen, when the guide may
    /// have been built from fourteen — one free, sold, or with no readable price.
    static func summary(of guide: PriceGuide) -> String {
        guard guide.count > 0 else { return "None of them had a price to compare" }
        if let range = guide.typicalRange {
            return "\(guide.count) prices — most asking \(guide.money(range.lowerBound))–\(guide.money(range.upperBound))"
        }
        if let median = guide.median {
            return guide.count == 1
                ? "Only one to go on, at \(guide.money(median))"
                : "\(guide.count) prices, around \(guide.money(median))"
        }
        return "None of them had a price to compare"
    }

    /// What to say when a server call fails.
    ///
    /// `APIError` already carries text written for a person — the API client
    /// only lets a server message through for the codes where the server meant
    /// it to be read — so it is used verbatim. Anything else is a network
    /// problem described as one.
    static func message(for error: Error) -> String {
        (error as? APIError)?.errorDescription ?? APIError.network.errorDescription ?? "Something went wrong."
    }

    static func message(for error: ComparableSearch.Failure) -> String {
        switch error {
        case .loginWall:
            return "Facebook won't show these results without a login. Sign in on the Browse tab and try again."
        case .nothingFound:
            return "Nothing similar is listed nearby, so there's no market to price against."
        case .engine(let message):
            return message
        }
    }
}
