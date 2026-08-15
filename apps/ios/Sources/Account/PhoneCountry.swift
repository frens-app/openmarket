import Foundation

/// A country the sign-in screen can offer a number for.
///
/// Which countries are *served* is the server's answer, not this table's:
/// `GetSignInOptions` returns the calling codes it will send to, and everything
/// here is the presentation and entry rules for them. A served code this table
/// has never heard of is still offered, labelled with the code itself, so
/// opening a market stays an env var on the API rather than an app release.
struct PhoneCountry: Identifiable, Hashable {
    /// ISO 3166-1 alpha-2, or empty for a served code with no entry here.
    let regionCode: String
    /// Calling code without the '+'.
    let callingCode: String
    /// National significant digits, where the length is known. Nil means
    /// unknown, not unbounded — see `digitRange`.
    let nationalDigits: ClosedRange<Int>?
    let example: String?
    /// Whether a leading zero is part of the number.
    ///
    /// Almost nowhere, which is why stripping it is the default: the trunk '0'
    /// is a domestic dialling convention and an E.164 national number never
    /// carries one. Italian landlines are the standing exception.
    let keepsLeadingZero: Bool

    init(
        _ regionCode: String,
        _ callingCode: String,
        nationalDigits: ClosedRange<Int>? = nil,
        example: String? = nil,
        keepsLeadingZero: Bool = false
    ) {
        self.regionCode = regionCode
        self.callingCode = callingCode
        self.nationalDigits = nationalDigits
        self.example = example
        self.keepsLeadingZero = keepsLeadingZero
    }

    var id: String { regionCode.isEmpty ? "+" + callingCode : regionCode }

    var name: String {
        guard !regionCode.isEmpty else { return "+" + callingCode }
        return Locale.current.localizedString(forRegionCode: regionCode) ?? regionCode
    }

    /// What the button beside the phone field says. The ISO code and not a flag
    /// emoji: the Simulator has no glyphs for regional indicators and draws two
    /// empty boxes.
    var shortLabel: String {
        regionCode.isEmpty ? "+" + callingCode : regionCode + " +" + callingCode
    }

    var placeholder: String { example ?? "Phone number" }

    /// How many national digits to accept, falling back to what E.164 itself
    /// guarantees: four digits up to the fifteen it allows in total.
    ///
    /// Deliberately generous, for the reason `Allowlist.Parse` in the backend
    /// gives for checking no length at all — the carrier is the only authority
    /// on which numbers exist, and a guess rejects real ones.
    var digitRange: ClosedRange<Int> {
        nationalDigits ?? 4...(15 - callingCode.count)
    }

    func accepts(nationalDigitCount count: Int) -> Bool { digitRange.contains(count) }

    /// Named because it is the last resort when nothing else resolves, and the
    /// country the debug bypass number belongs to.
    static let unitedStates = PhoneCountry("US", "1", nationalDigits: 10...10, example: "(415) 555-0123")

    /// Codes to offer when the server has never been reached — a first launch
    /// with no network. Matches the API's shipped `ALLOWED_COUNTRY_CODES`.
    static let fallbackCallingCodes = ["1", "44", "353", "61", "64"]

    /// The countries served by `callingCodes`, sorted by name.
    ///
    /// One calling code can name several countries (+1 is the US and Canada),
    /// and a code with no entry here becomes one unnamed row rather than
    /// disappearing.
    static func served(callingCodes: [String]) -> [PhoneCountry] {
        let wanted = Set(callingCodes)
        var offered = all.filter { wanted.contains($0.callingCode) }
        let covered = Set(offered.map(\.callingCode))
        offered += wanted.subtracting(covered).map { PhoneCountry("", $0) }
        return offered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The row to start on: this phone's own region when it is served.
    static func preferred(in countries: [PhoneCountry]) -> PhoneCountry? {
        let region = Locale.current.region?.identifier
        return countries.first { $0.regionCode == region } ?? countries.first
    }

    /// The served countries, and no more. Names come from `Locale`, so a row is
    /// an ISO code, a calling code, and the entry facts that vary. Adding one
    /// here does not serve it — `ALLOWED_COUNTRY_CODES` on the API does, and a
    /// market opened there works before a row exists for it.
    static let all: [PhoneCountry] = [
        unitedStates,
        PhoneCountry("CA", "1", nationalDigits: 10...10, example: "(416) 555-0123"),
        PhoneCountry("GB", "44", nationalDigits: 9...10, example: "07911 123456"),
        PhoneCountry("IE", "353", nationalDigits: 7...9, example: "085 012 3456"),
        PhoneCountry("AU", "61", nationalDigits: 9...9, example: "0412 345 678"),
        PhoneCountry("NZ", "64", nationalDigits: 8...10, example: "021 123 4567"),

        // The one row here for a country that is not served: Italy is where
        // the default leading-zero strip is wrong, and that is easier to keep
        // than to rediscover. Every other unserved market shows as its calling
        // code until a release names it.
        PhoneCountry("IT", "39", keepsLeadingZero: true),
    ]
}
