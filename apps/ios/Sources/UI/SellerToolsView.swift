import SwiftUI
import UIKit

/// The Seller tab: describe what you're selling, and get a price backed by what
/// is actually listed nearby and what has actually sold.
///
/// The screen is built as a **transcript** rather than a form that fills in.
/// Four things happen — a search term is worked out, the market is searched,
/// the sold listings are checked, the prices are read — and they take a few
/// seconds between them. Naming each one as it happens is not decoration: the
/// claim this feature makes is "this price comes from real listings near you",
/// and a spinner followed by a number asks the user to take that on faith.
/// Watching it go and look is the evidence.
///
/// The comparables are on screen *above* the recommendation for the same
/// reason. They are the working, not an illustration.
struct SellerToolsView: View {
    @EnvironmentObject private var model: SellerToolsModel
    /// The description being typed, held here rather than on the model — see
    /// `SellerToolsModel.input` for why the field must not be re-rendered from
    /// a `@Published` value while a run is publishing.
    @State private var draft = ""
    @FocusState private var isTyping: Bool
    @State private var selected: Listing?
    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    prompt
                    if !model.steps.isEmpty { transcript }
                    if !model.comps.isEmpty { comparables }
                    if !model.sold.isEmpty { recentlySold }
                    if model.hasResult { priceField }
                    if case .failed(let message) = model.phase { failureCard(message) }
                    if model.phase == .done { startOver }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 60)
            }
            .scrollDismissesKeyboard(.interactively)
            // Dragging already puts the keyboard away; tapping off the field
            // should too, and on a phone most of this screen is "off the
            // field" — the transcript and both comparable strips arrive
            // underneath the keyboard, so a keyboard that only leaves on a
            // drag is a keyboard sitting on top of the answer.
            //
            // Simultaneous rather than `onTapGesture`, so it never competes
            // with the button or the cards for the same tap: they run their
            // own action and the keyboard goes away either way.
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { isTyping = false })
            .navigationTitle("Seller")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: heroNamespace)
            }
        }
    }

    // MARK: - Asking

    /// The one way a run starts, whether it came from the button or from Done.
    ///
    /// Guarded rather than trusting the caller: the button is disabled below
    /// three characters, and Done has no such thing — it is on the keyboard
    /// whatever the field holds.
    private func submit() {
        guard !model.phase.isRunning,
              draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3
        else { return }
        isTyping = false
        model.start(draft)
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Seller Tools", systemImage: "tag")
                    .font(.title3.weight(.semibold))
                Text("Describe what you're selling. This looks at what similar things are listed for in \(model.marketName), and what's actually sold there lately, then works out what to ask.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("A white IKEA Malm dresser, six drawers, a few scratches on top",
                      text: $draft,
                      axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .focused($isTyping)
                .submitLabel(.done)
                // A vertical-axis field treats Return as a newline and never
                // calls `onSubmit`, so Done is caught here: the newline that
                // arrives is the tap on the key, and it goes back out again
                // rather than being left in the description.
                //
                // Same three things the button does, in the same order, so
                // Done and the button cannot drift apart.
                .onChange(of: draft) { _, text in
                    guard text.contains("\n") else { return }
                    draft = text.replacingOccurrences(of: "\n", with: " ")
                    // Down either way. Done on a description too short to
                    // search is still the user saying they're finished
                    // typing, and leaving the keyboard up would ignore that.
                    isTyping = false
                    submit()
                }
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))

            Button(action: submit) {
                HStack(spacing: 8) {
                    if model.phase.isRunning {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(model.phase.isRunning ? "Analysing the market…" : "Analyse the market")
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase.isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
        }
    }

    // MARK: - The transcript

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(model.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    marker(for: step.state)
                        .frame(width: 16)
                    Text(step.text)
                        .font(.subheadline)
                        .foregroundStyle(step.state == .running ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func marker(for state: SellerToolsModel.Step.State) -> some View {
        switch state {
        case .running:
            ProgressView().controlSize(.mini)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.tint)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - The evidence

    private var comparables: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's listed nearby")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.comps) { comp in
                        CompCard(comp: comp)
                            .onTapGesture { selected = comp.listing }
                    }
                }
                .padding(.horizontal, 2)
            }
            // The single most important sentence on this screen. Everything
            // here is what sellers *want*, and Facebook never publishes what
            // buyers paid — so a "market price" built from it is a price the
            // market is being asked for, which is a weaker and different claim.
            Text("Asking prices in \(model.marketName) right now — what sellers want, not what anything sold for.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The half of the market the app has never been able to show.
    ///
    /// A default Marketplace search returns nothing that has sold — measured,
    /// 0 of 14 — so until now every listing this app has ever displayed was
    /// something still sitting unsold. These are the ones that went.
    ///
    /// Each card carries its own age rather than the strip carrying an average,
    /// because the age *is* the claim: this was listed four days ago and it is
    /// gone, so it sold in at most four days.
    private var recentlySold: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recently sold nearby")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.sold.comps) { comp in
                        CompCard(comp: comp, footnote: soldFootnote(comp))
                            .onTapGesture { selected = comp.listing }
                    }
                }
                .padding(.horizontal, 2)
            }
            // The two caveats that keep this honest, and neither is optional.
            // Facebook publishes what a sold item was *listed* at, never what
            // it went for; and a list filtered on having sold cannot contain
            // the things that didn't.
            Text("Listed prices, not what they went for — Facebook doesn't publish that. Things that didn't sell aren't here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "Sold in ≤4 days" — the bound, stated as a bound. It was listed then and
    /// it is gone now; it may have gone in an hour.
    private func soldFootnote(_ comp: MarketComp) -> String? {
        guard let days = comp.daysListed else { return "Sold" }
        if days <= 1 { return "Sold within a day" }
        return "Sold in ≤\(days) days"
    }

    // MARK: - The answer

    /// One field, because there is one answer.
    ///
    /// This used to sit under a "Your listing" heading beside a generated title
    /// and description. Those are gone with the on-device model
    /// (`SellerToolsModel`), and the price was always the part the market
    /// evidence actually supported — the strips above are its working.
    private var priceField: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What to ask")
                .font(.headline)
            if let price = model.recommendedPrice {
                CopyableField(caption: "PRICE",
                              // Labelled the way the comparables above are —
                              // "CA$80" beside a strip of CA$ cards, never "$80".
                              display: model.guide?.money(price) ?? "\(price)",
                              // Bare, because it is going into Facebook's price
                              // box, which wants a number.
                              copies: String(price),
                              footnote: model.priceRationale)
            }
        }
    }

    // MARK: - Endings

    private func failureCard(_ message: String) -> some View {
        InlineNotice(text: message, actionTitle: "Try again") { model.start(draft) }
    }

    private var startOver: some View {
        Button("Start over", role: .destructive) {
            model.reset()
            draft = ""
        }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
    }
}

/// A field the user is going to paste somewhere else, so copying is the
/// primary action rather than a long-press away.
private struct CopyableField: View {
    let caption: String
    let display: String
    let copies: String
    var footnote: String?
    var isProse = false

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(caption)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(display)
                        .font(isProse ? .subheadline : .headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button(action: copy) {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .font(.subheadline)
                        .frame(width: 34, height: 34)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopy ? "\(caption) copied" : "Copy \(caption.lowercased())")
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func copy() {
        UIPasteboard.general.string = copies
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

/// A comparable at strip size: price first, because price is the only reason
/// this card is on the screen.
private struct CompCard: View {
    let comp: MarketComp
    /// Shown under the title on the sold strip, where how fast it went is the
    /// whole reason the card is there. Nil on the active strip.
    var footnote: String?

    private static let side: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color(.tertiarySystemFill)
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    RemoteImage(url: comp.listing.thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.hasFailed {
                            MissingPhoto()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    if comp.isSold { soldTag }
                }
            Text(comp.listing.priceText ?? "—")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(comp.isSold ? .secondary : .primary)
            if let title = comp.listing.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            if let footnote {
                Text(footnote)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Marked, not hidden. A sold listing is still worth seeing — it just isn't
    /// worth counting, and `PriceGuide` leaves it out of the arithmetic.
    private var soldTag: some View {
        Text("Sold")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.thinMaterial, in: Capsule())
            .padding(6)
    }
}
