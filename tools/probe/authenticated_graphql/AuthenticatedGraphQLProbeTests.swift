import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class AuthenticatedGraphQLProbeTests: XCTestCase {
    func testAuthenticatedPagination() async throws {
        let signedIn = await SessionState.isSignedIn()
        guard signedIn else { throw XCTSkip("No signed-in Facebook session") }
        let engine = DesktopFeedEngine(session: .authed, pacer: RequestPacer())
        engine.webView.configuration.userContentController.addUserScript(WKUserScript(source: #"""
        const original = window.fetch;
        window.fetch = async function(...args) {
            const response = await original.apply(this, args);
            if (String(args[0]).includes('/api/graphql/')) {
                const text = await response.clone().text();
                window.__probeSummary = {status: response.status, bytes: text.length};
                try {
                    const records = text.replace('for (;;);', '').trim().split(String.fromCharCode(10)).map(JSON.parse);
                    window.__probeSummary.records = records.map(r => {
                        const c = r.data?.marketplace_search?.feed_units || r.data?.marketplace_home_feed;
                        return {path: r.path, errorCode: typeof r.error === 'number' ? r.error : undefined, errorCodes: r.errors?.map(e => e.code),
                          nodeType: r.data?.node?.__typename, dataKeys: Object.keys(r.data || {}), edges: c?.edges?.length,
                          edgeTypes: [...new Set((c?.edges || []).map(e => e.node?.__typename))],
                          next: c?.page_info?.has_next_page};
                    });
                } catch (_) { window.__probeSummary.isJSON = false; }
            }
            return response;
        };
        """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        host.view.addSubview(engine.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let client = AuthenticatedFeedClient(webView: engine.webView, pacer: RequestPacer())
        for kind in [SearchQuery.Kind.search("anthurium"), .browse] {
            let query = SearchQuery(kind: kind, radiusKM: 16, citySlug: "sanfrancisco",
                                    coordinate: CLLocationCoordinate2D(latitude: 37.7793, longitude: -122.419),
                                    delivery: kind == .browse ? .any : .localPickup)
            var pagination = GraphQLFeedPagination()
            for index in 0..<(kind == .browse ? 2 : 3) {
                let start = Date()
                let page: GraphQLFeedPage
                do { page = try await client.page(for: query, cursor: pagination.cursor) }
                catch {
                    print("AUTH_PROBE failure type=\(type(of: error)) code=\((error as NSError).code)")
                    let summary = try? await engine.webView.evaluateJavaScript("JSON.stringify(window.__probeSummary)")
                    print("AUTH_PROBE response=\(summary as? String ?? "missing")")
                    throw error
                }
                let summary = try? await engine.webView.evaluateJavaScript("JSON.stringify(window.__probeSummary)")
                print("AUTH_PROBE response=\(summary as? String ?? "missing")")
                let cards = try pagination.accept(page)
                print("AUTH_PROBE production \(query.displayName) page=\(index) new=\(cards.count) more=\(page.hasNextPage) ms=\(Int(Date().timeIntervalSince(start)*1000))")
                if !page.hasNextPage { break }
            }
        }
    }
}
