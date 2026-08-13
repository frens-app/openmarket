import PhotosUI
import SwiftUI
import UIKit

/// Price Check, the first tool in the Tools tab: **the question half**.
///
/// Photos, a description, and a button. Running the check pushes
/// `PriceCheckRunView`, which is where the working and the answer live.
///
/// **A push rather than a swap**, and the back button is the whole reason. This
/// screen used to replace itself with its own results, which left "start over"
/// as the only way back to the inputs — a button that had to exist because the
/// navigation stack no longer described where the user was. Pushing means Back
/// already means "change what I asked", the inputs are still standing behind
/// it, and a second run is an edit rather than a re-entry.
///
/// Pushed from `ToolsView`, so it brings no `NavigationStack` of its own — the
/// tab owns one, and a second would nest.
struct PriceCheckView: View {
    @EnvironmentObject private var model: SellerToolsModel
    /// The description being typed, held here rather than on the model — see
    /// `SellerToolsModel.input` for why the field must not be re-rendered from
    /// a `@Published` value while a run is publishing.
    @State private var draft = ""
    @FocusState private var isTyping: Bool

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
    @State private var isRunning = false
    /// A past run being read. Separate from `isRunning` because they are
    /// different destinations, not two states of one.
    @State private var selectedPast: PastPriceCheck?

    /// The first photo of the run in progress, held here because the strip it
    /// came from is cleared the moment the run starts. `PriceCheckRunView`
    /// shows it beside the identification and has no picker of its own.
    @State private var runThumbnail: Image?

    /// What was submitted, kept only until the run either succeeds or doesn't.
    ///
    /// Clearing the form on submit is right for the ordinary case — the answer
    /// is on the next screen and coming back to a stale copy of the question is
    /// clutter. It is wrong for the failed one: "couldn't reach the server" and
    /// an empty form together means retyping the description and re-picking
    /// three photos to try again. So the inputs are put back when the run
    /// failed, and only then.
    @State private var submitted: (draft: String, photos: [PreparedPhoto])?

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
        question
            .navigationTitle("Price check")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $isRunning) {
                PriceCheckRunView(thumbnail: runThumbnail)
            }
            .navigationDestination(item: $selectedPast) { PastPriceCheckView(check: $0) }
            // Fetched once when the screen appears, and again whenever a run
            // ends — `SellerToolsModel` refreshes the list itself as the last
            // thing a successful run does, so by the time Back lands the new row
            // is already at the top.
            .task { await model.loadRecent() }
            .onChange(of: isRunning) { _, running in
                guard !running else { return }
                restoreIfRunFailed()
            }
    }

    // MARK: - Asking

    /// One question, two ways to answer it, one button, and what you asked
    /// before.
    ///
    /// **The button scrolls with the form now** rather than being pinned to the
    /// bottom. It was pinned because the keyboard covers the bottom of the
    /// screen while somebody types — but a bar welded across the foot of the
    /// screen also sat between the form and everything under it, which is the
    /// reason there was nothing under it. The keyboard case is covered where it
    /// actually happens: Return submits, and the scroll dismisses
    /// interactively.
    private var question: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What are you selling?")
                        .font(.largeTitle.bold())
                    // The one line of instruction on the screen, and it is here
                    // rather than under a field because it answers the question
                    // somebody has before they touch anything: which of these
                    // two boxes do I have to fill in.
                    Text("A photo or a sentence is enough. Both is better.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 8)

                photoStrip

                VStack(alignment: .leading, spacing: 10) {
                    descriptionField
                    runButton
                }

                recentSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            // Clears the floating tab bar, which is an overlay rather than a
            // safe-area inset, so nothing reserves this space on its own.
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
        // Tapping anywhere off the field puts the keyboard away. Simultaneous
        // rather than `onTapGesture` so it never competes with a control for
        // the same tap: they run their own action and the keyboard goes either
        // way.
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isTyping = false })
    }

    /// The placeholder is the only instruction the field gets.
    ///
    /// It replaced a caps label above and a caption below — three explanations
    /// of one text box, two of which stay on screen forever describing a field
    /// that is already full. The example does the work of all three by being an
    /// example: it shows the make, the model, what's included and what's wrong
    /// with it, and it disappears the moment somebody starts typing.
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

    /// The button, directly under the thing it acts on.
    ///
    /// No spinner and no "checking…" state: the run is a screen, and this
    /// button's whole job is to get there. A button reporting on work happening
    /// somewhere the user can already see would be describing it twice.
    ///
    /// The line of reassurance that used to sit under it — where the numbers
    /// come from, how long it takes — is gone with the pinned bar. It was
    /// answering "is this broken?" for a button that thought silently for ten
    /// seconds, and the next screen answers that better by naming each step as
    /// it happens.
    private var runButton: some View {
        Button(action: submit) {
            Text("Check the price")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canRun)
    }

    // MARK: - What you asked before

    /// The runs already done, newest first.
    ///
    /// Under the form rather than on a screen of its own, because it is only
    /// worth anything to somebody who is already here — and because the two
    /// most useful things it can do are both about the form above it: showing
    /// the listing copy from a run whose answer was already taken, and stopping
    /// a second run on something priced last week.
    ///
    /// Absent when empty rather than showing an empty state. A section
    /// explaining that you have no history yet is a paragraph about nothing on
    /// the screen with the least room for one.
    @ViewBuilder
    private var recentSection: some View {
        if !model.recent.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Recent")

                VStack(spacing: 0) {
                    ForEach(Array(model.recent.enumerated()), id: \.element.id) { index, check in
                        if index > 0 { Divider().padding(.leading, 14) }
                        recentRow(check)
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
            .padding(.top, 8)
        }
    }

    private func recentRow(_ check: PastPriceCheck) -> some View {
        Button {
            selectedPast = check
            // Whether the history is a feature or a list nobody opens. It was
            // added on the argument that listing copy is as useful a week later
            // as it was the minute it was written — this is the number that
            // says whether that is true.
            var properties: [String: Any] = [
                "position": model.recent.firstIndex { $0.id == check.id } ?? -1,
                "has_price": check.price != nil,
                "has_listing_copy": check.hasListing
            ]
            properties["identified_name"] = Analytics.text(check.label)
            Analytics.capture(.priceCheckHistoryOpened, properties)
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(check.label)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if let when = check.whenText {
                        Text(when)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                // The price is the reason to tap the row, so it is on the row.
                // A run that found no market says so rather than showing a gap,
                // which would read as a value that failed to load.
                Text(check.priceText ?? "No price")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(check.priceText == nil ? .secondary : .primary)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
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
    ///
    /// Starts the run and pushes in the same breath, so the next screen is
    /// already showing the first step by the time the transition lands.
    ///
    /// **And empties the form.** The question has been asked and answered on
    /// the screen in front of them; coming back to a copy of it is a stale
    /// draft of something that is already done, and the next thing anyone does
    /// here is price a different object. The submitted values are held in
    /// `submitted` until the run's outcome is known, and put back if it failed
    /// — see `restoreIfRunFailed`.
    private func submit() {
        guard canRun else { return }
        isTyping = false
        model.start(draft, photos: photos.map(\.photo))
        submitted = (draft, photos)
        runThumbnail = photos.first?.preview
        draft = ""
        photos = []
        isRunning = true
    }

    /// Puts the question back if it never got an answer.
    ///
    /// Runs when the run screen is popped, and does nothing unless the run
    /// actually failed — a completed run leaves the form clear, which is the
    /// point of clearing it. Only when there is nothing to go back to does the
    /// form become the place to fix it, and then the photos need to still be
    /// there.
    private func restoreIfRunFailed() {
        guard let submitted else { return }
        if case .failed = model.phase {
            draft = submitted.draft
            photos = submitted.photos
        }
        self.submitted = nil
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

}

/// A field the user is going to paste somewhere else, so copying is the
/// primary action rather than a long-press away.
struct EditableCopyField: View {
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

/// The small letterspaced caps above each block.
///
/// A type rather than a helper on one view, because both halves of Price Check
/// use it and a second copy of "caption2, semibold, 0.8 tracking, secondary" is
/// how the two screens start disagreeing about what a section label looks like.
struct SectionLabel: View {
    private let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
