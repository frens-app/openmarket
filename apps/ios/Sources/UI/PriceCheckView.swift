import PhotosUI
import SwiftUI
import UIKit

/// Price Check, the first tool in the Tools tab: describe what you're selling,
/// and get a price backed by what is actually listed nearby and what has
/// actually sold.
///
/// Pushed from `ToolsView`, so it brings no `NavigationStack` of its own — the
/// tab owns one, and a second would nest.
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
struct PriceCheckView: View {
    @EnvironmentObject private var model: SellerToolsModel
    /// The description being typed, held here rather than on the model — see
    /// `SellerToolsModel.input` for why the field must not be re-rendered from
    /// a `@Published` value while a run is publishing.
    @State private var draft = ""
    @FocusState private var isTyping: Bool
    @State private var selected: Listing?
    @Namespace private var heroNamespace

    /// The picker's selection, and what it resolved to.
    ///
    /// Single-selection, because the request accepts one photo. Going to
    /// several means the array-binding `PhotosPicker` and a `maxSelectionCount`
    /// here, plus raising the cap on the request — the wire field is already a
    /// list, so nothing about that is a migration.
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var photo: ItemPhoto?
    @State private var photoPreview: Image?
    @State private var isPreparingPhoto = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                prompt
                if !model.steps.isEmpty { transcript }
                if !model.comps.isEmpty { comparables }
                if !model.sold.isEmpty { recentlySold }
                if model.hasResult { priceField }
                if case .failed(let message) = model.phase { failureCard(message) }
                if model.phase == .done { helpfulPrompt }
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
        .navigationTitle("Price Check")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { listing in
            DetailView(listing: listing, namespace: heroNamespace)
        }
    }

    // MARK: - Asking

    /// Enough to go on: three characters of description, a photo, or both.
    ///
    /// Mirrors the `identify_item.needs_an_item` rule on the request, and the
    /// two are meant to agree — this one so the button is honest about whether
    /// it will work, that one because the server cannot trust a client.
    private var canRun: Bool {
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 || photo != nil
    }

    /// The one way a run starts, whether it came from the button or from Done.
    ///
    /// Guarded rather than trusting the caller: the button is disabled without
    /// enough to go on, and Done has no such thing — it is on the keyboard
    /// whatever the field holds.
    private func submit() {
        guard !model.phase.isRunning, canRun else { return }
        isTyping = false
        model.start(draft, photo: photo)
    }

    /// Downscales and encodes the picked photo off the main actor.
    ///
    /// A full-resolution phone photo is around 4000px on the long edge; scaling
    /// and JPEG-encoding it is tens of milliseconds of work, which is a visible
    /// stutter if it happens between a tap and the next frame. The preview is
    /// built from the prepared bytes rather than the original, so what is on
    /// screen is what will be sent.
    private func prepare(_ item: PhotosPickerItem?) async {
        guard let item else {
            photo = nil
            photoPreview = nil
            return
        }
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }

        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let prepared = await Task.detached(priority: .userInitiated, operation: {
                  ItemPhotoPreparer.prepare(image)
              }).value
        else {
            // Treated as "no photo" rather than surfaced. The run works on the
            // description alone, and refusing to price something because its
            // photo would not encode is the worse outcome.
            photo = nil
            photoPreview = nil
            return
        }
        photo = prepared
        photoPreview = UIImage(data: prepared.jpeg).map(Image.init(uiImage:))
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            // One line, and the only part of the old three that was not
            // already on screen: the market it will search. The Tools row said
            // what a price check is to get the user here, the button says what
            // it does, and the transcript shows the working as it happens —
            // explaining all of that again above the field is a paragraph the
            // user reads once and scrolls past forever after.
            //
            // No heading either. The navigation bar is already saying "Price
            // Check" two lines above this, and a title under a title reads as a
            // rendering mistake.
            Text("Checks what's listed and what's sold in \(model.marketName).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // The placeholder carries the rule, so nothing else has to. With no
            // photo it is an example of a good description; with one attached
            // it says the field is now optional and what it is still good for.
            // A line of copy explaining "either input will do" would be a line
            // of copy on a screen that just lost three of them, and it would be
            // on screen in both states to explain one of them.
            TextField(photo == nil
                        ? "A white IKEA Malm dresser, six drawers, a few scratches on top"
                        : "Optional — anything the photo doesn't show",
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

            photoRow

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
            .disabled(model.phase.isRunning || !canRun)
        }
    }

    /// The picker, and what it produced.
    ///
    /// Optional on purpose, and it says so: the run works on the description
    /// alone, so this is worded as something that improves the answer rather
    /// than something the screen is waiting for.
    @ViewBuilder
    private var photoRow: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickedPhoto, matching: .images) {
                HStack(spacing: 8) {
                    if isPreparingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: photo == nil ? "camera" : "checkmark.circle.fill")
                    }
                    Text(photo == nil ? "Add a photo" : "Change photo")
                        .font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(model.phase.isRunning)

            if let photoPreview {
                photoPreview
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(alignment: .topTrailing) { removePhotoButton }
            }
        }
        .onChange(of: pickedPhoto) { _, item in
            Task { await prepare(item) }
        }

        // Kept, shortened. The nudge earns its line: a photo is what separates
        // "dresser" from "IKEA Malm 6-drawer", and the run is measurably worse
        // without one. What it does not need is the joke it used to carry.
        if photo == nil {
            Text("Optional, but it identifies the item far better.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var removePhotoButton: some View {
        Button {
            pickedPhoto = nil
            photo = nil
            photoPreview = nil
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .padding(3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove photo")
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

    /// Both strips used to carry a caption, and most of what they said is still
    /// on screen: `PriceGuide.explanation` under the price says "N nearby
    /// asking prices…" and "N that sold were listed at…", which makes the
    /// asking-not-paid and listed-not-sold-for claims in the place the number
    /// is, where they bear on a decision. Saying them again in grey text under
    /// each strip was the screen repeating itself, and repetition is what gets
    /// skipped — eventually including the copy that matters.
    ///
    /// **One claim did not survive the cut**: that a list filtered on having
    /// sold cannot contain the things that didn't, so nothing here can show a
    /// price is too high. The prompt still tells the model (see
    /// `pricePrompt`), and `SoldSignal`'s own documentation still explains it,
    /// but no user-visible text makes that point now. If a seller ever reads
    /// "$100–$400 sold" as "$400 is achievable", this is the sentence that
    /// used to stand in the way, and the honest place to put it back is the
    /// explanation under the price rather than a caption on the strip.
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
        }
    }

    /// "Sold in ~4 days" — approximate, because it is. It was listed then and
    /// it is gone now; it may have gone in an hour.
    private func soldFootnote(_ comp: MarketComp) -> String? {
        guard let days = comp.daysListed else { return "Sold" }
        if days <= 1 { return "Sold within a day" }
        return "Sold in ~\(days) days"
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
            Text("Your listing")
                .font(.headline)
            if let price = model.recommendedPrice {
                CopyableField(caption: "PRICE",
                              // Labelled the way the comparables above are —
                              // "CA$80" beside a strip of CA$ cards, never "$80".
                              display: model.guide?.money(price) ?? "\(price)",
                              // Bare, because it is going into Facebook's price
                              // box, which wants a number.
                              copies: String(price),
                              footnote: model.priceRationale,
                              // The one signal worth collecting without asking.
                              // Copying the price is the action immediately
                              // before pasting it into Facebook, so it says
                              // "this worked" from everybody who gets this far
                              // — where the buttons below are answered by the
                              // few who stop to tap one.
                              onCopy: model.recordPriceCopied)
            }
            // Absent when the writing step failed, which leaves the price
            // standing on its own — it never depended on these.
            if let title = model.listingTitle {
                CopyableField(caption: "TITLE", display: title, copies: title)
            }
            if let body = model.listingBody {
                CopyableField(caption: "DESCRIPTION", display: body, copies: body, isProse: true)
            }
        }
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
            VStack(alignment: .leading, spacing: 10) {
                if let feedback = model.feedback {
                    Label(feedback ? "Thanks — glad it helped." : "Thanks — noted.",
                          systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Were these results helpful?")
                        .font(.subheadline)
                    HStack(spacing: 10) {
                        helpfulButton(title: "Yes", helpful: true)
                        helpfulButton(title: "No", helpful: false)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
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

    private func failureCard(_ message: String) -> some View {
        InlineNotice(text: message, actionTitle: "Try again") { model.start(draft, photo: photo) }
    }

    private var startOver: some View {
        Button("Start over", role: .destructive) {
            model.reset()
            draft = ""
            pickedPhoto = nil
            photo = nil
            photoPreview = nil
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
    /// Called on a successful copy. Nil where nobody is counting.
    var onCopy: (() -> Void)?

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
        onCopy?()
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
