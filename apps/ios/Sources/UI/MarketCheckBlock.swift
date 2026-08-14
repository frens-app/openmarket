import SwiftUI

/// "Is this a good price?", under any listing that has a price and a title.
///
/// One tap, then the same two searches the seller tab runs — but on its own
/// webviews, so nothing the user was reading moves. Collapsed until asked,
/// because most listings are opened to look at the photos.
struct MarketCheckBlock: View {
    let listing: Listing
    /// False once the item page says the listing is sold or pending — where
    /// "is this a good price" is a question about something nobody can buy.
    /// It only withdraws the offer: an answer already on screen stays, because
    /// the sold state can land seconds after the check does.
    let canAsk: Bool

    @EnvironmentObject private var checks: MarketCheckModel

    var body: some View {
        Group {
            switch checks.phase(for: listing) {
            case nil:
                if canAsk { askButton }
            case .running(let stage):
                runningCard(stage)
            case .done(let check):
                answer(check)
            case .failed(let message):
                InlineNotice(text: message, actionTitle: "Try again") { checks.check(listing) }
            }
        }
        .animation(.easeOut(duration: 0.2), value: checks.phase(for: listing))
    }

    private var askButton: some View {
        Button { checks.check(listing) } label: {
            Label("Is this a good price?", systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
    }

    private func runningCard(_ stage: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(stage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    /// The verdict, the bar, and the way to the working.
    ///
    /// Nothing is coloured by outcome. A price above every comparable is a fact
    /// about the other listings, not a fault in this one — see `PriceRangeBar`,
    /// which draws the same refusal.
    @ViewBuilder
    private func answer(_ check: MarketCheck) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: check.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                Text(check.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if !check.guide.isEmpty {
                PriceRangeBar(price: check.price, guide: check.guide)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let position = check.position {
                    Text(position)
                }
                if let sold = check.soldLine {
                    Text(sold)
                } else if check.sold.isEmpty {
                    Text("Nothing similar has sold nearby lately.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !check.comps.isEmpty || !check.sold.isEmpty {
                NavigationLink {
                    PriceEvidenceView(comps: check.comps,
                                      sold: check.sold,
                                      guide: check.guide,
                                      price: check.price,
                                      marketName: check.marketName,
                                      searchTerm: check.term,
                                      surface: .marketCheck)
                        .onAppear { capture(check) }
                } label: {
                    Text("See what this is based on")
                        .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func capture(_ check: MarketCheck) {
        Analytics.capture(.marketCheckEvidenceOpened, [
            "listing_id": listing.id,
            "comps_found": check.comps.count,
            "sold_count": check.sold.count
        ])
    }
}
