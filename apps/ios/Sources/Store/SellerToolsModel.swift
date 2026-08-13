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
/// Everything learned from that version still holds (README, "The on-device
/// writer"), and none of it is prompted for any more — each one was designed
/// out instead:
///
/// * **The model cannot do arithmetic about its own evidence.** It is never
///   shown any. `PriceGuide` computes the numbers, picks the median, and
///   `PriceGuide.explanation` writes the sentence underneath.
/// * **It takes the item's identity from the comparables if it can see them.**
///   It cannot see one. The item is named and the listing is written from the
///   photo, in the only call there is, before any comparable exists.
/// * **Its answer needs clamping to the observed range.** Nothing needs
///   clamping: the recommendation is the median of the observed prices, so it
///   is inside the range by construction.
///
/// The run is four steps — identify, search, check what sold, read the prices —
/// and exactly one of them leaves this device to reach a model. The search
/// cannot move off the phone at all: it is a `WKWebView` against the user's own
/// Facebook session.
@MainActor
final class SellerToolsModel: ObservableObject {
    /// One line of the transcript.
    ///
    /// The work is four distinct things — understand, search, check what sold,
    /// price — and each takes long enough to be worth naming. A single spinner
    /// for the whole run would hide that the app went and looked at the actual
    /// market, which is the part worth trusting.
    struct Step: Identifiable, Equatable {
        // `write` was a fifth kind, for the model call that priced the item and
        // wrote the listing. The listing is written during `identify` now and
        // the price is arithmetic, so there is no step left to name.
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
    /// What we recommended: the median of what similar things are listed for.
    /// Fixed for the run, and the number the server records.
    @Published private(set) var recommendedPrice: Int?
    /// What the user settled on, which starts as the recommendation and moves
    /// when they use the stepper.
    ///
    /// **Kept separate from `recommendedPrice` rather than replacing it**, and
    /// the gap between the two is the most interesting number this feature can
    /// produce. "Sellers move our price up 20% on average" is the finding that
    /// says the median is the wrong statistic; overwriting the recommendation
    /// with the seller's edit would erase the evidence for it.
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

    /// The runs already done, newest first.
    ///
    /// **Read from the server, not remembered here.** The row has been written
    /// on every run since this feature existed — before the model is called, so
    /// that a run which dies is still countable — so a history was already in
    /// the database waiting to be read; the alternative would have been a
    /// second copy on the device, disagreeing with it after the first
    /// reinstall.
    ///
    /// Kept on this object rather than in the screen so it survives a tab
    /// switch, same reasoning as the result itself.
    @Published private(set) var recent: [PastPriceCheck] = []
    /// True only for the first load, so an empty list can tell "nothing yet"
    /// from "we haven't looked". A refresh behind an already-populated list is
    /// silent — nobody needs a spinner over rows they can already read.
    @Published private(set) var isLoadingRecent = false

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
        // Also sent to our own server, and the duplication is on purpose: that
        // row is joinable to the run it belongs to and is the record of what
        // this feature produced, while the event is joinable to everything else
        // the same person did that week. Neither can answer the other's
        // question, so both are kept.
        Analytics.capture(.priceCheckFeedbackSubmitted, [
            "helpful": helpful,
            "comps_found": comps.count,
            // Whether they had moved the number before judging it, which is the
            // difference between "your price was right" and "your price was
            // wrong and here is the one I fixed it to".
            "was_adjusted": askingPrice != recommendedPrice
        ])
    }

    /// Records that the price was copied, **and which price it was**.
    ///
    /// The signal worth having: copying the number is what somebody does right
    /// before pasting it into Facebook's price box, and it arrives from
    /// everybody rather than from the few who stop to answer a question.
    ///
    /// Now that the number is adjustable, what they copied is a different fact
    /// from what we recommended, and it is the better one — it is the price
    /// that goes on a real listing. Sending it beside a stored
    /// `recommended_price_minor` makes the gap queryable.
    func recordPriceCopied() {
        guard let priceCheckID else { return }
        let copied = askingPrice
        Task { await pricing.recordCopy(priceCheckID: priceCheckID, price: copied) }

        // The closest thing this app has to a conversion, so it carries both
        // numbers and the gap between them. "Sellers move our price up 20% on
        // average" is the finding that would say the median is the wrong
        // statistic, and it needs the recommendation and the copy side by side
        // — a percentage computed here rather than in six saved insights later.
        var properties: [String: Any] = [
            "source": Analytics.Surface.priceCheckRun.rawValue,
            "comps_found": comps.count,
            "sold_count": sold.count
        ]
        // So the conversion event reads on its own. Without it, "what kind of
        // thing gets priced and then actually listed" needs a join back to
        // `price_check_completed` on a session, which is three clicks nobody
        // makes when they are looking at a number that surprised them.
        properties["identified_name"] = Analytics.text(identifiedName)
        properties["search_term"] = Analytics.text(searchTerm?.lowercased())
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

        // The copy itself goes to our own server, which stores both versions
        // against the run and can diff them. What goes here is the verdict —
        // which field, and whether it was changed — plus the item's name so the
        // event reads without a join. Duplicating a whole listing body into a
        // second system buys nothing: the comparison that matters is *what the
        // model wrote versus what got pasted*, and only one of those two systems
        // holds both halves.
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

    /// The same three signals, from a run that finished some time ago.
    ///
    /// Separate from the two above only because it names its subject: those
    /// read `priceCheckID`, which is the run in progress, and a copy taken off
    /// the history screen belongs to a different row.
    ///
    /// Recorded rather than skipped, and it is arguably the better version of
    /// the signal: somebody who comes back a week later to copy the title again
    /// is telling us the copy was worth keeping, which no measurement taken
    /// thirty seconds after it was written can.
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

        // The same two events as a fresh run, distinguished only by `source`.
        // Deliberately not a third event name: "the price got copied" is one
        // question, and splitting it by name would mean every chart of it had
        // to remember to add the second one. Where it happened is a property.
        if let price {
            var properties: [String: Any] = [
                "source": Analytics.Surface.priceCheckHistory.rawValue,
                "asking_price": price,
                // Absent here rather than guessed: a stored run keeps the price
                // it recommended and not the range behind it, so there is no
                // adjustment to compute. The gap between recommended and copied
                // is a live-run measurement.
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

    // `reset()` stood here, and nothing calls it any more. It existed for the
    // "start over" button, which existed because the results replaced the input
    // screen — the run is a pushed screen now, so going back *is* the reset and
    // `start` already clears the previous results. Deleted rather than kept
    // "in case": an uncalled method that wipes the model is a thing somebody
    // wires to a button later without checking what it does to a running task.

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
        // Which of the two inputs people use is the question this feature was
        // built around — photo-only runs are the whole reason there is a vision
        // call — and the description is what says *what* they are selling. The
        // photos are not sent: they go to the identify call, they are stored
        // against that row, and they are megabytes.
        var started: [String: Any] = [
            "photo_count": photos.count,
            "has_description": !item.isEmpty,
            "description_length": item.count
        ]
        started["description"] = Analytics.text(item)
        Analytics.capture(.priceCheckStarted, started)

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
        begin(.identify, Self.identifyStepText(photoCount: photos.count))
        let term: String
        do {
            let identified = try await pricing.identify(description: item, photos: photos)
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
                reportFailure(.identify, reason: "no_query", startedAt: startedAt)
                return
            }
            term = query
            // The listing arrives here now, with the identification, because
            // both are read off the same photograph. Nothing later can improve
            // them and one thing later could poison them — see the note on
            // `IdentifiedItem` in the llm package.
            listingTitle = identified.listingTitle.isEmpty ? nil : identified.listingTitle
            listingBody = identified.listingBody.isEmpty ? nil : identified.listingBody
        } catch {
            guard !Task.isCancelled else { return }
            let message = Self.message(for: error)
            fail(.identify, message)
            phase = .failed(message)
            reportFailure(.identify, reason: Self.reason(for: error), startedAt: startedAt)
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
            reportFailure(.search, reason: Self.reason(for: error), startedAt: startedAt)
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

        // 4 — arithmetic, in Swift, instantly, and this is the answer.
        //
        // There used to be a fifth step here that sent all of this to a model
        // and asked it for a number. It is gone, and the reason is in the
        // table: on runs where the seller wrote nothing about condition it
        // returned this median, four seconds and thirteen hundred tokens later.
        // Where they did write something it moved ±10–20%, which is a judgement
        // this screen is not in a position to check and the user is — they can
        // see the whole range and the middle half a few points up.
        begin(.price, "Reading the prices")
        let computed = PriceGuide(comps: comps)
        guide = computed
        guard let median = computed.median else {
            fail(.price, "None of them had a price to compare")
            phase = .done
            // Completed, not failed, and the app agrees — `phase` is `.done`.
            // The run went all the way to the market and found comparables with
            // no readable price on any of them, which is a fact about the
            // listings rather than a fault. It still leaves the user with no
            // number, so it has to be countable apart from a run that produced
            // one: `has_price` is the split.
            reportCompletion(startedAt: startedAt, price: nil)
            return
        }
        recommendedPrice = median
        askingPrice = median
        priceRationale = sold.rationale(for: median, against: computed)
        finish(.price, "\(Self.summary(of: computed)) — suggesting \(computed.money(median))")

        phase = .done
        reportCompletion(startedAt: startedAt, price: median)

        // 5 — the row, after the screen is already finished.
        //
        // Deliberately last and deliberately unawaited-for: this call returns
        // nothing the user is waiting on, so making them watch it would be
        // making them wait on bookkeeping. A failure loses one row of telemetry
        // and nothing else, which is why it is swallowed rather than shown.
        await record(compsFound: comps.count, price: median, guide: computed)

        // The row this run just wrote is the one the input screen is about to
        // show at the top of its list, so it is fetched now rather than when
        // that screen reappears — the user is still reading the answer, and the
        // list is populated by the time they press Back.
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

    /// A run that reached an answer, with what it took to get there.
    ///
    /// The four steps are four chances to come back with nothing, and each one
    /// is a different problem: no comparables is a thin market, no sold history
    /// is a slow one, no price on any of them is a parsing question. Counting
    /// them together with the duration is what makes it possible to say which
    /// of the four is worth working on.
    ///
    /// `identified_name` and `search_term` are the two strings worth having and
    /// the reason is the same for both: the model turns "grill, needs cleaning"
    /// into "Weber Genesis II" and then searches for something else again, and
    /// when a price comes back wrong that chain is where it went wrong. They are
    /// checkable on screen by the person holding the object, which is exactly
    /// what makes them worth checking in aggregate afterwards.
    private func reportCompletion(startedAt: Date, price: Int?) {
        var properties: [String: Any] = [
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000),
            "photo_count": photoCount,
            "comps_found": comps.count,
            "sold_count": sold.count,
            "has_price": price != nil,
            // Whether there is anything to paste. The listing copy is written
            // during the identify call, so it can be absent on a run that
            // priced perfectly well — and a price with no words is half the
            // feature.
            "has_listing_copy": listingTitle != nil || listingBody != nil
        ]
        // Omitted rather than sent as zero when there is no price. A run that
        // found no market did not recommend $0, and an average over a column
        // padded with zeroes is worse than an average over fewer rows.
        if let price { properties["recommended_price"] = price }
        properties["description"] = Analytics.text(input)
        properties["identified_name"] = Analytics.text(identifiedName)
        properties["search_term"] = Analytics.text(searchTerm?.lowercased())
        Analytics.capture(.priceCheckCompleted, properties)
    }

    /// A run that stopped, and where.
    ///
    /// `step` is the load-bearing property: identify failing is a server or a
    /// photograph, search failing is Facebook, and the two have nothing to do
    /// with each other. `reason` is a fixed code rather than the sentence shown
    /// on screen, because that sentence can carry text the server wrote and is
    /// meant to be read once by one person, not grouped on.
    private func reportFailure(_ step: Step.Kind, reason: String, startedAt: Date) {
        var properties: [String: Any] = [
            "step": Self.name(of: step),
            "reason": reason,
            "photo_count": photoCount,
            "duration_ms": Int(Date().timeIntervalSince(startedAt) * 1000)
        ]
        // What was asked, and — on anything past `identify` — what it was turned
        // into. A `nothing_found` on the search step is the interesting failure
        // and it is unreadable without the query: "no market for this" and "we
        // searched for the wrong thing" look identical from the step name alone.
        properties["description"] = Analytics.text(input)
        properties["identified_name"] = Analytics.text(identifiedName)
        properties["search_term"] = Analytics.text(searchTerm?.lowercased())
        Analytics.capture(.priceCheckFailed, properties)
    }

    /// How many photos the run in flight was given.
    ///
    /// Held because there is nowhere else to read it from by the time a run
    /// ends: `PriceCheckView` empties its strip on submit, and the photos
    /// themselves are handed to the request and not kept. Whether a photo-only
    /// run works as well as a described one is the question this feature's
    /// design rests on, so the count has to survive to the event that answers
    /// it.
    private var photoCount = 0

    private static func name(of step: Step.Kind) -> String {
        switch step {
        case .identify: return "identify"
        case .search: return "search"
        case .sold: return "sold"
        case .price: return "price"
        }
    }

    /// A stable code for a server failure. Deliberately coarse: this exists to
    /// separate "our server is unwell" from "the caller sent something it
    /// shouldn't have", and any finer grain belongs in the server's own logs
    /// where the request is.
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
    ///
    /// Named for what the app is doing rather than for how long it takes: this
    /// line is on screen for the four or five seconds the model call takes, and
    /// "Looking at your photos" is a claim the user can check against what they
    /// attached.
    static func identifyStepText(photoCount: Int) -> String {
        switch photoCount {
        case 0: "Working out what you're selling"
        case 1: "Looking at your photo"
        default: "Looking at your \(photoCount) photos"
        }
    }

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
