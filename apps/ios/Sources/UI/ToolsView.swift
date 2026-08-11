import SwiftUI

/// The Tools tab: a menu of the things the app can work out for you, as opposed
/// to Browse, which is the things other people are selling.
///
/// A menu rather than the tool itself, even though there is one working tool
/// today. The tab used to open straight into what is now Price Check, which
/// made "Seller" and "the pricing screen" the same thing — and every second
/// tool would then have had to displace it. A list costs one tap and makes the
/// shape of the tab honest: these are separate jobs that happen to share a
/// location, a session and a webview.
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

                    // Named but not built. Listed rather than hidden because a
                    // one-item menu reads as a mistake, and because both are
                    // things this app has the machinery for — the draft writer
                    // existed and was taken out with the on-device model (see
                    // `SellerToolsModel`), and a buyer-side check is the same
                    // comparable search pointed at a listing instead of a
                    // description.
                    ForEach(Tool.upcoming) { tool in
                        ToolRow(icon: tool.icon,
                                name: tool.name,
                                summary: tool.summary,
                                isComingSoon: true)
                    }
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

/// A tool that isn't here yet. Only the unbuilt ones are modelled — Price Check
/// is a `NavigationLink` to a real screen, and pretending otherwise would mean
/// a destination-by-enum indirection to save nothing.
private struct Tool: Identifiable {
    let id: String
    let icon: String
    let name: String
    let summary: String

    static let upcoming: [Tool] = [
        Tool(id: "listing-draft",
             icon: "text.alignleft",
             name: "Listing Draft",
             summary: "Turn the same description into a title and a listing you can paste."),
        Tool(id: "deal-check",
             icon: "checkmark.seal",
             name: "Deal Check",
             summary: "Point it at a listing you're thinking of buying and see whether the price holds up."),
    ]
}

/// One row of the menu.
///
/// A card rather than a `List` row: the summary is two lines of prose and needs
/// the width, and the tab has no other list on it to be consistent with.
private struct ToolRow: View {
    let icon: String
    let name: String
    let summary: String
    var isComingSoon = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isComingSoon ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.headline)
                    if isComingSoon { comingSoonTag }
                }
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 8)

            if !isComingSoon {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        // Dimmed rather than removed: an unbuilt tool is worth knowing about,
        // and a row that looks tappable and does nothing is worse than one that
        // plainly says it isn't ready.
        .opacity(isComingSoon ? 0.65 : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(isComingSoon ? "Not available yet" : "")
    }

    private var comingSoonTag: some View {
        Text("Coming soon")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
    }
}
