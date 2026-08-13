import Foundation

/// Something the user says they shop for.
///
/// The only piece of taste this app collects. It exists to answer "what would
/// you type" for someone who hasn't typed anything yet: the search field offers
/// these under "Try", where a new install would otherwise get a fixed list of
/// categories that had nothing to do with anybody.
///
/// The search suggestions are the whole of the job (`docs/discover.md` §6.1) —
/// Discover is Facebook's own browse feed for everybody. Chosen in Settings, and
/// picking none is allowed: `Interest.defaults` fills the "Try" row for anyone
/// who never goes looking.
///
/// Stored as `id` strings in `Preferences.interests`, never as labels or search
/// terms. Both of those are presentation decisions that should be changeable —
/// re-wording a chip or improving what it searches for must not silently empty
/// somebody's saved choices.
struct Interest: Identifiable, Hashable {
    let id: String
    /// What the chip says.
    let label: String
    /// What actually gets searched.
    ///
    /// Not always the label, because Marketplace search is a fuzzy match over
    /// listing text rather than a category filter — nobody titles a listing
    /// "Home & garden". The term is the searchable half of the category, and it
    /// is US-spelled where that differs from the label, because the listings
    /// are.
    let term: String
    let prominence: Prominence

    /// How large the chip is drawn, and nothing else.
    ///
    /// A judgement about how many people shop for a category, not a
    /// measurement — there is no data behind it and it shouldn't pretend
    /// otherwise. It earns its place because eighteen identical chips are a
    /// wall of text: three sizes let the eye land on the broad categories first
    /// while the long tail stays reachable. Ranking one wrong costs a few
    /// points of type size.
    enum Prominence: Int {
        case broad = 2, common = 1, specific = 0
    }

    /// Ordered broad-first, which is also roughly the order people scan.
    static let catalogue: [Interest] = [
        Interest(id: "furniture", label: "Furniture", term: "furniture", prominence: .broad),
        Interest(id: "electronics", label: "Electronics", term: "electronics", prominence: .broad),
        Interest(id: "clothing", label: "Clothing", term: "clothing", prominence: .broad),
        Interest(id: "home", label: "Home & garden", term: "home decor", prominence: .broad),
        Interest(id: "cars", label: "Cars", term: "car", prominence: .broad),
        Interest(id: "baby", label: "Baby & kids", term: "baby", prominence: .common),
        Interest(id: "toys", label: "Toys & games", term: "toys", prominence: .common),
        Interest(id: "bikes", label: "Bikes", term: "bike", prominence: .common),
        Interest(id: "tools", label: "Tools", term: "tools", prominence: .common),
        Interest(id: "plants", label: "Plants", term: "plants", prominence: .common),
        Interest(id: "sports", label: "Sports gear", term: "sports equipment", prominence: .common),
        Interest(id: "appliances", label: "Appliances", term: "appliances", prominence: .common),
        Interest(id: "books", label: "Books & media", term: "books", prominence: .common),
        Interest(id: "instruments", label: "Musical instruments", term: "musical instrument", prominence: .specific),
        Interest(id: "pets", label: "Pet supplies", term: "pet supplies", prominence: .specific),
        Interest(id: "art", label: "Art & collectibles", term: "art", prominence: .specific),
        Interest(id: "jewellery", label: "Jewellery", term: "jewelry", prominence: .specific),
        Interest(id: "free", label: "Free stuff", term: "free stuff", prominence: .specific)
    ]

    /// What to fall back on when there are no chosen interests to read.
    ///
    /// Onboarding makes that unreachable in a shipped app — nobody gets to the
    /// home screen without picking three — so this covers previews, tests, and
    /// any future path that reaches Discover before the choice has been made.
    /// It is the broad row rather than a separate hand-written list, so there
    /// is only one place where categories are named.
    static let defaults: [Interest] = catalogue.filter { $0.prominence == .broad }

    static func named(_ id: String) -> Interest? { byID[id] }

    /// Resolves stored ids, dropping any this build no longer knows about — a
    /// category can be renamed or retired without stranding an install on a
    /// term nothing will ever search.
    static func resolve(_ ids: [String]) -> [Interest] { ids.compactMap(named) }

    private static let byID = Dictionary(uniqueKeysWithValues: catalogue.map { ($0.id, $0) })
}
