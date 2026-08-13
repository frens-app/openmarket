import UIKit

/// Universal links to the canonical web URL. iOS routes them to the
/// Facebook app when it's installed and to Safari when it isn't. The `fb://`
/// custom scheme is undocumented and fails silently, so it's never used.
enum Handoff {
    static func open(_ url: URL, kind: String, metrics: MetricsReporter = LocalMetrics.shared) {
        metrics.handoff(kind: kind)
        UIApplication.shared.open(url)
    }

    static func openMarketplace(metrics: MetricsReporter = LocalMetrics.shared) {
        guard let url = URL(string: "https://www.facebook.com/marketplace/") else { return }
        open(url, kind: "marketplace-root", metrics: metrics)
    }

    /// Used when a listing's canonical URL couldn't be resolved. Searching
    /// Marketplace for the title lands the user on or beside the item, which
    /// beats dropping them at the top of Marketplace with nothing to go on.
    static func openSearch(for listing: Listing,
                           citySlug: String?,
                           metrics: MetricsReporter = LocalMetrics.shared) {
        guard let title = listing.title, !title.isEmpty else {
            openMarketplace(metrics: metrics)
            return
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.facebook.com"
        components.path = "/marketplace/\(citySlug ?? "search")/search/"
        components.queryItems = [URLQueryItem(name: "query", value: title)]
        guard let url = components.url else {
            openMarketplace(metrics: metrics)
            return
        }
        open(url, kind: "search-fallback", metrics: metrics)
    }
}
