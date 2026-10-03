import Foundation
import WebKit

struct AmazonProduct: Decodable {
    let id: String
    let title: String
    let price: String?
    let image: String?

    var comparable: MarketComp {
        MarketComp(listing: Listing(id: id, title: title, priceText: price,
                                   thumbnailURL: image.flatMap(URL.init(string:)),
                                   itemURL: URL(string: "https://www.amazon.com/dp/\(id)"),
                                   cardIndex: 0, capturedAt: Date()))
    }
}

@MainActor
final class AmazonSearch: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var navigation: WKNavigation?
    private var loaded = false
    private var navigationError: Error?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func url(for term: String) -> URL {
        var components = URLComponents(string: "https://www.amazon.com/s")!
        components.queryItems = [URLQueryItem(name: "k", value: term),
                                URLQueryItem(name: "rh", value: "p_n_condition-type:6461716011")]
        return components.url!
    }

    func search(_ term: String) async throws -> [MarketComp] {
        loaded = false
        navigationError = nil
        navigation = webView.load(URLRequest(url: Self.url(for: term)))
        defer {
            navigation = nil
            webView.stopLoading()
        }
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(500))
            if let navigationError { throw navigationError }
            guard loaded else { continue }
            guard let raw = try await webView.evaluateJavaScript(Self.extract) as? String,
                  let data = raw.data(using: .utf8) else { continue }
            let result = try JSONDecoder().decode(SearchPage.self, from: data)
            if result.blocked { throw SearchError.blocked }
            if !result.products.isEmpty { return result.products.map(\.comparable) }
            if result.empty { return [] }
        }
        throw SearchError.unavailable
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === self.navigation else { return }
        loaded = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        navigationError = error
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === self.navigation else { return }
        navigationError = error
    }

    private struct SearchPage: Decodable {
        let products: [AmazonProduct]
        let blocked: Bool
        let empty: Bool
    }

    enum SearchError: LocalizedError {
        case blocked, unavailable
        var errorDescription: String? {
            switch self {
            case .blocked: "Amazon is asking for browser verification. Try again later."
            case .unavailable: "Couldn't read Amazon search results. Try again later."
            }
        }
    }

    static let extract = #"""
    (() => {
        const text = document.body?.innerText || '';
        const blocked = !!document.querySelector('#captchacharacters, form[action*="validateCaptcha"]')
            || /enter the characters you see|verify that you're not a robot|sorry, we just need to make sure/i.test(text);
        const imageURL = card => {
            // Amazon mobile puts a “More like this” SVG before the product photo.
            // Both carry s-image, so the first image is not necessarily the product.
            for (const img of card.querySelectorAll('img.s-image')) {
                const sources = [img.getAttribute('data-src'), img.getAttribute('data-lazy-src'),
                    img.currentSrc, img.getAttribute('src'),
                    ...(img.getAttribute('srcset') || '').split(',').map(entry => entry.trim().split(/\s+/)[0])];
                for (const source of sources) {
                    if (!source || /^(data:|blob:)/i.test(source)) continue;
                    try {
                        const url = new URL(source, document.baseURI);
                        if (url.protocol === 'https:' && !/\.svg$|(?:grey|transparent)-pixel|\/pixel[.-]/i.test(url.pathname)) return url.href;
                    } catch {}
                }
            }
            return null;
        };
        const seen = new Set();
        const products = [];
        for (const card of document.querySelectorAll('[data-component-type="s-search-result"][data-asin]')) {
            const id = card.getAttribute('data-asin');
            const title = Array.from(card.querySelectorAll('h2')).map(h => h.textContent.trim())
                .sort((a, b) => b.length - a.length)[0];
            if (!/^[A-Z0-9]{10}$/.test(id || '') || !title || seen.has(id)) continue;
            if (/\b(renewed|refurbished|pre[ -]?owned|used|open[ -]box)\b/i.test(title)) continue;
            seen.add(id);
            products.push({ id, title, price: card.querySelector('.a-price .a-offscreen')?.textContent?.trim() || null,
                image: imageURL(card) });
            if (products.length === 15) break;
        }
        return JSON.stringify({ products, blocked, empty: /no results for|did not match any products/i.test(text) });
    })()
    """#
}
