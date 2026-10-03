import SwiftUI

struct FeedPaginationFooter: View {
    let position: PaginationDemand.Position
    let canLoadMore: Bool
    let isLoading: Bool
    var loadingMessage: String? = nil
    let loadMore: () -> Void
    @State private var isNearBottom = false
    @State private var demand = PaginationDemand()

    private var state: PaginationDemand.State {
        .init(position: position, isNearBottom: isNearBottom,
              canLoadMore: canLoadMore, isLoading: isLoading)
    }

    var body: some View {
        ZStack {
            if isLoading {
                HStack {
                    ProgressView()
                        .accessibilityLabel("Loading more listings")
                    if let loadingMessage {
                        Text(loadingMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .onGeometryChange(for: Bool.self) { proxy in
            guard let viewport = proxy.bounds(of: .scrollView(axis: .vertical)) else { return false }
            return viewport.maxY >= -160 && viewport.minY <= proxy.size.height
        } action: { isNearBottom = $0 }
        .onChange(of: state, initial: true) { _, state in
            if demand.shouldLoad(state) { loadMore() }
        }
    }
}
