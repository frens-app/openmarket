import SwiftUI
import UIKit

/// The run, and then the answer.
///
/// **Pushed rather than swapped in**, which is what let "start over" go. That
/// button existed because the previous version replaced the input screen with
/// its own results, so the navigation stack stopped describing where the user
/// was and a control had to stand in for Back. Here Back already means "change
/// what I asked": `PriceCheckView` is still on the stack behind this, photos
/// and description intact, and running again is an edit rather than a restart.
///
/// While it runs this is a **transcript**. Four things happen — the item is
/// identified, the market is searched, the sold listings are checked, the prices
/// are read — and they take a few seconds between them. Naming each as it
/// happens is not decoration: the claim this feature makes is "this price comes
/// from real listings near you", and a spinner followed by a number asks the
/// user to take that on faith. Watching it go and look is the evidence.
///
/// When it finishes the transcript is replaced rather than kept. It was
/// progress, and progress that has finished is just a receipt above the answer.
struct PriceCheckRunView: View {
    @EnvironmentObject private var model: SellerToolsModel
    /// The first photo, passed down rather than re-derived: this screen shows it
    /// beside the identification and has no picker of its own.
    let thumbnail: Image?

    @State private var selected: Listing?
    @Namespace private var heroNamespace
    @State private var isShowingEvidence = false

    /// The listing, as the user may have rewritten it.
    ///
    /// Held here rather than on the model for the reason `SellerToolsModel.input`
    /// documents: a `TextField` re-rendered from a `@Published` value mid-edit
    /// loses an uncommitted autocorrect composition, and hands back the marked
    /// substring doubled. Seeded once when the run produces copy; theirs after
    /// that.
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var didCopyPrice = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.hasResult {
                answer
            } else {
                progress
            }
        }
        .navigationTitle(model.hasResult ? "Price check" : "Checking…")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { listing in
            DetailView(listing: listing, namespace: heroNamespace)
        }
        .navigationDestination(isPresented: $isShowingEvidence) { evidence }
        // Seeds the editable copy the moment the run produces it, and only
        // then: the fields own their text afterwards, so a keystroke does not
        // fight a republish.
        .onChange(of: model.listingTitle) { _, title in editedTitle = title ?? "" }
        .onChange(of: model.listingBody) { _, body in editedBody = body ?? "" }
        .onAppear { editedTitle = model.listingTitle ?? ""; editedBody = model.listingBody ?? "" }
    }

    // MARK: - Running

    /// What is happening, while it happens.
    ///
    /// Top-aligned rather than centred: the steps arrive one at a time and a
    /// vertically-centred stack would shuffle every line down the screen each
    /// time one appeared.
    private var progress: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                transcript
                if case .failed(let message) = model.phase { failureCard(message) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 96)
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

    // MARK: - The answer

    /// The decision, then the paste.
    ///
    /// Everything above the "ready to paste" label is one question — what do I
    /// ask for this — and it is answerable without scrolling: the number, what
    /// the number means, and where it sits against everyone else. Everything
    /// below it is clerical.
    private var answer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                identifiedHeader
                priceBlock
                evidenceRow
                listingBlock
                helpfulPrompt
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Clears the floating tab bar, which is an overlay rather than a
            // safe-area inset — so nothing reserves this space and the last
            // control on any screen sits underneath it. Measured against the
            // capsule, not guessed.
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    /// What it decided this is, and where it got that.
    ///
    /// Small and at the top, because it is the one thing on the screen the
    /// person holding the object can check better than the app can — and a
    /// price for the wrong item is worse than no price. It replaces the
    /// transcript, which said the same thing at four times the height and only
    /// mattered while the run was going.
    @ViewBuilder
    private var identifiedHeader: some View {
        HStack(spacing: 12) {
            if let thumbnail {
                thumbnail
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.identifiedName ?? model.input)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(thumbnail == nil ? "Read from what you wrote" : "Read from your photo and notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    /// The number, the stepper, the sentence, and the bar.
    ///
    /// **The stepper is the point.** The recommendation is a median, which is a
    /// statement about other people's listings rather than about this object,
    /// and the person holding it knows things the median cannot — that it is
    /// boxed, or that the drawer sticks. Letting them move it and rewriting the
    /// sentence as they do turns a number handed down into a number chosen,
    /// with the consequences visible while they choose.
    @ViewBuilder
    private var priceBlock: some View {
        if let price = model.askingPrice, let guide = model.guide {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("List it at")

                HStack(alignment: .center, spacing: 12) {
                    // The number is the copy button.
                    //
                    // The design sketch had no control here, and a seller can
                    // certainly type "150" — but copying the price is the one
                    // signal this feature gets from everybody rather than from
                    // the few who answer a question, and it is what tells us
                    // whether the recommendation is any good. So the affordance
                    // stays; it is the number itself plus a small glyph rather
                    // than a third button crowding the stepper.
                    Button(action: copyPrice) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(guide.money(price))
                                .font(.system(size: 52, weight: .bold, design: .rounded))
                                .minimumScaleFactor(0.5)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.15), value: price)
                            Image(systemName: didCopyPrice ? "checkmark" : "doc.on.doc")
                                .font(.footnote)
                                .foregroundStyle(didCopyPrice ? Color.accentColor : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(didCopyPrice ? "Price copied" : "Copy price")
                    Spacer(minLength: 8)
                    stepButton(systemName: "minus", direction: -1)
                    stepButton(systemName: "plus", direction: 1)
                }

                if let sentence = priceSentence(for: price, guide: guide) {
                    Text(sentence)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }

                PriceRangeBar(price: price, guide: guide)
            }
        }
    }

    /// Two short sentences: where it sits, and how fast things like it go.
    ///
    /// Both are arithmetic written in Swift — see `PriceGuide.position` for why
    /// the long form moved to the evidence screen, and `SoldSignal.speed` for
    /// why "about two weeks" beats "13 days".
    private func priceSentence(for price: Int, guide: PriceGuide) -> String? {
        let parts = [guide.position(for: price), model.sold.speed].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Copies the bare number — Facebook's price box wants digits, not "$150".
    private func copyPrice() {
        guard let price = model.askingPrice else { return }
        UIPasteboard.general.string = String(price)
        model.recordPriceCopied()
        withAnimation(.easeOut(duration: 0.15)) { didCopyPrice = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { didCopyPrice = false }
        }
    }

    private func stepButton(systemName: String, direction: Int) -> some View {
        Button {
            model.nudgePrice(by: direction)
        } label: {
            Image(systemName: systemName)
                .font(.headline)
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemBackground), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!model.canNudge(direction))
        .accessibilityLabel(direction > 0 ? "Increase price" : "Decrease price")
    }

    /// The comparables, one tap away.
    ///
    /// It states the counts on its face rather than only behind the chevron,
    /// because the counts are the claim — "10 nearby listings · 15 sold last
    /// month" is what makes the number above it something other than a guess,
    /// and a row that made you tap to find that out would be hiding the part
    /// that matters to keep the part that is merely interesting.
    @ViewBuilder
    private var evidenceRow: some View {
        if !model.comps.isEmpty {
            Button {
                isShowingEvidence = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("What this is based on")
                            .font(.subheadline.weight(.semibold))
                        Text(evidenceSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
    }

    private var evidenceSummary: String {
        var parts = ["\(model.comps.count) nearby listing\(model.comps.count == 1 ? "" : "s")"]
        if model.sold.count > 0 {
            parts.append("\(model.sold.count) sold last month")
        }
        return parts.joined(separator: " · ")
    }

    /// The listing, editable before it is copied.
    ///
    /// Editable because the model wrote it from a photograph and two lines of
    /// notes, and the seller knows the rest. Making them paste it into Facebook
    /// and fix it there means fixing it in the one place where a mistake is
    /// already public.
    @ViewBuilder
    private var listingBlock: some View {
        if model.listingTitle != nil || model.listingBody != nil {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Ready to paste")

                VStack(spacing: 0) {
                    if model.listingTitle != nil {
                        EditableCopyField(caption: "Title", text: $editedTitle, isProse: false) {
                            model.recordListingCopied(title: editedTitle)
                        }
                        Divider().padding(.leading, 14)
                    }
                    if model.listingBody != nil {
                        EditableCopyField(caption: "Description", text: $editedBody, isProse: true) {
                            model.recordListingCopied(description: editedBody)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))

                Text("Tap a field to rewrite it before you copy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var evidence: some View {
        PriceEvidenceView(comps: model.comps,
                          sold: model.sold,
                          guide: model.guide ?? PriceGuide(comps: []),
                          price: model.askingPrice ?? model.recommendedPrice ?? 0,
                          marketName: model.marketName,
                          searchTerm: model.searchTerm)
    }

    /// The asked question, once there is something to judge.
    ///
    /// Two buttons rather than a checkbox, and that is the same distinction the
    /// column behind it makes: a checkbox cannot tell "no" from "didn't
    /// answer", and those are different findings. Answering swaps the prompt
    /// for an acknowledgement rather than leaving a live control that has
    /// already been used.
    @ViewBuilder
    private var helpfulPrompt: some View {
        if model.hasResult {
            // One row rather than a stacked question: it is the last thing on
            // the screen and the least important, and a two-line block there
            // reads as another section to deal with.
            HStack(spacing: 10) {
                if let feedback = model.feedback {
                    Label(feedback ? "Thanks — glad it helped." : "Thanks — noted.",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    Text("Was this price helpful?")
                        .font(.subheadline)
                    Spacer(minLength: 8)
                    helpfulButton(title: "Yes", helpful: true)
                    helpfulButton(title: "No", helpful: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .animation(.easeOut(duration: 0.2), value: model.feedback)
        }
    }

    private func helpfulButton(title: String, helpful: Bool) -> some View {
        Button(title) { model.recordFeedback(helpful: helpful) }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.bordered)
    }

    // MARK: - Endings

    /// A failed run offers the way back rather than a retry in place.
    ///
    /// The inputs live on the previous screen and this one cannot resubmit
    /// them. Sending somebody back to a field that still holds everything they
    /// typed is one tap and no lost work — and most failures here are worth
    /// changing something about anyway, which is exactly what that screen is
    /// for.
    private func failureCard(_ message: String) -> some View {
        InlineNotice(text: message, actionTitle: "Go back") { dismiss() }
    }
}
