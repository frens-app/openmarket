import Foundation

/// Facebook can concatenate adjacent current and struck-through prices.
/// Keep source strings intact; only split an ascending pair in one currency.
enum PriceRun {
    static func isPrice(_ text: String) -> Bool {
        MarketplacePrice.parse(text) != nil
    }

    static func split(_ text: String) -> (current: String, original: String)? {
        MarketplacePrice.split(text)
    }

    static func resolve(price: String?, original: String?) -> (price: String?, original: String?) {
        guard original == nil, let price, let pair = split(price) else { return (price, original) }
        return (pair.current, pair.original)
    }
}
