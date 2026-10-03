import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class SellerNavigationTests: XCTestCase {
    private final class HeldNavigationWebView: WKWebView {
        private let navigationSource = WKWebView()
        var requestedNavigation: WKNavigation?
        override func load(_ request: URLRequest) -> WKNavigation? {
            let navigation = navigationSource.loadHTMLString("<html></html>", baseURL: nil)
            requestedNavigation = navigation
            return navigation
        }
    }

    func testSameURLReloadCannotFetchFromPreviousDocumentOrStaleCommit() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let browser = HeldNavigationWebView(frame: .zero, configuration: configuration)
        let profile = SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "Seller"))!
        let previousNavigation = browser.loadHTMLString(#"""
        <script type="application/json">
        {"__bbox":{"result":{"data":{"user":{"id":"someone-else","profile_picture_160":{"uri":"https://example.com/wrong.jpg"}}}}}}
        </script>
        <script type="application/json">
        {"__bbox":{"result":{"data":{"user":{"id":"resolved-seller","profile_picture_160":{"uri":"https://example.com/profile.jpg"},"commerce_profile_picture_with_fallback_160":{"uri":"https://example.com/commerce.jpg"}}}}}}
        </script>
        <script type="application/json">
        {"queryName":"MarketplaceSellerProfileInventoryQuery","variables":{"sellerID":"123456789"},
         "__bbox":{"result":{"data":{"profile":{"id":"resolved-seller","marketplace_listing_sets":{
           "edges":[],"page_info":{"has_next_page":false,"end_cursor":null}}}}}}}
        </script>
        <script>
        window.calls = [];
        window.require = name => {
          if (name === 'CurrentUserInitialData') return {USER_ID:'test-actor'};
          if (name === 'getAsyncParams') return () => ({__user:'test-actor',fb_dtsg:'test-token'});
          throw new Error('Missing module');
        };
        window.fetch = async (url, options) => {
          window.calls.push(JSON.parse(options.body.get('variables')));
          return {ok:true,status:200,text:async () => JSON.stringify({data:{node:{id:'resolved-seller',
            marketplace_listing_sets:{edges:[{node:{canonical_listing:{id:'42',marketplace_listing_title:'Sold desk',
              is_sold:true,is_pending:false}}}],page_info:{has_next_page:false,end_cursor:null}}}}})};
        };
        window.ready = true;
        </script>
        """#, baseURL: profile.url)
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while (try? await browser.evaluateJavaScript("window.ready")) as? Bool != true {
            guard ContinuousClock.now < deadline else { return XCTFail("Fixture did not load") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let client = SellerProfileClient(pacer: RequestPacer(nextGap: { 0 }), webView: browser,
                                         currentActor: { "test-actor" })
        let load = Task { try await client.load(profile: profile, filter: .unavailable) }
        defer { load.cancel(); client.cancel() }
        while browser.requestedNavigation == nil { await Task.yield() }
        try await Task.sleep(for: .milliseconds(300))
        let beforeCommit = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertEqual(beforeCommit, 0, "The old document already matches the seller URL but must not be used")
        client.webView(browser, didCommit: previousNavigation)
        try await Task.sleep(for: .milliseconds(300))
        let afterStaleCommit = try await browser.evaluateJavaScript("window.calls.length") as? Int
        XCTAssertEqual(afterStaleCommit, 0, "An obsolete navigation must not unlock fetching")
        client.webView(browser, didCommit: browser.requestedNavigation)
        let result = try await load.value
        XCTAssertEqual(result.items.map(\.id), ["fb:42"])
        XCTAssertEqual(result.items.first?.badgeText, "Sold")
        XCTAssertEqual(result.sellerPhotoURL?.absoluteString, "https://example.com/commerce.jpg")
        let requests = try await browser.evaluateJavaScript("window.calls") as? [[String: Any]]
        XCTAssertEqual(requests?.count, 1)
        XCTAssertEqual(requests?.first?["availabilities"] as? [String], ["PENDING", "OUT_OF_STOCK"])
        XCTAssertEqual(requests?.first?["id"] as? String, "resolved-seller")
    }
}
