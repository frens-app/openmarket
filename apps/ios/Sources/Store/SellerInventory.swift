import Foundation
import WebKit

struct SellerInventoryPage {
    let items: [Listing]
    let hasMore: Bool
    var sellerPhotoURL: URL? = nil
}

@MainActor
protocol SellerInventoryLoading {
    var webView: WKWebView { get }
    func load(profile: SellerProfile, filter: SellerListingFilter) async throws -> SellerInventoryPage
    func nextPage() async throws -> SellerInventoryPage
    func cancel()
}

enum SellerInventoryError: Error, LocalizedError {
    case signInRequired, unavailable, unsupported
    var errorDescription: String? {
        switch self {
        case .signInRequired: return "Sign in to Facebook to see this seller's listings."
        case .unavailable: return "This seller's listings aren't available right now."
        case .unsupported: return "Couldn't read this seller's listings. You can try again or view their profile on Facebook."
        }
    }
}

@MainActor
final class SellerInventory: ObservableObject {
    @Published private(set) var items: [Listing] = []
    @Published private(set) var isLoading = true
    @Published private(set) var needsSignIn = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var canLoadMore = false
    @Published private(set) var sellerPhotoURL: URL?
    private let loader: SellerInventoryLoading
    @Published private(set) var generation = 0
    private var loaded = false
    private var loadedProfileID: String?
    private var loadedFilter: SellerListingFilter?
    var webView: WKWebView { loader.webView }

    init(loader: SellerInventoryLoading? = nil) { self.loader = loader ?? SellerProfileClient() }

    func loadIfNeeded(profile: SellerProfile, filter: SellerListingFilter) async {
        guard !loaded || loadedProfileID != profile.id || loadedFilter != filter else { return }
        await load(profile: profile, filter: filter)
    }

    func load(profile: SellerProfile, filter: SellerListingFilter) async {
        cancel()
        let request = generation
        items = []
        sellerPhotoURL = nil
        loaded = false
        needsSignIn = false
        canLoadMore = false
        errorMessage = nil
        isLoading = true
        defer { if request == generation { isLoading = false } }
        do {
            let page = try await loader.load(profile: profile, filter: filter)
            guard request == generation, !Task.isCancelled else { return }
            accept(page)
            loaded = true
            loadedProfileID = profile.id
            loadedFilter = filter
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            failure(error)
        }
    }

    func retry(profile: SellerProfile, filter: SellerListingFilter) async {
        if loaded { await loadMore() } else { await load(profile: profile, filter: filter) }
    }

    func loadMore() async {
        guard loaded, canLoadMore, !isLoading else { return }
        let request = generation
        isLoading = true
        errorMessage = nil
        defer { if request == generation { isLoading = false } }
        do {
            let page = try await loader.nextPage()
            guard request == generation, !Task.isCancelled else { return }
            accept(page)
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            failure(error)
        }
    }

    func cancel() {
        generation &+= 1
        loader.cancel()
        isLoading = false
    }

    private func accept(_ page: SellerInventoryPage) {
        var ids = Set(items.map { $0.itemURL?.marketplaceItemID ?? $0.id })
        items.append(contentsOf: page.items.filter { ids.insert($0.itemURL?.marketplaceItemID ?? $0.id).inserted })
        canLoadMore = page.hasMore
        if let photoURL = page.sellerPhotoURL { sellerPhotoURL = photoURL }
    }

    private func failure(_ error: Error) {
        if case SellerInventoryError.signInRequired = error {
            needsSignIn = true
            items = []
            canLoadMore = false
            loaded = false
        } else if case GraphQLFeedError.sessionChanged = error {
            items = []
            canLoadMore = false
            loaded = false
            errorMessage = error.localizedDescription
        } else { errorMessage = error.localizedDescription }
    }
}
