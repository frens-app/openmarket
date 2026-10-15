import Foundation

struct MarketCurrency {
    let code: String
    let localSymbol: String
    let aliases: [String]
    // Facebook offsets differ from ISO minor units; see the captured metadata
    // in tools/probe/regional/currencies-2026-10-15.json.
    var facebookOffset: Int = 100

    var symbols: [String] { [code] + aliases + [localSymbol] }

    static let all: [MarketCurrency] = [
        .init(code: "USD", localSymbol: "$", aliases: ["US$"]),
        .init(code: "CAD", localSymbol: "$", aliases: ["CA$", "C$"]),
        .init(code: "GBP", localSymbol: "£", aliases: ["GB£"]),
        .init(code: "EUR", localSymbol: "€", aliases: []),
        .init(code: "AUD", localSymbol: "$", aliases: ["AU$", "A$"]),
        .init(code: "NZD", localSymbol: "$", aliases: ["NZ$"]),
        .init(code: "DKK", localSymbol: "kr", aliases: ["kr."]),
        .init(code: "TWD", localSymbol: "$", aliases: ["NT$"], facebookOffset: 1),
        .init(code: "INR", localSymbol: "₹", aliases: []),
        .init(code: "IDR", localSymbol: "Rp", aliases: ["Rp."], facebookOffset: 1),
        .init(code: "BRL", localSymbol: "R$", aliases: []),
        .init(code: "PHP", localSymbol: "₱", aliases: []),
        .init(code: "MXN", localSymbol: "$", aliases: ["MX$", "Mex$"]),
        .init(code: "VND", localSymbol: "₫", aliases: ["đ"], facebookOffset: 1),
        .init(code: "BDT", localSymbol: "৳", aliases: ["Tk"]),
        .init(code: "PKR", localSymbol: "Rs", aliases: ["Rs."]),
        .init(code: "EGP", localSymbol: "E£", aliases: ["ج.م.", "ج.م", "LE", "L.E."]),
        .init(code: "THB", localSymbol: "฿", aliases: []),
        .init(code: "NGN", localSymbol: "₦", aliases: []),
        .init(code: "COP", localSymbol: "$", aliases: ["CO$", "COL$"], facebookOffset: 1),
        .init(code: "TRY", localSymbol: "₺", aliases: ["TL"]),
        .init(code: "ARS", localSymbol: "$", aliases: ["AR$"]),
        .init(code: "ZAR", localSymbol: "R", aliases: []),
        .init(code: "DZD", localSymbol: "DA", aliases: ["د.ج.", "د.ج"]),
    ]

    static func currency(code: String) -> MarketCurrency? {
        all.first { $0.code == code }
    }

    static func currency(symbol: String) -> MarketCurrency? {
        all.first { $0.symbols.contains { $0.caseInsensitiveCompare(symbol) == .orderedSame } }
    }

    static func localSymbol(for symbol: String) -> String {
        currency(symbol: symbol)?.localSymbol ?? symbol
    }

    static func unambiguousCurrency(symbol: String) -> MarketCurrency? {
        let matches = all.filter { $0.symbols.contains { $0.caseInsensitiveCompare(symbol) == .orderedSame } }
        return matches.count == 1 ? matches.first : nil
    }

    func amount(fromFacebookOffset raw: String) -> Decimal? {
        guard !raw.isEmpty, raw.count <= 18, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let amount = Decimal(string: raw, locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return amount / Decimal(facebookOffset)
    }

    // Keep an explicit currency in synthesized source prices. UI shortening
    // must not erase currency identity from saved listings or observations.
    func sourcePrice(_ amount: Decimal) -> String {
        let parts = NSDecimalNumber(decimal: amount).stringValue.split(separator: ".")
        let grouped = String(parts[0].reversed().enumerated().map { index, digit in
            index > 0 && index.isMultiple(of: 3) ? ",\(digit)" : String(digit)
        }.joined().reversed())
        return code + grouped + (parts.count > 1 ? "." + parts[1] : "")
    }
}
