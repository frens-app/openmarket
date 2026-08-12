import SwiftUI

/// A row-aligned listing grid. Every listing card reserves the same content
/// slots, and `LazyVGrid` makes the next pair begin on one shared baseline.
struct ListingGrid<Item: Identifiable, Content: View>: View {
    let items: [Item]
    let columns: Int
    let spacing: CGFloat
    let loadingPlaceholderCount: Int
    @ViewBuilder let content: (Item) -> Content

    init(items: [Item],
         columns: Int,
         spacing: CGFloat,
         loadingPlaceholderCount: Int = 0,
         @ViewBuilder content: @escaping (Item) -> Content) {
        self.items = items
        self.columns = columns
        self.spacing = spacing
        self.loadingPlaceholderCount = loadingPlaceholderCount
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: spacing) {
            ForEach(items) { item in
                content(item)
            }
            // These must live in the same grid as the real cells. When the
            // result count is odd, the first placeholder naturally occupies
            // the open second column instead of beginning a detached new row.
            ForEach(0..<loadingPlaceholderCount, id: \.self) { index in
                if index == 0 {
                    SkeletonCard()
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Loading more listings")
                } else {
                    SkeletonCard()
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing, alignment: .top),
            count: columns
        )
    }
}

struct SkeletonGrid: View {
    let rows: Int
    let accessibilityLabel: String

    init(rows: Int = 4, accessibilityLabel: String = "Loading listings") {
        self.rows = rows
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2),
            spacing: 12
        ) {
            ForEach(0..<(rows * 2), id: \.self) { _ in
                SkeletonCard()
            }
        }
        .padding(.horizontal, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

struct SkeletonCard: View {
    @State private var shimmer = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemFill))
                .frame(height: 180)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemFill))
                .frame(width: 60, height: 14)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemFill))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemFill))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.secondarySystemFill))
                .frame(width: 110, height: 10)
        }
        .opacity(shimmer ? 0.7 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: shimmer)
        .onAppear { shimmer = true }
    }
}
