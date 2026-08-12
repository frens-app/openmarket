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

    /// Up to `maxPhotos`, in the order they were added.
    ///
    /// The library picker and the camera both land here, which is why this is
    /// the state rather than `PhotosPickerItem`s: a captured `UIImage` has no
    /// picker item, so a selection-shaped source of truth could only hold half
    /// of what the screen accepts.
    @State private var photos: [PreparedPhoto] = []
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var isPreparingPhoto = false
    @State private var isChoosingSource = false
    @State private var isChoosingFromLibrary = false
    @State private var isTakingPhoto = false

    /// Three, matching `max_items` on the request. Both numbers exist because
    /// the client should not be able to build a request the server refuses, and
    /// the server should not trust that it can't.
    private static let maxPhotos = 3

    /// A photo and the thumbnail for it, kept together because they are made
    /// together — the preview is rendered from the prepared bytes rather than
    /// the original, so what is on screen is exactly what will be sent.
    struct PreparedPhoto: Identifiable, Equatable {
        let id = UUID()
        let photo: ItemPhoto
        let preview: Image

        static func == (a: PreparedPhoto, b: PreparedPhoto) -> Bool { a.id == b.id }
    }

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
        draft.trimmingCharacters(in: .whitespacesAndNewlines).count >= 3 || !photos.isEmpty
    }

    private var canAddPhoto: Bool {
        photos.count < Self.maxPhotos && !model.phase.isRunning
    }

    /// The one way a run starts, whether it came from the button or from Done.
    ///
    /// Guarded rather than trusting the caller: the button is disabled without
    /// enough to go on, and Done has no such thing — it is on the keyboard
    /// whatever the field holds.
    private func submit() {
        guard !model.phase.isRunning, canRun else { return }
        isTyping = false
        model.start(draft, photos: photos.map(\.photo))
    }

    /// Downscales and encodes off the main actor, then appends.
    ///
    /// A full-resolution phone photo is around 4000px on the long edge; scaling
    /// and JPEG-encoding it is tens of milliseconds of work, which is a visible
    /// stutter if it happens between a tap and the next frame — and three of
    /// them at once is three times that.
    ///
    /// A photo that will not encode is dropped silently rather than surfaced.
    /// The run works without it, and refusing to price something because one of
    /// its pictures would not compress is the worse outcome.
    private func add(_ image: UIImage) async {
        guard photos.count < Self.maxPhotos else { return }
        isPreparingPhoto = true
        defer { isPreparingPhoto = false }

        guard let prepared = await Task.detached(priority: .userInitiated, operation: {
            ItemPhotoPreparer.prepare(image)
        }).value,
            let preview = UIImage(data: prepared.jpeg)
        else { return }

        photos.append(PreparedPhoto(photo: prepared, preview: Image(uiImage: preview)))
    }

    /// Loads whatever the library picker handed back, in the order picked.
    ///
    /// The selection is cleared afterwards so the picker opens empty next time:
    /// leaving it set would show the previous choice pre-ticked, and unticking
    /// it there would not remove the thumbnail here — two views of one list,
    /// disagreeing.
    private func load(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard photos.count < Self.maxPhotos else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else { continue }
            await add(image)
        }
        pickerSelection = []
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            photoStrip

            // The placeholder is the only instruction on this screen. It names
            // the four things worth typing, which is what the removed paragraph
            // was for, and it disappears the moment somebody starts typing —
            // where a caption stays on screen forever explaining a field that
            // is already full.
            TextField("Description — condition, brand, issues",
                      text: $draft,
                      axis: .vertical)
                .lineLimit(2...6)
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
            .disabled(model.phase.isRunning || !canRun)
        }
    }

    // MARK: - Photos

    /// The photos, at the top, sized to be the first thing on the screen.
    ///
    /// It used to be a full-width button with the thumbnail hung off the end of
    /// it and a caption underneath calling itself optional — which read as a
    /// setting rather than as the main input. It is still optional; a run works
    /// on the description alone. But a photo is what separates "dresser" from
    /// "IKEA Malm 6-drawer", so it is drawn like the thing to do and left empty
    /// without comment, rather than labelled as skippable.
    ///
    /// The tiles are all one size and sit in a row, so one photo and three are
    /// the same layout rather than two designs. The add tile is the last of
    /// them and disappears at `maxPhotos` — a full set needs no empty slot, and
    /// a disabled one would be a control that says no.
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(photos) { entry in
                    entry.preview
                        .resizable()
                        .scaledToFill()
                        .frame(width: Self.tile, height: Self.tile)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .topTrailing) { removeButton(for: entry) }
                }

                if canAddPhoto { addTile }
            }
            // Room for the remove buttons, which overhang the tiles.
            .padding(.vertical, 4)
            .padding(.horizontal, 2)
        }
        .animation(.easeOut(duration: 0.2), value: photos)
    }

    private static let tile: CGFloat = 104

    /// Library and camera in one tile.
    ///
    /// One tile with a choice behind it, rather than two side by side: two
    /// buttons is a decision to make before the interesting one, and the tile
    /// is meant to read as "put a picture here".
    ///
    /// **The choice is a `confirmationDialog`, and both pickers are presented
    /// by modifiers.** The obvious version — a `Menu` containing a
    /// `PhotosPicker` — builds and runs and does nothing: choosing the item
    /// dismisses the menu, and the picker's presentation goes with the view
    /// that was hosting it. So the menu items only set state, and the sheets
    /// hang off the tile where nothing is about to disappear underneath them.
    ///
    /// The camera item is absent rather than disabled where there is no camera.
    /// A disabled control is a control that says no; an absent one is a device
    /// that never offered.
    @ViewBuilder
    private var addTile: some View {
        Button {
            // Straight to the library when that is the only option, because a
            // one-item menu is a tap that asks permission to do the only thing
            // it can do.
            if CameraPicker.isAvailable {
                isChoosingSource = true
            } else {
                isChoosingFromLibrary = true
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(.secondarySystemBackground))
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(.separator), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                if isPreparingPhoto {
                    ProgressView()
                } else {
                    Image(systemName: photos.isEmpty ? "camera.fill" : "plus")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.tile, height: Self.tile)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photos.isEmpty ? "Add a photo" : "Add another photo")
        .confirmationDialog("Add a photo", isPresented: $isChoosingSource, titleVisibility: .hidden) {
            Button("Take Photo") { isTakingPhoto = true }
            Button("Choose Photo") { isChoosingFromLibrary = true }
        }
        .photosPicker(isPresented: $isChoosingFromLibrary,
                      selection: $pickerSelection,
                      maxSelectionCount: Self.maxPhotos - photos.count,
                      matching: .images)
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            Task { await load(items) }
        }
        .sheet(isPresented: $isTakingPhoto) {
            CameraPicker { image in
                Task { await add(image) }
            }
            .ignoresSafeArea()
        }
    }

    private func removeButton(for entry: PreparedPhoto) -> some View {
        Button {
            photos.removeAll { $0.id == entry.id }
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.55))
                .padding(5)
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
        // Retries with the same inputs, photos included — a failed run is
        // usually a network or a provider having a moment, and making somebody
        // re-attach three photographs to find that out would be its own defeat.
        InlineNotice(text: message, actionTitle: "Try again") { submit() }
    }

    private var startOver: some View {
        Button("Start over", role: .destructive) {
            model.reset()
            draft = ""
            photos = []
            pickerSelection = []
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
