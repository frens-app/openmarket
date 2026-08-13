import SwiftUI

/// Everything the price was built from, one screen behind a tap.
///
/// The comparables used to be on the main screen, above the answer, on the
/// argument that they are the working rather than an illustration. They still
/// are — but two horizontal strips and a paragraph of arithmetic is most of a
/// screen, and it sat between a person and the number they came for.
///
/// So the claim moved rather than the evidence: the main screen says what the
/// price is and where it sits, and says out loud how many listings are behind
/// it. This is where somebody who wants to check goes, and it holds the things
/// that screen can no longer afford — the full arithmetic, and every card.
///
/// **The two caveats live here now, in full.** They are the ones nothing else
/// on either screen can say: these are asking prices rather than sale prices,
/// and a list filtered on having sold cannot contain the things that didn't.
struct PriceEvidenceView: View {
    let comps: [MarketComp]
    let sold: SoldSignal
    let guide: PriceGuide
    let price: Int
    let marketName: String
    let searchTerm: String?

    @State private var selected: Listing?
    @Namespace private var heroNamespace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                summary
                if !comps.isEmpty { strip("What's listed nearby", comps, footnote: nil) }
                if !sold.isEmpty {
                    strip("Recently sold nearby", sold.comps, footnote: soldFootnote)
                }
                caveats
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            // Clears the floating tab bar, which overlays rather than insets —
            // without this the caveats sit underneath it, which is the worst
            // thing on the screen to have half-covered.
            .padding(.bottom, 96)
        }
        .navigationTitle("What this is based on")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { listing in
            DetailView(listing: listing, namespace: heroNamespace)
        }
    }

    /// The long-form arithmetic, which is exactly what the main screen dropped
    /// when the bar took over. Every number in it is measured.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let searchTerm {
                Text("Searched \(marketName) for “\(searchTerm)”.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(sold.rationale(for: price, against: guide))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func strip(_ title: String, _ items: [MarketComp], footnote: ((MarketComp) -> String?)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { position, comp in
                        CompCard(comp: comp, footnote: footnote?(comp))
                            .onTapGesture { open(comp, at: position) }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// A comparable, opened as an ordinary listing.
    ///
    /// Counted under the same event as the four browse surfaces rather than one
    /// of its own, because it is the same act — somebody went and looked at a
    /// listing — and the only interesting thing about it is that they arrived
    /// from a price check. That is what `surface` is for. It is also the one
    /// place in the app where a *sold* listing can be opened, which is why that
    /// goes up beside it.
    private func open(_ comp: MarketComp, at position: Int) {
        selected = comp.listing
        var properties: [String: Any] = [
            "surface": Analytics.Surface.priceCheckEvidence.rawValue,
            "position": position,
            "listing_id": comp.listing.id,
            "has_price": comp.listing.priceText != nil,
            "is_sold": comp.isSold
        ]
        properties["title"] = Analytics.text(comp.listing.title)
        // `comp.price` rather than re-parsing the text: the comparable already
        // carries the number `PriceGuide` read out of it, and that is the one
        // the recommendation was computed from. Parsing again here could only
        // ever disagree with the chart beside it.
        if let price = comp.price { properties["price"] = price }
        properties["search_term"] = Analytics.text(searchTerm?.lowercased())
        Analytics.capture(.listingOpened, properties)
    }

    private func soldFootnote(_ comp: MarketComp) -> String? {
        guard let days = comp.daysListed else { return "Sold" }
        if days <= 1 { return "Sold within a day" }
        return "Sold in ~\(days) days"
    }

    private var caveats: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Asking prices, not sale prices. Facebook publishes what sellers want and never what buyers paid — including on the sold cards, where the price shown is what it was listed at.")
            Text("The sold list only contains things that sold. Whatever failed to sell at a price is exactly what's missing from it, so nothing here can show a price is too high — only that certain prices worked.")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
