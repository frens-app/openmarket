import SwiftUI

/// Where a price sits against what everyone else is asking.
///
/// This replaces three clauses of prose. "10 nearby asking prices, $5 to $400,
/// with a median of $150. The middle half sits between $85 and $300" is four
/// numbers and two relationships, and a reader has to hold all six to picture
/// the thing this draws in one glance.
///
/// **The shaded band is the middle half, not a target.** It is where most of the
/// asks are, which is a fact about other sellers rather than advice — an item
/// genuinely better than everything listed should be asking above it, and the
/// bar has to make that look like a choice rather than an error. Nothing here
/// turns red.
struct PriceRangeBar: View {
    let price: Int
    let guide: PriceGuide

    private var lowest: Int { guide.lowest ?? price }
    private var highest: Int { guide.highest ?? price }

    /// Where `price` falls, 0…1. Guards the degenerate case where every
    /// comparable asks the same amount, which would otherwise divide by zero
    /// and put the marker nowhere.
    private func position(of value: Int) -> Double {
        let span = Double(highest - lowest)
        guard span > 0 else { return 0.5 }
        return min(max(Double(value - lowest) / span, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geometry in
                let width = geometry.size.width

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 6)

                    if let band = guide.typicalRange {
                        let start = position(of: band.lowerBound) * width
                        let end = position(of: band.upperBound) * width
                        Capsule()
                            .fill(Color.accentColor.opacity(0.25))
                            .frame(width: max(end - start, 2), height: 6)
                            .offset(x: start)
                    }

                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                        // Half the marker's width, so the dot centres on its
                        // value instead of starting at it — at the ends that is
                        // the difference between "the cheapest" and "cheaper
                        // than the cheapest".
                        .offset(x: position(of: price) * width - 8)
                }
                .frame(height: 16)
            }
            .frame(height: 16)

            // Three labels, and the middle one is the useful one: the ends are
            // outliers by definition and the band is where the market actually
            // is.
            HStack(alignment: .top, spacing: 8) {
                Text(guide.money(lowest))
                Spacer(minLength: 0)
                if let band = guide.typicalRange {
                    Text("most ask \(guide.money(band.lowerBound))–\(guide.money(band.upperBound))")
                    Spacer(minLength: 0)
                }
                Text(guide.money(highest))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Price position")
        .accessibilityValue(accessibilityDescription)
    }

    /// VoiceOver gets the sentence the sighted version replaced — a bar is not
    /// readable, and "0.4" would be worse than nothing.
    private var accessibilityDescription: String {
        var parts = ["\(guide.money(price)), against nearby asks from \(guide.money(lowest)) to \(guide.money(highest))"]
        if let band = guide.typicalRange {
            parts.append("most ask between \(guide.money(band.lowerBound)) and \(guide.money(band.upperBound))")
        }
        return parts.joined(separator: ". ")
    }
}
