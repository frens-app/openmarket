import SwiftUI

/// The Tools tab: a menu of the things the app can work out for you, as opposed
/// to Browse, which is the things other people are selling.
///
/// A menu rather than the tool itself, even though there is exactly one tool
/// today: opening straight into Price Check would make "Seller" and "the pricing
/// screen" the same thing, and every second tool would have to displace it.
/// These are separate jobs that happen to share a location, a session and a
/// webview. No placeholder rows for unbuilt tools — a menu where most entries do
/// nothing is worse than a short one.
struct ToolsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    NavigationLink {
                        PriceCheckView()
                    } label: {
                        ToolRow(icon: "tag",
                                name: "Price Check",
                                summary: "Describe what you're selling and get a price backed by what's listed and what's sold nearby.")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// One row of the menu.
///
/// A card rather than a `List` row: the summary is two lines of prose and needs
/// the width, and the tab has no other list on it to be consistent with.
private struct ToolRow: View {
    let icon: String
    let name: String
    let summary: String

    var body: some View {
        // Centred, not top-aligned: the chevron then sits against the block it
        // belongs to whatever length the summary turns out to be.
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.headline)
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}
