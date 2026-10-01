struct PaginationDemand {
    struct Position: Equatable {
        let generation: Int
        let visibleCount: Int
        let lastVisibleID: String?
    }

    struct State: Equatable {
        let position: Position
        let isNearBottom: Bool
        let canLoadMore: Bool
        let isLoading: Bool
    }

    private var lastAttempt: Position?

    mutating func shouldLoad(_ state: State) -> Bool {
        guard state.isNearBottom else {
            lastAttempt = nil
            return false
        }
        guard state.canLoadMore, !state.isLoading, lastAttempt != state.position else { return false }
        // An empty/filtered batch must not spin forever while the footer stays visible.
        lastAttempt = state.position
        return true
    }
}
