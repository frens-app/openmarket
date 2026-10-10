import Foundation

protocol GraphQLFeedLoading {
    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage
}

struct GraphQLFeedPage {
    let listings: [PayloadListing]
    let endCursor: String?
    let hasNextPage: Bool
    var filteredAdCount = 0
}

enum GraphQLFeedError: Error, LocalizedError, Equatable {
    case unsupportedQuery
    case invalidResponse
    case blocked
    case paused
    case sessionChanged

    var permitsBrowserFallback: Bool {
        self == .unsupportedQuery || self == .invalidResponse
    }

    var errorDescription: String? {
        switch self {
        case .sessionChanged: return "Facebook session changed. Refresh your results to continue."
        case .blocked, .paused: return "Browsing is paused. Try again shortly."
        case .unsupportedQuery, .invalidResponse: return "Couldn't load more listings. Try again."
        }
    }
}

/// Session-local cursors never enter the disk cache or cross query generations.
struct GraphQLFeedPagination {
    private(set) var cursor: String?
    private(set) var hasNextPage = true
    private var cursors = Set<String>()
    private var listingIDs = Set<String>()

    mutating func accept(_ page: GraphQLFeedPage) throws -> [PayloadListing] {
        if page.hasNextPage {
            guard let next = page.endCursor, !next.isEmpty,
                  next != cursor, !cursors.contains(next) else {
                throw GraphQLFeedError.invalidResponse
            }
        }
        cursor = page.endCursor
        if let cursor { cursors.insert(cursor) }
        hasNextPage = page.hasNextPage
        return page.listings.filter { listingIDs.insert($0.id).inserted }
    }
}
