import Foundation

/// The location pill the **desktop** search page renders under its filter row —
/// "San Francisco, California · Within 5 mi".
///
/// Source: the pill's own `aria-label` (`"Location: San Francisco, California,
/// Within 5 mi"`), falling back to its rendered text. Desktop only — the mobile
/// surface renders a bare "Distance" chip with no place in it, and no pill at
/// all on a search page. Extracted by `DesktopScripts.extractLocationPill`.
///
/// Worth reading for two things the URL cannot give: the place as a **display
/// name** rather than a slug or an id, and the **radius**, which is expressed
/// nowhere else in the document.
///
/// It is a claim, not a measurement. The radius shown here does not filter
/// anything — `radius=8` and `radius=161` return the same listings, and a page
/// labelled "Within 5 mi" carries listings 60 mi out (`docs/filter-parameters.md`
/// Read it to know what Facebook believes, never to conclude what it did.
struct DesktopLocationPill: Equatable {
    /// "San Francisco, California", as rendered.
    var placeName: String?
    /// The radius as written, in whichever unit the pill used.
    var radius: Measurement<UnitLength>?
    /// Whatever the pill actually said, kept so a bad parse is visible instead
    /// of silently producing a plausible value (`docs/probe-checklist.md` §6).
    var rawPillText: String

    /// Rounded kilometres, the unit `Preferences.radiusKM` stores.
    var radiusKM: Int? {
        radius.map { Int($0.converted(to: .kilometers).value.rounded()) }
    }

    /// Rounded miles, the unit the app's own UI speaks.
    var radiusMiles: Int? {
        radius.map { Int($0.converted(to: .miles).value.rounded()) }
    }

    /// Both observed shapes, and the ones either side of them:
    ///
    ///     "Location: San Francisco, California, Within 5 mi"   (aria-label)
    ///     "San Francisco, California · Within 5 mi"            (rendered text)
    ///     "San Francisco · 8 km"
    ///
    /// The radius is matched first and cut out; whatever remains is the place.
    /// That order is what lets one parser handle "Within 5 mi", "· 5 mi", a
    /// kilometre pill, and a pill carrying no radius at all.
    init(rawPillText: String) {
        self.rawPillText = rawPillText
        var remainder = rawPillText.trimmingCharacters(in: .whitespacesAndNewlines)

        // The aria-label's prefix. A missing one isn't a failure — a localised
        // build says something else, and the rendered-text form has no prefix.
        for prefix in ["Location:", "Location"] where remainder.hasPrefix(prefix) {
            remainder = String(remainder.dropFirst(prefix.count))
            break
        }

        if let match = Self.radiusPattern.firstMatch(
            in: remainder,
            range: NSRange(remainder.startIndex..., in: remainder)
        ) {
            if let valueRange = Range(match.range(at: 1), in: remainder),
               let unitRange = Range(match.range(at: 2), in: remainder),
               let value = Double(remainder[valueRange]) {
                let unit: UnitLength = remainder[unitRange].lowercased().hasPrefix("k")
                    ? .kilometers : .miles
                radius = Measurement(value: value, unit: unit)
            }
            if let whole = Range(match.range, in: remainder) {
                remainder.removeSubrange(whole)
            }
        }

        let name = remainder.trimmingCharacters(in: Self.separators)
        placeName = name.isEmpty ? nil : name
    }

    /// `Within 5 mi`, `· 8 km`, `5 miles`, `12.5 km`. "Within" is consumed by
    /// the match so it cannot survive into the place name.
    private static let radiusPattern = try! NSRegularExpression(
        pattern: "(?:within\\s+)?(\\d+(?:\\.\\d+)?)\\s*(mi|mile|miles|km|kilometre|kilometres|kilometer|kilometers)\\b",
        options: [.caseInsensitive]
    )

    private static let separators = CharacterSet(charactersIn: " ,·-–—|\u{00A0}")
        .union(.whitespacesAndNewlines)
}

/// Where a loaded **desktop** page actually is, read from both instruments at
/// once: the URL's place segment and the page's own location pill.
///
/// Neither is sufficient alone, and that is the point of pairing them. The URL
/// says whether our request survived; the pill says what Facebook resolved it
/// to. A page can carry an accepted slug *and* a pill naming another state —
/// `richmond` is accepted and served as Richmond, Virginia — so agreement
/// between the two is the real check, not either one by itself.
struct DesktopPageLocation: Equatable {
    /// From `URL.pathComponents`.
    var urlPlace: MarketplaceURLPlace
    /// From the rendered pill. Nil when the page hasn't drawn one — a login
    /// wall, a still-loading document, or the mobile surface.
    var pill: DesktopLocationPill?

    /// Was the requested place accepted? False only when Facebook rewrote it.
    var wasAccepted: Bool { urlPlace != .refused }

    /// Does the pill agree with the place we believe we asked for?
    ///
    /// Compared loosely — "San Francisco, California" against "San Francisco" —
    /// since the pill renders a display name while the request carries a slug or
    /// an id. **Nil means unknown** (no pill, or nothing to compare against),
    /// which callers must not treat as a failure: a page mid-load has no pill.
    func pillAgrees(withRequestedName expected: String?) -> Bool? {
        guard let expected, let shown = pill?.placeName else { return nil }
        let a = Self.simplify(expected), b = Self.simplify(shown)
        guard !a.isEmpty, !b.isEmpty else { return nil }
        return b.hasPrefix(a) || a.hasPrefix(b)
    }

    private static func simplify(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// One line for the log: what was asked for, and what came back.
    var summary: String {
        let place = pill?.placeName ?? "unknown place"
        let radius = pill?.radiusMiles.map { "\($0) mi" } ?? "no radius"
        switch urlPlace {
        case .citySlug(let value): return "slug \(value) -> \(place), \(radius)"
        case .placeID(let value): return "id \(value) -> \(place), \(radius)"
        case .ipInferred: return "IP-inferred -> \(place), \(radius)"
        case .refused: return "REFUSED, serving \(place), \(radius)"
        case .notAPlaceURL: return "no place in URL"
        }
    }
}
