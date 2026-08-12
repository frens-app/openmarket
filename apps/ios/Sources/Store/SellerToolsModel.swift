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
/// **The writing step is back, and it is server-side now.** It was Apple's
/// on-device model, and it went out because `SystemLanguageModel.availability`
/// reports `.available` on the strength of Apple Intelligence being switched
/// on, saying nothing about whether the 3B asset is installed — the permanent
/// state of the simulator, so the feature degraded to an apology on the machine
/// it gets developed on. A server has no such ambiguity: it is reachable or it
/// is not, and the difference is a network error rather than a guess.
///
/// Everything learned from that version still holds, and most of it is now
/// structural rather than prompted (README, "The on-device writer"):
///
/// * **The model cannot do arithmetic about its own evidence.** `PriceGuide`
///   still computes every number, and `PriceGuide.explanation` still writes the
///   sentence underneath. The model is sent the numbers and picks a point.
/// * **It takes the item's identity from the comparables if it can see them.**
///   It cannot: the item is identified from the photo in a first call, before a
///   single comparable exists. That failure is now unreachable rather than
///   argued with.
/// * **Its answer is clamped to the observed range**, here and again on the
///   server, because a price outside the evidence is not a bolder opinion about
///   the market.
///
/// The run is therefore three phases: identify, search the market on this
/// device, then price. The middle one cannot move — it is a `WKWebView` against
/// the user's own Facebook session — which is what makes this two round trips
/// rather than one.
@MainActor
final class SellerToolsModel: ObservableObject {
    /// One line of the transcript.
    ///
    /// The work is four distinct things — understand, search, check what sold,
    /// price — and each takes long enough to be worth naming. A single spinner
    /// for the whole run would hide that the app went and looked at the actual
    /// market, which is the part worth trusting.
    struct Step: Identifiable, Equatable {
        enum Kind: Hashable { case identify, search, sold, price, write }
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

    /// What the last run was asked about. Written when a run starts, never
    /// bound to the text field.
    ///
    /// The field used to bind straight to this. That put a `@Published` write
    /// in the middle of every keystroke, and this object republishes constantly
    /// once a run is going — `steps`, `comps`, `sold` and `phase` all change
    /// within seconds of each other. A SwiftUI `TextField` re-rendered from its
    /// binding while the keyboard has an *uncommitted* autocorrect composition
    /// open loses that composition: the field goes blank and the value it hands
    /// back has the marked substring doubled, which is how a search for
    /// "anthurium" went out as "anthuriumium" (FRE-6471). The field owns its
    /// own text now and hands it over once, on the tap that starts the run.
    @Published private(set) var input = ""
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var steps: [Step] = []
    @Published private(set) var comps: [MarketComp] = []
    @Published private(set) var guide: PriceGuide?
    /// What sold nearby in the last month. Empty is an ordinary outcome, not a
    /// failure — plenty of things simply haven't sold near you lately.
    @Published private(set) var sold = SoldSignal(comps: [])
    /// The number to ask, and why. The median of what similar things are listed
    /// for, which is exactly where the model was steered anyway.
    @Published private(set) var recommendedPrice: Int?
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

    private let search: ComparableSearch
    private let pricing: PricingService
    /// Read from, never written to.
    ///
    /// Specifically: this tab must never call `prefs.recordSearch`. The terms it
    /// searches are derived from whatever the user is drafting a listing for, so
    /// recording them would seed the home screen's Discover section with the
    /// thing they are trying to *sell* — and, on a shared device, put it in the
    /// search suggestions too. Location and filters are all this reads.
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

    /// Needs three characters of description **or** a photo. The photo alone is
    /// a real run — a vision model naming an item from an image is the thing
    /// this feature is built on — so the guard is on having something to send,
    /// not on having words.
    func start(_ text: String, photo: ItemPhoto? = nil) {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.count >= 3 || photo != nil else { return }
        input = item
        task?.cancel()
        task = Task { await run(item, photo: photo) }
    }

    // MARK: - Afterwards

    /// Records the answer to the helpful question, and keeps it on screen.
    ///
    /// Optimistic: the button fills in immediately and the call goes out behind
    /// it. Somebody's opinion of a finished screen is not worth a spinner, and a
    /// failure here costs one row of telemetry.
    func recordFeedback(helpful: Bool) {
        guard let priceCheckID, feedback != helpful else { return }
        feedback = helpful
        Task { await pricing.submitFeedback(priceCheckID: priceCheckID, helpful: helpful) }
    }

    /// Records that the price was copied.
    ///
    /// The signal worth having: copying the number is what somebody does right
    /// before pasting it into Facebook's price box, and it arrives from
    /// everybody rather than from the few who stop to answer a question.
    func recordPriceCopied() {
        guard let priceCheckID else { return }
        Task { await pricing.recordPriceCopied(priceCheckID: priceCheckID) }
    }

    func cancel() {
        task?.cancel()
        task = nil
        if phase.isRunning { phase = .idle }
    }

    func reset() {
        cancel()
        input = ""
        clearResults()
        phase = .idle
    }

    private func clearResults() {
        steps = []
        comps = []
        guide = nil
        sold = SoldSignal(comps: [])
        recommendedPrice = nil
        priceRationale = nil
        searchTerm = nil
        identifiedName = nil
        listingTitle = nil
        listingBody = nil
        feedback = nil
        priceCheckID = nil
    }

    private func run(_ item: String, photo: ItemPhoto?) async {
        clearResults()
        phase = .running

        // 1 — what this is, and what to search for.
        //
        // A round trip, because it is the only step that can see the photo.
        // Separated from the search itself because it can be wrong in a way the
        // user can see and correct: "we think this is a Vitamix 5200, searching
        // for vitamix 5200 blender" is checkable, "found 14 listings" is not.
        //
        // Load-bearing: without a query there is nothing to search, so a
        // failure here ends the run. The steps after it are not — see the
        // writing step at the bottom.
        begin(.identify, photo == nil ? "Working out what you're selling" : "Looking at your photo")
        let term: String
        do {
            let identified = try await pricing.identify(description: item, photo: photo)
            guard !Task.isCancelled else { return }
            priceCheckID = identified.priceCheckID
            identifiedName = identified.name.isEmpty ? nil : identified.name
            // The fallback re-derives a query from what the user typed, and on
            // a photo-only run there is nothing to derive it from. An empty
            // term is not a weak search, it is a search for the entire
            // marketplace — so this stops instead, which is the same thing the
            // step already does when the server has no query for us.
            let typed = SearchTerm.from(item)
            guard let query = identified.primaryQuery ?? (typed.isEmpty ? nil : typed) else {
                let message = "Couldn't work out what this is. Try adding a description."
                fail(.identify, message)
                phase = .failed(message)
                return
            }
            term = query
        } catch {
            guard !Task.isCancelled else { return }
            let message = Self.message(for: error)
            fail(.identify, message)
            phase = .failed(message)
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

        // 4 — arithmetic, in Swift, instantly. Its own step anyway: it is a
        // separate claim from "we found some listings", and it is the one that
        // can come back empty when everything found was free or sold.
        begin(.price, "Reading the prices")
        let computed = PriceGuide(comps: comps)
        guide = computed
        guard let median = computed.median else {
            fail(.price, "None of them had a price to compare")
            phase = .done
            return
        }
        // The median stands in until the model answers, so the screen is never
        // without a defensible number — this is exactly what it showed before
        // there was a writing step at all.
        recommendedPrice = median
        priceRationale = sold.rationale(for: median, against: computed)
        finish(.price, Self.summary(of: computed))

        // 5 — the price and the words for it.
        //
        // Explicitly *not* load-bearing. If this fails the median above is
        // already on screen with its working shown, so the step is marked
        // failed and the run still finishes: losing a title and a description
        // is not a reason to withhold a price that was never derived from
        // them.
        begin(.write, "Pricing it against the market")
        do {
            let draft = try await pricing.price(
                priceCheckID: priceCheckID ?? "",
                searchQuery: searchTerm ?? "",
                marketName: marketName,
                comparables: comps,
                guide: computed,
                sold: sold
            )
            guard !Task.isCancelled else { return }
            // Clamped again here. The server clamps before it records, and this
            // holds the same line against a response that arrived from anywhere
            // else — a recommendation outside the observed prices is a number
            // with nothing behind it.
            let price = computed.clamped(draft.price)
            recommendedPrice = price
            priceRationale = sold.rationale(for: price, against: computed)
            listingTitle = draft.title.isEmpty ? nil : draft.title
            listingBody = draft.body.isEmpty ? nil : draft.body
            finish(.write, "Suggested \(computed.money(price))")
        } catch {
            guard !Task.isCancelled else { return }
            fail(.write, "Couldn't write the listing — the price below is the median of what's listed")
        }
        phase = .done
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

    /// States the count as well as the band.
    ///
    /// Without it the transcript reads "Found 15 nearby listings" then "Most
    /// are asking $55–$125", and the two lines look like they describe the
    /// same fifteen when the guide was built from fourteen — one was free, or
    /// sold, or had no readable price. Saying both numbers makes the drop
    /// visible instead of leaving a discrepancy for the user to find.
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
