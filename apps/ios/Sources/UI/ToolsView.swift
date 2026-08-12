import SwiftUI

/// The Tools tab: a menu of the things the app can work out for you, as opposed
/// to Browse, which is the things other people are selling.
///
/// A menu rather than the tool itself, even though there is exactly one tool
/// today. The tab used to open straight into what is now Price Check, which made
/// "Seller" and "the pricing screen" the same thing — and every second tool
/// would then have had to displace it. A list costs one tap and makes the shape
/// of the tab honest: these are separate jobs that happen to share a location, a
/// session and a webview.
///
/// **The two "coming soon" rows are gone.** They were listed rather than hidden
/// on the argument that a one-item menu reads as a mistake — which was a worry
/// about how the screen looks, weighed against two rows that promise things
/// nobody is building. One real row is honest; three rows where two do nothing
/// is a menu that mostly does nothing. If either gets built it comes back as a
/// `NavigationLink`, which is a smaller change than the placeholder was.
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
        // Centred rather than top-aligned. The chevron used to hang off the
        // first line with a nudge of padding to fake it, which only looks right
        // while the summary is exactly two lines — it is a two-line summary
        // today and a three-line one after any edit. Centring the row means the
        // marker sits against the block it belongs to whatever length it is.
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
