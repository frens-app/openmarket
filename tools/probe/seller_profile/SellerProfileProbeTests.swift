import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class SellerProfileProbeTests: XCTestCase {
    func testDiscovery() async throws {
        guard await SessionState.isSignedIn() else { throw XCTSkip("Sign into the QA app first") }
        let query = SearchQuery(kind: .search("plant"), radiusKM: 8, citySlug: "sanfrancisco",
            coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433), delivery: .localPickup)
        let feed = try await AnonymousFeedClient().page(for: query, cursor: nil)
        let card = try XCTUnwrap(feed.listings.first).makeListing(cardIndex: 0)
        let detail = DetailEngine()
        let browser = DesktopFeedEngine(session: .authed)
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        host.view.addSubview(detail.webView)
        host.view.addSubview(browser.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let value = await detail.loadBrowserDetail(id: card.id, url: card.itemURL!)
        let profile = try XCTUnwrap(value.flatMap(SellerProfile.init(detail:)))
        let cards = await browser.loadCards(profile.url)
        print("SELLER_PROBE cards=\(cards.count)")
        print("SELLER_PROBE discovery=\(await browser.evaluate(Self.discovery) ?? "missing")")
    }

    static let discovery = #"""
    (() => {
      const queries = [], shapes = [], seen = new Set();
      function walk(x,p,depth) {
        if (!x || typeof x !== 'object' || depth > 35) return;
        if (x.queryName && x.variables) {
          queries.push({name:x.queryName,id:x.queryID,variables:Object.fromEntries(Object.entries(x.variables).map(([k,v]) => [k,/id/i.test(k) ? typeof v : v]))});
        }
        if (x.edges && x.page_info) {
          const keys = Object.keys(x.edges[0]?.node || {});
          shapes.push({path:p,keys,count:x.edges.length,page_info:Object.keys(x.page_info)});
        }
        for (const [k,v] of Object.entries(x)) walk(v,p+'.'+k,depth+1);
      }
      for (const s of document.querySelectorAll('script[type="application/json"]')) {
        try { walk(JSON.parse(s.textContent),'root',0); } catch (_) {}
      }
      const controls = [...document.querySelectorAll('[role="tab"],[role="combobox"],select,option')].map(x=>({role:x.getAttribute('role'),text:x.innerText,aria:x.getAttribute('aria-label')}));
      const modules = [...new Set((document.documentElement.innerHTML.match(/Marketplace[A-Za-z0-9_]*(?:Query|Pagination)[A-Za-z0-9_]*[.]graphql/g)||[]))];
      return JSON.stringify({queries,shapes,controls,modules});
    })()
    """#
}
