import Foundation

/// Supported Marketplace regions and the price prefixes their listings use.
struct MarketRegion: Equatable, Identifiable {
    let countryCode: String
    let currencyCode: String
    let marketplaceVerified: Bool

    var id: String { countryCode }
    var currency: MarketCurrency { MarketCurrency.currency(code: currencyCode)! }
    var pricePrefixes: [String] { currency.symbols }

    static let unitedStates = MarketRegion("US", currencyCode: "USD")
    static let canada = MarketRegion("CA", currencyCode: "CAD")

    private init(_ countryCode: String, currencyCode: String) {
        self.countryCode = countryCode
        self.currencyCode = currencyCode
        self.marketplaceVerified = true
    }

    static let all: [MarketRegion] = [
        unitedStates, canada,
        MarketRegion("GB", currencyCode: "GBP"),
        MarketRegion("IE", currencyCode: "EUR"),
        MarketRegion("AU", currencyCode: "AUD"),
        MarketRegion("NZ", currencyCode: "NZD"),
        MarketRegion("ES", currencyCode: "EUR"),
        MarketRegion("DK", currencyCode: "DKK"),
        MarketRegion("NL", currencyCode: "EUR"),
        MarketRegion("TW", currencyCode: "TWD"),
        MarketRegion("FR", currencyCode: "EUR"),
        MarketRegion("IT", currencyCode: "EUR"),
        MarketRegion("DE", currencyCode: "EUR"),
        MarketRegion("MX", currencyCode: "MXN"),
        MarketRegion("PH", currencyCode: "PHP"),
        MarketRegion("BR", currencyCode: "BRL"),
        MarketRegion("IN", currencyCode: "INR"),
        MarketRegion("ID", currencyCode: "IDR"),
        MarketRegion("VN", currencyCode: "VND"),
        MarketRegion("BD", currencyCode: "BDT"),
        MarketRegion("PK", currencyCode: "PKR"),
        MarketRegion("EG", currencyCode: "EGP"),
        MarketRegion("TH", currencyCode: "THB"),
        MarketRegion("NG", currencyCode: "NGN"),
        MarketRegion("CO", currencyCode: "COP"),
        MarketRegion("TR", currencyCode: "TRY"),
        MarketRegion("AR", currencyCode: "ARS"),
        MarketRegion("ZA", currencyCode: "ZAR"),
        MarketRegion("DZ", currencyCode: "DZD"),
    ]

    static func region(countryCode: String?) -> MarketRegion? {
        guard let countryCode else { return nil }
        return all.first { $0.countryCode.caseInsensitiveCompare(countryCode) == .orderedSame }
    }

    /// Price recognition follows verified browsing support.
    static var supportedPricePrefixes: [String] {
        Array(Set(all.filter(\.marketplaceVerified).flatMap(\.pricePrefixes)))
            .sorted { lhs, rhs in
                lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
            }
    }

    static var verifiedMarketplaceCountryCodes: Set<String> {
        Set(all.filter(\.marketplaceVerified).map(\.countryCode))
    }

    static let unsupportedMarketplaceMessage =
        "Marketplace browsing isn't available in that country yet."
}
