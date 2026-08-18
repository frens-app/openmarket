import Foundation

/// One source of truth for the country-shaped capabilities the app exposes.
///
/// A phone number's country and the Marketplace being browsed are independent:
/// somebody in Toronto can sign in with a British number. That is why the two
/// permissions stay separate, even though their configuration lives together.
/// Keeping the price prefixes beside them prevents a country from being added
/// to the shipped phone fallback without also stating how its prices render.
struct MarketRegion: Equatable, Identifiable {
    let countryCode: String
    let callingCode: String
    let nationalDigits: ClosedRange<Int>?
    let phoneExample: String?
    let keepsLeadingZero: Bool
    let pricePrefixes: [String]
    let phoneEnabledByDefault: Bool
    let marketplaceVerified: Bool

    var id: String { countryCode }

    init(
        _ countryCode: String,
        callingCode: String,
        nationalDigits: ClosedRange<Int>? = nil,
        phoneExample: String? = nil,
        keepsLeadingZero: Bool = false,
        pricePrefixes: [String],
        phoneEnabledByDefault: Bool,
        marketplaceVerified: Bool
    ) {
        self.countryCode = countryCode
        self.callingCode = callingCode
        self.nationalDigits = nationalDigits
        self.phoneExample = phoneExample
        self.keepsLeadingZero = keepsLeadingZero
        self.pricePrefixes = pricePrefixes
        self.phoneEnabledByDefault = phoneEnabledByDefault
        self.marketplaceVerified = marketplaceVerified
    }

    static let unitedStates = MarketRegion(
        "US", callingCode: "1", nationalDigits: 10...10,
        phoneExample: "(415) 555-0123", pricePrefixes: ["US$", "$"],
        phoneEnabledByDefault: true, marketplaceVerified: true
    )

    static let canada = MarketRegion(
        "CA", callingCode: "1", nationalDigits: 10...10,
        phoneExample: "(416) 555-0123", pricePrefixes: ["CA$", "C$"],
        phoneEnabledByDefault: true, marketplaceVerified: true
    )

    static let all: [MarketRegion] = [
        unitedStates,
        canada,
        MarketRegion(
            "GB", callingCode: "44", nationalDigits: 9...10,
            phoneExample: "07911 123456", pricePrefixes: ["£"],
            phoneEnabledByDefault: true, marketplaceVerified: true
        ),
        MarketRegion(
            "IE", callingCode: "353", nationalDigits: 7...9,
            phoneExample: "085 012 3456", pricePrefixes: ["€"],
            phoneEnabledByDefault: true, marketplaceVerified: true
        ),
        MarketRegion(
            "AU", callingCode: "61", nationalDigits: 9...9,
            phoneExample: "0412 345 678", pricePrefixes: ["AU$", "A$"],
            phoneEnabledByDefault: true, marketplaceVerified: true
        ),
        MarketRegion(
            "NZ", callingCode: "64", nationalDigits: 8...10,
            phoneExample: "021 123 4567", pricePrefixes: ["NZ$"],
            phoneEnabledByDefault: true, marketplaceVerified: true
        ),

        // Retained for correct E.164 entry if the server enables +39. Italy's
        // leading zero is part of landline numbers, unlike the trunk prefix in
        // the markets above. It is not in the offline phone fallback.
        MarketRegion(
            "IT", callingCode: "39", keepsLeadingZero: true,
            pricePrefixes: ["€"], phoneEnabledByDefault: false,
            marketplaceVerified: false
        ),
    ]

    static func region(countryCode: String?) -> MarketRegion? {
        guard let countryCode else { return nil }
        return all.first { $0.countryCode.caseInsensitiveCompare(countryCode) == .orderedSame }
    }

    /// Calling codes used if the API cannot provide its dynamic allowlist.
    /// De-duplicated because several countries share +1.
    static var defaultPhoneCallingCodes: [String] {
        var seen = Set<String>()
        return all.compactMap { region in
            guard region.phoneEnabledByDefault, seen.insert(region.callingCode).inserted else {
                return nil
            }
            return region.callingCode
        }
    }

    /// Every prefix whose country is in the shipped phone catalog. A market
    /// still needs `marketplaceVerified` before somebody can browse it.
    static var supportedPricePrefixes: [String] {
        Array(Set(all.filter(\.phoneEnabledByDefault).flatMap(\.pricePrefixes)))
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
