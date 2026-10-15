import XCTest
import SwiftUI
import OpenMarketProtos
@testable import OpenMarket

final class RegionalCurrencyTests: XCTestCase {
    func testSouthAfricanAmountsPreserveCurrencyAndCents() throws {
        let currency = try XCTUnwrap(MarketRegion.region(countryCode: "ZA")?.currency)
        XCTAssertEqual(currency.code, "ZAR")
        XCTAssertEqual(currency.localSymbol, "R")
        XCTAssertEqual(currency.amount(fromFacebookOffset: "123456"), Decimal(string: "1234.56"))
        for source in ["ZAR1,234.56", "R1 234,56", "R1\u{00a0}234,56", "1 234,56 ZAR"] {
            let parsed = try XCTUnwrap(MarketplacePrice.parse(source), source)
            XCTAssertEqual(parsed.amount, Decimal(string: "1234.56"), source)
            let listing = Listing(id: source, priceText: source, cardIndex: 0, capturedAt: Date())
            XCTAssertEqual(listing.currencyCode, "ZAR", source)
        }
        XCTAssertEqual(MarketplacePrice.display("ZAR1,234.56"), "R1,234.56")
        XCTAssertEqual(MarketCurrency.unambiguousCurrency(symbol: "R$")?.code, "BRL")
    }

    @MainActor
    func testCurrencyCardsRender() throws {
        let suite = "RegionalCurrencyTests.preview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preview = CurrencyCardsPreview()
            .environmentObject(DistanceResolver(defaults: defaults))
            .environmentObject(SavedListings(defaults: defaults))
            .environmentObject(ViewedListings(defaults: defaults))
            .padding(16)
            .frame(width: 430)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 2
        let attachment = XCTAttachment(image: try XCTUnwrap(renderer.uiImage))
        attachment.name = "Regional currency listing cards"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCapturedSearchPricesMatchFacebookMajorAmounts() throws {
        struct Price: Decodable { let source: String; let amount: String }
        struct Market: Decodable { let country: String; let prices: [Price] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "RegionalPrices", withExtension: "json"))
        let markets = try JSONDecoder().decode([Market].self, from: Data(contentsOf: url))
        XCTAssertEqual(markets.count, 19)
        for market in markets {
            XCTAssertTrue(MarketRegion.region(countryCode: market.country)?.marketplaceVerified == true)
            for price in market.prices {
                // Berlin returned one cross-border Polish listing. Preserve its
                // source text, but don't treat an unsupported currency as euros.
                if price.source.hasPrefix("PLN") {
                    XCTAssertNil(MarketplacePrice.parse(price.source))
                    XCTAssertEqual(MarketplacePrice.display(price.source), price.source)
                    continue
                }
                XCTAssertEqual(MarketplacePrice.parse(price.source)?.amount, Decimal(string: price.amount),
                               "\(market.country): \(price.source)")
            }
        }
    }

    func testDecimalAndGroupingConventionsAcrossExtractionRoutes() throws {
        let samples: [(String, String)] = [
            ("CA$1,234.56", "1234.56"), ("£1,234.56", "1234.56"),
            ("1\u{202f}234,56 €", "1234.56"), ("1.234,56 €", "1234.56"),
            ("€ 1.234,56", "1234.56"), ("MX$1,234.56", "1234.56"),
            ("₱1,234.56", "1234.56"), ("R$ 1.234,56", "1234.56"),
            ("₹1,23,456.78", "123456.78"), ("Rp1.234.567", "1234567"),
            ("1.234.567 ₫", "1234567"), ("৳১,২৩,৪৫৬.৭৮", "123456.78"),
            ("PKR1,234.56", "1234.56"), ("Rs 1,234.56", "1234.56"),
            ("\u{200f}١٬٢٣٤٫٥٦ ج.م.\u{200f}", "1234.56"),
            ("฿1,234.56", "1234.56"), ("₦1,234.56", "1234.56"),
            ("COP1.234.567", "1234567"), ("1.234,56 TL", "1234.56"),
            ("AR$1.234,56", "1234.56"), ("R1 234,56", "1234.56"),
            ("1\u{00a0}234,56 DA", "1234.56"), ("1.234,56 kr.", "1234.56"),
            ("TWD1,234", "1234"), ("USD0.99", "0.99"),
            ("IDR550M", "550000000"), ("Rp1.25M", "1250000"),
        ]
        for (source, expected) in samples {
            XCTAssertEqual(MarketplacePrice.parse(source)?.amount, Decimal(string: expected), source)
            let expectedWhole = NSDecimalNumber(string: expected).intValue
            XCTAssertEqual(PriceGuide.parse(source), expectedWhole, source)
            let raw = DesktopRawCard(id: "123", label: "Desk, \(source), Example City, listing 123",
                                     imageURL: "", text: "", lines: [source, "Desk", "Example City, Region"])
            XCTAssertEqual(DesktopCardParser.parseLabel(raw, cardIndex: 0)?.priceText, source)
            XCTAssertEqual(DesktopCardParser.parseLines(raw, cardIndex: 0)?.priceText, source)
            XCTAssertEqual(CardLabel.parse("Desk for sale - Used - Good - \(source) in Example City")?.priceText, source)
        }
    }

    func testDiscountsCompareExactDecimalsAndSupportSuffixes() throws {
        for (current, original) in [("R$12,50", "R$12,99"), ("12,50 €", "12,99 €"),
                                    ("₹1,23,456.50", "₹1,23,456.99"),
                                    ("IDR550M", "IDR600M"), ("kr12.50", "kr12.99"),
                                    ("1\u{202f}234,50 €", "1\u{202f}234,99 €")] {
            let pair = try XCTUnwrap(PriceRun.split(current + original))
            XCTAssertEqual(pair.current, current)
            XCTAssertEqual(pair.original, original)
            XCTAssertNil(PriceRun.split(original + current))
            XCTAssertNil(PriceRun.split(current + current))
        }
        XCTAssertNil(PriceRun.split("CA$10US$20"))
        XCTAssertNil(PriceRun.split("€10€20€30"))
        XCTAssertNil(PriceRun.split("€10 - €20"))
        XCTAssertEqual(PriceGuide.parse("€1.200,50 – €1.400,99"), 1200)
    }

    func testDisplayShortensSymbolsWithoutChangingSourceOrSeparators() {
        let samples = [
            "CA$1,234.56": "$1,234.56", "CAD12.50": "$12.50", "C$50": "$50",
            "US$20": "$20", "AU$20": "$20", "NZ$20": "$20", "NT$20": "$20",
            "GBP12.50": "£12.50", "£12.50": "£12.50", "MX$1,234": "$1,234",
            "PHP1,234.50": "₱1,234.50", "IDR1,234,567": "Rp1,234,567",
            "BDT1,234": "৳1,234", "NGN1,234": "₦1,234", "TRY1,234": "₺1,234",
            "ZAR1,234": "R1,234", "ARS1,234": "$1,234", "COP1,234": "$1,234",
            "1\u{202f}234,56 EUR": "1\u{202f}234,56 €", "Free": "Free",
            "CA$20 – CA$40": "$20 – $40",
        ]
        for (source, expected) in samples {
            let listing = Listing(id: "test", priceText: source, originalPriceText: source,
                                  cardIndex: 0, capturedAt: Date())
            XCTAssertEqual(listing.displayPrice, expected)
            XCTAssertEqual(listing.displayOriginalPrice, expected)
            XCTAssertEqual(listing.priceText, source)
            XCTAssertEqual(listing.originalPriceText, source)
        }
        var comp = MarketComp(listing: Listing(id: "test", priceText: "CA$100",
                                             cardIndex: 0, capturedAt: Date()))
        comp.relevance = .included
        let guide = PriceGuide(comps: [comp])
        XCTAssertEqual(guide.currency, "CA$")
        XCTAssertEqual(guide.money(100), "$100")
        var summary = PriceCheckSummary()
        summary.currencySymbol = "CA$"
        summary.recommendedPriceMinor = 10000
        let past = PastPriceCheck(summary)
        XCTAssertEqual(past.currency, "CA$")
        XCTAssertEqual(past.priceText, "$100")
    }

    func testMalformedPricesNeverBecomePlausibleAmounts() {
        for source in ["Desk1", "Free delivery", "CA$12,34,567,89", "€1.23.45", "€1,234.567",
                       "₹1,234,56", "€12 34", "$-10", "¥25", "₩25", "USD12oops",
                       "€999999999999999999999999999999999999999", "R2D2", "£12.50.99"] {
            XCTAssertNil(MarketplacePrice.parse(source), source)
            XCTAssertFalse(PriceRun.isPrice(source), source)
            XCTAssertNil(PriceGuide.parse(source), source)
            XCTAssertEqual(MarketplacePrice.display(source), source)
        }
    }

    func testLocalizedFreePrices() {
        for source in ["Free", "FREE", "Gratuit", "Gratis", "Grátis", "Kostenlos", "Miễn phí", "ฟรี"] {
            XCTAssertEqual(PriceGuide.parse(source), 0, source)
            XCTAssertTrue(PriceRun.isPrice(source), source)
        }
    }

    func testInvalidGraphQLAmountsFailClosed() {
        for amount in ["-100", "123abc", "12.50", "", "9999999999999999999999999"] {
            let raw = #"{"data":{"marketplace_home_feed":{"edges":[{"node":{"__typename":"MarketplaceFeedGeneralListingObject","data":{"title":"Chair","price":{"currency":"VND","amount_with_offset":"\#(amount)"}},"listing":{"id":"202"}}}],"page_info":{"has_next_page":false}}}}"#
            XCTAssertThrowsError(try GraphQLFeedDecoder.decode(Data(raw.utf8), kind: .browse))
        }
    }

    func testPriceGuideGroupsCurrencyAliasesAndExcludesForeignAmounts() {
        let comps = ["VND100000", "₫200,000", "₫300,000", "USD10"].enumerated().map { index, source in
            var comp = MarketComp(listing: Listing(id: String(index), priceText: source,
                                                 cardIndex: index, capturedAt: Date()))
            comp.relevance = .included
            return comp
        }
        let guide = PriceGuide(comps: comps)
        XCTAssertEqual(guide.count, 3)
        XCTAssertEqual(guide.skipped, 1)
        XCTAssertEqual(guide.median, 200000)
        XCTAssertEqual(guide.currency, "VND")
        XCTAssertEqual(guide.money(200000), "₫200000")
        let check = MarketCheck(term: "desk", price: 20, comps: comps, sold: SoldSignal(comps: []),
                                marketName: "Example", currencySymbol: "USD")
        XCTAssertEqual(check.guide.count, 1)
        XCTAssertEqual(check.guide.median, 10)
        XCTAssertEqual(check.standing, .above)
    }
}

private struct CurrencyCardsPreview: View {
    @Namespace private var namespace
    private let examples = [("Canada", "CA$1,234.50"), ("United Kingdom", "£1,234.50"),
                            ("France", "1\u{202f}234,50 €"), ("Brazil", "R$1.234,50"),
                            ("India", "₹1,23,456.50"), ("Indonesia", "IDR550M")]

    var body: some View {
        VStack(spacing: 20) {
            ForEach(0..<3) { row in
                HStack(alignment: .top, spacing: 12) {
                    ForEach(0..<2) { column in
                        let example = examples[row * 2 + column]
                        ListingCard(listing: Listing(id: example.0, title: example.0, priceText: example.1,
                                                     cardIndex: 0, capturedAt: Date()), namespace: namespace)
                    }
                }
            }
        }
    }
}
