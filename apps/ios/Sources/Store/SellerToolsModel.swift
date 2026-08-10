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
/// **There was a writing step here, and it is gone for now.** Apple's on-device
/// model named the item, chose a price inside the measured band and drafted a
/// description. It worked — verified against the real model — but not anywhere
/// it could be relied on: `SystemLanguageModel.availability` reports
/// `.available` on the strength of Apple Intelligence being switched on, and
/// then generation fails if the 3B asset isn't actually installed. That is the
/// permanent state of the iOS simulator, whose model assets all carry
/// `version: (none)` with `update available false`, so the whole feature
/// degraded to an apology on the machine it gets developed on.
///
/// What is left is the part that never needed a model: the market search, the
/// arithmetic, and the price. That was always the load-bearing half — every
/// number was Swift's already, and the model only chose a point inside a range
/// Swift computed and held it there. Removing it costs the title and the
/// description and nothing else.
///
/// The implementation and its measured prompts are in commit `1c54a9f`, and
/// what was learned from them is written up in the README rather than left in
/// the history: four narrow calls beat one wide one, the model cannot do
/// arithmetic about evidence it was just shown, and every push for richer prose
/// made it invent condition the seller never described.
@MainActor
final class SellerToolsModel: ObservableObject {
    /// One line of the transcript.
    ///
    /// The work is four distinct things — understand, search, check what sold,
    /// price — and each takes long enough to be worth naming. A single spinner
    /// for the whole run would hide that the app went and looked at the actual
    /// market, which is the part worth trusting.
    struct Step: Identifiable, Equatable {
        enum Kind: Hashable { case understand, search, sold, price }
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

    private let search: ComparableSearch
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

    init(search: ComparableSearch? = nil, prefs: Preferences = .shared) {
        self.search = search ?? ComparableSearch()
        self.prefs = prefs
    }

    /// Where the comparables come from, for the screen to state up front.
    var marketName: String { prefs.locationName ?? "your area" }

    var hasResult: Bool { recommendedPrice != nil }

    // MARK: - The run

    func start(_ text: String) {
        let item = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.count >= 3 else { return }
        input = item
        task?.cancel()
        task = Task { await run(item) }
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
    }

    private func run(_ item: String) async {
        clearResults()
        phase = .running

        // 1 — what to search for.
        //
        // Separated from the search itself because it can be wrong in a way the
        // user can see and correct: "searching for ikea malm dresser" is
        // checkable, "found 14 listings" is not.
        let term = SearchTerm.from(item)
        searchTerm = term
        steps.append(Step(kind: .understand, text: "Searching for “\(term)”", state: .done))

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
        recommendedPrice = computed.median
        priceRationale = computed.median.map { sold.rationale(for: $0, against: computed) }
        if computed.median != nil {
            finish(.price, Self.summary(of: computed))
        } else {
            fail(.price, "None of them had a price to compare")
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
