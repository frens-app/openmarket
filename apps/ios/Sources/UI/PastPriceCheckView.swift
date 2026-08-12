import SwiftUI
import UIKit

/// A run that already happened.
///
/// **Deliberately not the answer screen with old data in it.** Two things a
/// fresh run has are gone by the time anyone opens this: the comparables, which
/// were never stored because a card that was live during the run is a 404 a
/// week later, and the range they defined — so there is no bar to draw a marker
/// on and no stepper, because a stepper clamps to observed prices and there are
/// none to clamp to. Showing either as an empty shell would be worse than
/// leaving them out.
///
/// What is left is what people come back for. The listing copy is exactly as
/// useful a week later as it was the minute it was written, and the price is
/// still the price that was recommended — it just needs saying that it was a
/// reading of the market on the day rather than a reading of it now.
struct PastPriceCheckView: View {
    @EnvironmentObject private var model: SellerToolsModel
    let check: PastPriceCheck

    /// Editable for the same reason as on a fresh run: the model wrote this
    /// from a photograph and two lines of notes, and the seller knows the rest.
    /// Seeded once in `onAppear` — see `SellerToolsModel.input` for why a
    /// `TextField` must not be re-rendered from a published value mid-edit.
    @State private var editedTitle = ""
    @State private var editedBody = ""
    @State private var didCopyPrice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                priceBlock
                listingBlock
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 96)
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Price check")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            editedTitle = check.listingTitle
            editedBody = check.listingBody
        }
    }

    /// What it was, when, and what it was searched as.
    ///
    /// The search term is here rather than hidden, same as on a fresh run: a
    /// price guide is only as good as what it went looking for, and months
    /// later this is the line that explains a number that looks wrong.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(check.label)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String? {
        var parts: [String] = []
        if let when = check.whenText { parts.append(when) }
        if !check.searchTerm.isEmpty { parts.append("searched for “\(check.searchTerm)”") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The number, and what it rested on.
    ///
    /// The counts are stated and the cards are not offered, which is the honest
    /// pair: "15 nearby listings" is a fact about the run that was recorded,
    /// and a strip of links to listings that have since sold or been deleted
    /// would be a broken promise dressed as evidence.
    @ViewBuilder
    private var priceBlock: some View {
        if let price = check.price {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Listed at")

                Button(action: { copyPrice(price) }) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(check.currency)\(price)")
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        Image(systemName: didCopyPrice ? "checkmark" : "doc.on.doc")
                            .font(.footnote)
                            .foregroundStyle(didCopyPrice ? Color.accentColor : .secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(didCopyPrice ? "Price copied" : "Copy price")

                if let evidence = check.evidenceText {
                    Text("Read from \(evidence) that day. Those listings aren't kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            // A run that found no market is still worth opening — the listing
            // copy below it is intact, and it was written before any comparable
            // existed.
            InlineNotice(text: "Nothing similar was listed nearby, so this run never got to a price.",
                         actionTitle: nil,
                         action: nil)
        }
    }

    /// Copies the bare number — Facebook's price box wants digits, not "$150".
    private func copyPrice(_ price: Int) {
        UIPasteboard.general.string = String(price)
        model.recordCopy(of: check, price: price)
        withAnimation(.easeOut(duration: 0.15)) { didCopyPrice = true }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.2)) { didCopyPrice = false }
        }
    }

    @ViewBuilder
    private var listingBlock: some View {
        if check.hasListing {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Ready to paste")

                VStack(spacing: 0) {
                    if !check.listingTitle.isEmpty {
                        EditableCopyField(caption: "Title", text: $editedTitle, isProse: false) {
                            model.recordCopy(of: check, title: editedTitle)
                        }
                        Divider().padding(.leading, 14)
                    }
                    if !check.listingBody.isEmpty {
                        EditableCopyField(caption: "Description", text: $editedBody, isProse: true) {
                            model.recordCopy(of: check, description: editedBody)
                        }
                    }
                }
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
