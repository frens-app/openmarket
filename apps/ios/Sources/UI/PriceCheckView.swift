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
/// **The comparables used to sit above the recommendation**, on the argument
/// that they are the working rather than an illustration. They are below it
/// now, and the argument survives the move: the transcript already states the
/// working in the line above the price — how many listings were found, how many
/// sold, what band they were asking in. The claim "we went and looked" is made
/// by the checkmarks, before the number appears, which is what putting the
/// strips first was for.
///
/// What putting them first also did was bury the answer under two horizontal
/// scrollers on a phone. Somebody who wants to check the evidence scrolls; the
/// order now matches what they came for, and the strips are what backs it up
/// rather than what stands in front of it.
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

    /// **Two screens, not one scroll.**
    ///
    /// The old version stacked the question, the working and the answer in one
    /// column, which meant the inputs stayed on screen forever — a form asking
    /// "what are you selling?" above a price it had already worked out. Asking
    /// and answering are different moments, so they are different screens now,
    /// with the run itself as the third thing in between.
    var body: some View {
        Group {
            if model.hasResult {
                answer
            } else {
                question
            }
        }
        .navigationTitle("Price check")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { listing in
            DetailView(listing: listing, namespace: heroNamespace)
        }
        .navigationDestination(isPresented: $isShowingEvidence) { evidence }
        // Seeds the editable copy the moment a run produces it, and only then:
        // the fields own their text afterwards, so that a keystroke does not
        // fight a republish. Same reasoning as `SellerToolsModel.input`.
        .onChange(of: model.listingTitle) { _, title in editedTitle = title ?? "" }
        .onChange(of: model.listingBody) { _, body in editedBody = body ?? "" }
    }

    // MARK: - Asking

    /// One question, two ways to answer it, one button.
    ///
    /// The button is pinned rather than scrolled to, because on a phone the
    /// keyboard covers the bottom of the screen the moment somebody starts
    /// typing — and the button they need next was underneath it.
    private var question: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What are you selling?")
                            .font(.largeTitle.bold())
                        // The one line of instruction on the screen, and it is
                        // here rather than under a field because it answers the
                        // question somebody has before they touch anything:
                        // which of these two boxes do I have to fill in.
                        Text("A photo or a sentence is enough. Both is better.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)

                    photoStrip

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("Anything worth knowing")
                        descriptionField
                        // Not "this is optional" — the line above already said
                        // that. This says what to write, which is the more
                        // useful thing and the reason the field exists.
                        Text("Condition, age and what's included move the price most.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !model.steps.isEmpty { transcript }
                    if case .failed(let message) = model.phase { failureCard(message) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)

            runBar
        }
        // Tapping anywhere off the field puts the keyboard away. Simultaneous
        // rather than `onTapGesture` so it never competes with a control for
        // the same tap: they run their own action and the keyboard goes either
        // way.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isTyping = false })
    }

    private var descriptionField: some View {
        TextField("Weber Genesis II gas grill, three burners, cover included, grates need cleaning",
                  text: $draft,
                  axis: .vertical)
            .lineLimit(3...8)
            .textFieldStyle(.plain)
            .focused($isTyping)
            .submitLabel(.done)
            // A vertical-axis field treats Return as a newline and never calls
            // `onSubmit`, so Done is caught here: the newline that arrives is
            // the tap on the key, and it goes straight back out rather than
            // being left in the description.
            .onChange(of: draft) { _, text in
                guard text.contains("\n") else { return }
                draft = text.replacingOccurrences(of: "\n", with: " ")
                isTyping = false
                submit()
            }
            .padding(12)
            .frame(minHeight: 96, alignment: .topLeading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The button, and the promise underneath it.
    ///
    /// The second line is doing real work: this run takes the better part of
    /// ten seconds, most of it two page loads against Facebook, and a button
    /// that silently thinks for that long reads as broken. Saying where the
    /// numbers come from and roughly how long it takes turns a wait into a
    /// wait for something.
    private var runBar: some View {
        VStack(spacing: 8) {
            Button(action: submit) {
                HStack(spacing: 8) {
                    if model.phase.isRunning {
                        ProgressView().controlSize(.small).tint(.white)
                    }
                    Text(model.phase.isRunning ? "Checking the price…" : "Check the price")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.phase.isRunning || !canRun)

            Text("We read recent Marketplace sales near you. About ten seconds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        // Same tab-bar clearance as the answer screen, for the same reason —
        // here it is the reassurance line that would sit under the capsule.
        .padding(.bottom, 76)
        .background(.bar)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
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
                startOver
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
            if let preview = photos.first?.preview {
                preview
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.identifiedName ?? model.input)
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(photos.isEmpty ? "Read from what you wrote" : "Read from your photo and notes")
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
                sectionLabel("List it at")

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
                sectionLabel("Ready to paste")

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
private struct EditableCopyField: View {
    let caption: String
    @Binding var text: String
    /// Prose wraps and gets the smaller face; a title is one line at headline
    /// weight, which is roughly how Facebook renders it in a grid.
    let isProse: Bool
    /// Called with the copy, so the text that left is the text recorded.
    let onCopy: () -> Void

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                // A `TextField` rather than a `Text`, which is the whole
                // difference: the copy is a draft written from a photograph and
                // two lines of notes, and the seller knows the rest. Fixing it
                // here beats fixing it in Facebook, where a mistake is already
                // public.
                TextField(caption, text: $text, axis: .vertical)
                    .font(isProse ? .subheadline : .headline)
                    .textFieldStyle(.plain)
                    .lineLimit(isProse ? 2...8 : 1...3)
            }
            Button(action: copy) {
                Text(didCopy ? "Copied" : "Copy")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                    .contentTransition(.opacity)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "\(caption) copied" : "Copy \(caption.lowercased())")
        }
        .padding(14)
    }

    private func copy() {
        UIPasteboard.general.string = text
        onCopy()
        withAnimation(.easeOut(duration: 0.15)) { didCopy = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { didCopy = false }
        }
    }
}

/// A comparable at strip size: price first, because price is the only reason
/// this card is on the screen.
/// Internal rather than private: `PriceEvidenceView` draws the same card, and
/// two copies of a card that has to stay consistent with the price beside it is
/// how the two drift.
struct CompCard: View {
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
