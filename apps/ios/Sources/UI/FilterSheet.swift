import SwiftUI

/// A city Facebook will accept in a search path.
///
/// Location is the one thing that genuinely moves a result set — it is a path
/// segment, and it works on both surfaces. Everything else about location is
/// decorative: `latitude`/`longitude` are discarded in favour of the
/// IP-inferred place, and `radius` doesn't filter anywhere
/// (`docs/filter-parameters.md`).
struct MarketplaceCity: Identifiable, Hashable {
    let name: String
    let slug: String
    var id: String { slug }

    /// **Five of the twelve entries here were wrong** — `berkeley`, `dalycity`,
    /// `paloalto`, `fremont` and `marin` are not places Facebook recognises. It
    /// does not say so: it rewrites the path to `/marketplace/category/search/`
    /// and serves the IP-inferred city, so picking Berkeley returned San
    /// Francisco listings with nothing on screen admitting it
    /// (`docs/location-targeting.md` §1, measured 2026-08-06).
    ///
    /// The comment they shipped under claimed the slugs were "verified to
    /// relocate the result set" — true of the three anyone checked, assumed of
    /// the rest. Only the seven measured to work are listed now.
    ///
    /// This whole list is a stopgap. Slugs are a guess at a name in a global
    /// namespace — `richmond` resolves to Richmond *Virginia* — so the real fix
    /// is resolving the user's own location to a numeric place id, which every
    /// search payload already carries (§6, §7).
    static let common: [MarketplaceCity] = [
        MarketplaceCity(name: "San Francisco", slug: "sanfrancisco"),
        MarketplaceCity(name: "Oakland", slug: "oakland"),
        MarketplaceCity(name: "San Jose", slug: "sanjose"),
        MarketplaceCity(name: "Los Angeles", slug: "la"),
        MarketplaceCity(name: "New York", slug: "nyc"),
        MarketplaceCity(name: "Seattle", slug: "seattle"),
        MarketplaceCity(name: "Chicago", slug: "chicago")
    ]

    static func named(_ slug: String?) -> MarketplaceCity? {
        guard let slug else { return nil }
        return common.first { $0.slug == slug }
    }
}

/// Every filter, in one sheet.
///
/// Edits are applied to `Preferences` as they happen — the controls are bound
/// straight to it — and the search only re-runs when the sheet is dismissed via
/// **Show results**. Re-running on each toggle would fire three or four
/// searches while someone sets up one query, which is both slow and exactly the
/// kind of traffic that risks a login wall.
struct FilterSheet: View {
    @EnvironmentObject private var prefs: Preferences
    @Environment(\.dismiss) private var dismiss

    /// Called on dismissal, and only if something actually changed.
    var onApply: () -> Void

    /// Snapshotted on appear so dismissal can tell whether a re-run is needed.
    @State private var original: FilterSnapshot?
    @State private var minPriceText = ""
    @State private var maxPriceText = ""
    @State private var showLocationPicker = false

    /// What a change to any of these costs: a fresh search.
    ///
    /// `hideViewed` is absent from `requiresRerun` — it applies to listings
    /// already on screen, so re-running would fetch the same cards minus some.
    /// It is still recorded: a free filter is still a filter somebody chose.
    private struct FilterSnapshot: Equatable {
        var sort: SearchQuery.Sort
        var delivery: SearchQuery.Delivery
        var minPrice: Int?
        var maxPrice: Int?
        var conditions: [SearchQuery.Condition]
        var citySlug: String?
        var hideViewed: Bool
        /// Tracked for the diff but absent from `requiresRerun`: distance is
        /// applied on this device, and `ResultsView` already watches it.
        var radiusKM: Int

        /// The subset that goes back to Facebook — compared separately from
        /// `==` so a local-only toggle records without costing a page load.
        func requiresRerun(against other: FilterSnapshot) -> Bool {
            sort != other.sort
                || delivery != other.delivery
                || minPrice != other.minPrice
                || maxPrice != other.maxPrice
                || conditions != other.conditions
                || citySlug != other.citySlug
        }

        /// Which fields moved, as the strings the event carries.
        func changes(from other: FilterSnapshot) -> [String] {
            var changed: [String] = []
            if sort != other.sort { changed.append("sort") }
            if delivery != other.delivery { changed.append("delivery") }
            if minPrice != other.minPrice { changed.append("min_price") }
            if maxPrice != other.maxPrice { changed.append("max_price") }
            if conditions != other.conditions { changed.append("condition") }
            if citySlug != other.citySlug { changed.append("location") }
            if hideViewed != other.hideViewed { changed.append("hide_viewed") }
            if radiusKM != other.radiusKM { changed.append("distance") }
            return changed
        }
    }

    private var current: FilterSnapshot {
        FilterSnapshot(sort: prefs.sort, delivery: prefs.delivery,                        minPrice: prefs.minPrice, maxPrice: prefs.maxPrice,
                       conditions: prefs.conditions, citySlug: prefs.locationSlug,
                       hideViewed: prefs.hideViewed, radiusKM: prefs.radiusKM)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    section("Sort by") { sortControl }
                    // Distance moved in with the location picker. The two are
                    // read as one phrase — "San Francisco · 10 mi" — and having
                    // to visit two sheets to change one phrase was the split
                    // showing through.
                    section("Location", footnote: "Place and distance, together.") {
                        locationControl
                    }
                    section("Viewed", footnote: "Applied on this device — Facebook has no filter like this.") {
                        viewedControl
                    }
                    section("Delivery") { deliveryControl }
                    section("Price") { priceControl }
                    section("Condition") { conditionControl }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showLocationPicker) { LocationPickerSheet() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // No event of its own: Reset only moves filters, and the
                    // `filters_applied` on dismissal carries every one it moved.
                    Button("Reset") {
                        prefs.resetFilters()
                        syncPriceText()
                    }
                    .disabled(!prefs.hasNonDefaultFilters)
                }
            }
            .safeAreaInset(edge: .bottom) { showResults }
            .onAppear {
                original = current
                syncPriceText()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Chrome

    private func section<Content: View>(_ title: String,
                                        footnote: String? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var showResults: some View {
        Button {
            commitPriceText()
            dismiss()
        } label: {
            Text("Show results")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .onDisappear {
            commitPriceText()
            guard let original, original != current else { return }
            // One event per dismissal, not per control: setting up a query
            // touches three or four toggles and is one act of filtering.
            captureFiltersApplied(changedFrom: original)
            // Only re-run if the query would actually differ. Dismissing a
            // sheet you only looked at should cost nothing, and neither should
            // a local-only toggle.
            if current.requiresRerun(against: original) { onApply() }
        }
    }

    // MARK: - Controls

    private var sortControl: some View {
        wrapping(SearchQuery.Sort.allCases, id: \.self) { option in
            pill(option.label, isOn: prefs.sort == option) { prefs.sort = option }
        }
    }

    /// Opens the picker rather than listing cities inline.
    ///
    /// There is no list any more: any place Apple can find is a place this can
    /// browse, because Facebook does the naming (`LocationPickerSheet`).
    private var locationControl: some View {
        Button {
            showLocationPicker = true
        } label: {
            HStack {
                Image(systemName: "mappin.and.ellipse")
                Text(prefs.locationName ?? "Choose a location")
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
        }
        .foregroundStyle(.primary)
    }

    /// The one filter with no remote counterpart at all. Distance at least has
    /// a `radius` parameter Facebook ignores; this has nothing on the other end
    /// — it runs entirely off what the app itself remembers.
    private var viewedControl: some View {
        Toggle(isOn: $prefs.hideViewed) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Only new listings").font(.subheadline)
                Text("Hide anything you've already opened")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var deliveryControl: some View {
        VStack(spacing: 0) {
            deliveryRow(.localPickup, "Local pickup", "Collect in person")
            Divider()
            deliveryRow(.any, "Any", "Including items that ship")
            Divider()
            deliveryRow(.shipping, "Shipping", "Delivered to you")
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private func deliveryRow(_ value: SearchQuery.Delivery,
                             _ title: String, _ subtitle: String) -> some View {
        Button { prefs.delivery = value } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if prefs.delivery == value {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var priceControl: some View {
        HStack(spacing: 12) {
            priceField("Min", text: $minPriceText)
            Text("—").foregroundStyle(.secondary)
            priceField("Max", text: $maxPriceText)
        }
    }

    private func priceField(_ label: String, text: Binding<String>) -> some View {
        HStack(spacing: 4) {
            Text("$").foregroundStyle(.secondary)
            TextField(label, text: text)
                .keyboardType(.numberPad)
        }
        .font(.subheadline)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var conditionControl: some View {
        wrapping(SearchQuery.Condition.allCases, id: \.self) { condition in
            pill(condition.label, isOn: prefs.conditions.contains(condition)) {
                if let index = prefs.conditions.firstIndex(of: condition) {
                    prefs.conditions.remove(at: index)
                } else {
                    prefs.conditions.append(condition)
                }
            }
        }
    }

    // MARK: - Bits

    /// Chips that wrap onto as many lines as they need. `Layout` rather than a
    /// horizontal `ScrollView` so nothing is hidden off the edge — a filter the
    /// user can't see is a filter they won't use.
    private func wrapping<Data: RandomAccessCollection, ID: Hashable, Content: View>(
        _ data: Data,
        id: KeyPath<Data.Element, ID>,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) -> some View {
        WrapLayout(spacing: 8) {
            ForEach(data, id: id) { item in content(item) }
        }
    }

    private func pill(_ text: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    Capsule().fill(isOn ? Color.accentColor : Color(.secondarySystemBackground))
                )
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    /// What changed, and what it ended up as — the first says which controls
    /// get used, the second what a real query looks like.
    private func captureFiltersApplied(changedFrom original: FilterSnapshot) {
        Analytics.capture(.filtersApplied, [
            "source": Analytics.Surface.filterSheet.rawValue,
            "changed": current.changes(from: original),
            "sort": prefs.sort.rawValue,
            "delivery": prefs.delivery == .any ? "any" : prefs.delivery.rawValue,
            "radius_km": prefs.radiusKM,
            "has_min_price": prefs.minPrice != nil,
            "has_max_price": prefs.maxPrice != nil,
            "condition_count": prefs.conditions.count,
            "hide_viewed": prefs.hideViewed
        ])
    }

    // Price is held as text while editing so a half-typed "1" isn't
    // immediately committed as a £1 ceiling.
    private func syncPriceText() {
        minPriceText = prefs.minPrice.map(String.init) ?? ""
        maxPriceText = prefs.maxPrice.map(String.init) ?? ""
    }

    private func commitPriceText() {
        prefs.minPrice = Int(minPriceText.filter(\.isNumber))
        prefs.maxPrice = Int(maxPriceText.filter(\.isNumber))
    }
}

/// Flow layout: lays children left to right, wrapping when the line is full.
struct WrapLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: width, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
