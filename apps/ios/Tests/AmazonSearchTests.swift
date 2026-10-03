import XCTest
import WebKit
import OpenMarketProtos
@testable import OpenMarket

@MainActor
final class AmazonSearchTests: XCTestCase {
    func testLiveAmazonImages() async throws {
        guard ProcessInfo.processInfo.environment["AMAZON_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set AMAZON_LIVE_TEST=1 to check live Amazon images")
        }
        let search = AmazonSearch()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        search.webView.frame = window.bounds
        controller.view.addSubview(search.webView)
        defer { window.isHidden = true }
        let products = try await search.search("nintendo switch")
        XCTAssertFalse(products.isEmpty)
        for product in products.prefix(3) {
            let url = try XCTUnwrap(product.listing.thumbnailURL)
            let image = try await ImageLoader.shared.image(for: url)
            XCTAssertGreaterThan(image.size.width, 10)
        }
    }

    func testSearchEncodesProductTitle() {
        let term = "Nintendo Switch & dock + case"
        let url = AmazonSearch.url(for: term)
        XCTAssertEqual(url.host, "www.amazon.com")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, term)
    }

    func testExtractionDeduplicatesAndPreservesDisplayedPrices() async throws {
        let result = try await extract("""
        <div data-component-type="s-search-result" data-asin="B012345678">
          <h2>Console &amp; dock</h2><span class="a-price"><span class="a-offscreen">$299.99</span></span>
        </div>
        <div data-component-type="s-search-result" data-asin="B012345678"><h2>Duplicate</h2></div>
        <div data-component-type="s-search-result" data-asin="B987654321"><h2>No offer</h2></div>
        <div data-component-type="s-search-result" data-asin="invalid"><h2>Invalid ID</h2></div>
        """)
        let products = try XCTUnwrap(result["products"] as? [[String: Any]])
        XCTAssertEqual(products.count, 2)
        let decoded = try JSONDecoder().decode([AmazonProduct].self, from: JSONSerialization.data(withJSONObject: products))
        XCTAssertEqual(decoded[0].title, "Console & dock")
        XCTAssertEqual(decoded[0].comparable.listing.priceText, "$299.99")
        XCTAssertEqual(decoded[0].comparable.listing.itemURL?.absoluteString, "https://www.amazon.com/dp/B012345678")
        XCTAssertNil(decoded[1].price)
        let comps = decoded.map(\.comparable)
        var first = ComparableDecision()
        first.id = "0"
        first.useInComparison = false
        first.probability = 0.1
        var second = ComparableDecision()
        second.id = "1"
        second.useInComparison = true
        second.probability = 0.9
        let evaluated = try ComparisonRelevance.apply([second, first], to: comps,
                                                      candidates: ComparisonRelevance.candidates(from: comps))
        XCTAssertEqual(MarketComp.comparableFirst(evaluated).map(\.id), ["B987654321", "B012345678"])
    }

    func testLazyImagesIgnorePlaceholdersAndResolveURLs() async throws {
        let result = try await extract("""
        <div data-component-type="s-search-result" data-asin="B012345678">
          <h2>Lazy image</h2><img class="s-image" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///w=="
            data-src="//m.media-amazon.com/images/I/product.jpg">
        </div>
        <div data-component-type="s-search-result" data-asin="B987654321">
          <h2>Responsive image</h2><img class="s-image" srcset="https://m.media-amazon.com/images/I/other.jpg 2x">
        </div>
        <div data-component-type="s-search-result" data-asin="B123456789">
          <h2>Missing image</h2><img class="s-image" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///w==">
        </div>
        """)
        let products = try XCTUnwrap(result["products"] as? [[String: Any]])
        let decoded = try JSONDecoder().decode([AmazonProduct].self, from: JSONSerialization.data(withJSONObject: products))
        XCTAssertEqual(decoded[0].comparable.listing.thumbnailURL?.absoluteString,
                       "https://m.media-amazon.com/images/I/product.jpg")
        XCTAssertEqual(decoded[1].comparable.listing.thumbnailURL?.absoluteString,
                       "https://m.media-amazon.com/images/I/other.jpg")
        XCTAssertNil(decoded[2].comparable.listing.thumbnailURL)
    }

    func testMobileActionIconIsNotTheProductPhotoAndRenewedIsExcluded() async throws {
        let result = try await extract("""
        <div data-component-type="s-search-result" data-asin="B012345678">
          <h2>Nintendo</h2><h2>Nintendo Switch</h2>
          <img class="s-image" alt="More like this" src="https://m.media-amazon.com/images/I/01rrzVoKd5L.svg">
          <img class="s-image" src="https://m.media-amazon.com/images/I/console.jpg">
        </div>
        <div data-component-type="s-search-result" data-asin="B987654321">
          <h2>Nintendo Switch (Renewed)</h2>
        </div>
        """)
        let products = try XCTUnwrap(result["products"] as? [[String: Any]])
        XCTAssertEqual(products.count, 1)
        XCTAssertEqual(products.first?["title"] as? String, "Nintendo Switch")
        XCTAssertEqual(products.first?["image"] as? String, "https://m.media-amazon.com/images/I/console.jpg")
    }

    func testVerificationAndEmptyPagesAreDistinct() async throws {
        let blocked = try await extract("<form action='/errors/validateCaptcha'><input id='captchacharacters'></form>")
        XCTAssertEqual(blocked["blocked"] as? Bool, true)
        XCTAssertEqual(blocked["empty"] as? Bool, false)
        let empty = try await extract("<h2>No results for this product</h2>")
        XCTAssertEqual(empty["blocked"] as? Bool, false)
        XCTAssertEqual(empty["empty"] as? Bool, true)
    }

    private func extract(_ html: String) async throws -> [String: Any] {
        let view = WKWebView()
        let delegate = LoadedPage()
        view.navigationDelegate = delegate
        view.loadHTMLString(html, baseURL: URL(string: "https://www.amazon.com"))
        await fulfillment(of: [delegate.loaded], timeout: 5)
        let raw = try await view.evaluateJavaScript(AmazonSearch.extract)
        let text = try XCTUnwrap(raw as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}

@MainActor
private final class LoadedPage: NSObject, WKNavigationDelegate {
    let loaded = XCTestExpectation(description: "Fixture loaded")
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
}
