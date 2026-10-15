import Foundation

/// Supported Marketplace regions and the price prefixes their listings use.
struct MarketRegion: Equatable, Identifiable {
    let countryCode: String
    let pricePrefixes: [String]
    let marketplaceVerified: Bool

    var id: String { countryCode }

    init(
        _ countryCode: String,
        pricePrefixes: [String],
        marketplaceVerified: Bool
    ) {
        self.countryCode = countryCode
        self.pricePrefixes = pricePrefixes
        self.marketplaceVerified = marketplaceVerified
    }

    static let unitedStates = MarketRegion(
        "US", pricePrefixes: ["US$", "$"], marketplaceVerified: true
    )

    static let canada = MarketRegion(
        "CA", pricePrefixes: ["CA$", "C$"], marketplaceVerified: true
    )

    static let all: [MarketRegion] = [
        unitedStates,
        canada,
        MarketRegion(
            "GB",
            pricePrefixes: ["£"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "IE",
            pricePrefixes: ["€"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "AU",
            pricePrefixes: ["AU$", "A$"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "NZ",
            pricePrefixes: ["NZ$"],
            marketplaceVerified: true
        ),

        MarketRegion(
            "ES", pricePrefixes: ["€"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "DK", pricePrefixes: ["DKK", "kr.", "kr"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "NL", pricePrefixes: ["€"],
            marketplaceVerified: true
        ),
        MarketRegion(
            "TW", pricePrefixes: ["NT$", "TWD"],
            marketplaceVerified: true
        ),

        MarketRegion(
            "IT",
            pricePrefixes: ["€"],
            marketplaceVerified: false
        ),
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
