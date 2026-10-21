import SwiftUI
import CoreLocation
import UIKit

struct ResultsView: View {
    private enum Surface {
        case discover
        case search
    }

    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var distances: DistanceResolver
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var viewed: ViewedListings
    @EnvironmentObject private var discover: DiscoverFeed
    @ObservedObject private var searchAlerts = SearchAlerts.shared
    @Environment(\.scenePhase) private var scenePhase

    @State private var isVisible = false
    @State private var searchText = ""
    @FocusState private var isSearching: Bool
    /// Search is a temporary surface over the home feed, not the owner of it.
    /// Keeping this separate from `store.query` lets Search retain its results
    /// while clearing the field reveals the exact Discover view underneath.
    @State private var surface: Surface = .discover
    @State private var selected: Listing?
    @State private var selectedReferrer: Analytics.Surface = .discover
    @State private var showAccountLink = false
    @State private var linkedProvider: String?
    @State private var showLinkConfirmation = false
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var showSaved = false
    @State private var showLocationPicker = false
    @State private var alertDraft: ListingAlertDraft?
    @State private var selectedSearchAlert: SearchAlert?
    @State private var searchAlertSource = "search"

    @State private var showSignIn = false
    /// One sheet serves two offers — the wall mid-search and the footer at the
    /// end of a feed — and they convert differently.
    @State private var signInSurface: Analytics.Surface = .search

    /// Whether either sheet that can change the radius is up. Discover rebuilds
    /// when this goes false — see the `radiusKM` handler.
    private var isCoveredBySheet: Bool { showSettings || showLocationPicker }

    private var canRecordShownListings: Bool {
        isVisible && scenePhase == .active && !isSearching && selected == nil
            && !showAccountLink && !showSettings && !showLocationPicker && !showFilters && !showSaved && !showSignIn
            && alertDraft == nil && selectedSearchAlert == nil
    }

    /// Which listings the "only new" filter is hiding right now.
    ///
    /// A snapshot of `ViewedListings`, taken when a search runs or the filter is
    /// switched on — never read live, or opening a listing and coming back would
    /// make that card vanish under the user's thumb. "New" means new as of when
    /// you ran this search.
    @State private var hiddenAsViewed: Set<String> = []

    @Namespace private var discoverNamespace
    @Namespace private var searchNamespace

    /// The zero-height marker at the top of the scroll, and the reason there is
    /// a `ScrollViewReader` here. First in the stack rather than attached to a
    /// section, so it works whatever `content` is drawing.
    private static let searchTopAnchor = "search-results-top"

    var body: some View {
        NavigationStack {
            results
        }
    }

    /// The screen, minus its scrolling half: everything presented over the
    /// results or triggered from them, plus the reloads that follow.
    ///
    /// Split from `searchSurface` because the two chains together are past
    /// what the type checker will accept in one expression.
    private var results: some View {
        browseSurfaces
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                searchBar
                if surface == .search && !isSearching {
                    ActiveFilterBar(
                        onLocation: { showLocationPicker = true },
                        onRerun: { Task { await rerunCurrentQuery() } }
                    )
                }
            }
            .background(.bar)
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet()
        }
        .sheet(item: $alertDraft) { draft in
            CreateListingAlertView(draft: draft, created: { _ in })
        }
        .sheet(item: $selectedSearchAlert) { alert in
            SearchAlertDetailsSheet(route: AlertRoute(alertID: alert.id, source: searchAlertSource))
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { profileButton }
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink { FollowingView() } label: {
                    Image(systemName: "person.2")
                }
                .accessibilityLabel("Following")
            }
            ToolbarItem(placement: .topBarTrailing) { savedButton }
        }
        .sheet(isPresented: $showSaved) {
            SavedListingsSheet { listing, position in
                recordListingOpen(listing, from: .saved, at: position)
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showAccountLink, onDismiss: {
            if linkedProvider != nil { showLinkConfirmation = true }
        }) {
            NavigationStack {
                AccountLoginView(isLinking: true) { _ in
                    linkedProvider = account.state.viewer?.signInProvider == "apple" ? "Apple" : "Google"
                    showAccountLink = false
                }
            }
        }
        .alert("Account linked", isPresented: $showLinkConfirmation) {
            Button("Done", role: .cancel) { linkedProvider = nil }
        } message: {
            Text("Use \(linkedProvider ?? "your linked provider") next time you sign in. Your existing account, saved listings, follows, and history are unchanged.")
        }
        .onChange(of: filteredNonLocalIDs, initial: true) { _, ids in
            FilterTotals.shared.recordNonLocal(ids)
        }
        .sheet(isPresented: $showFilters) {
            FilterSheet { refreshVisibleSurfaceAfterFilters() }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(surface: signInSurface) {
                // A signed-in query returns a different result set, not merely a
                // longer one, so both surfaces re-run rather than append.
                // `loadIfNeeded` notices the session change on its own.
                Task {
                    let previous = store.session
                    store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                    if previous == store.session {
                        if surface == .search { await store.retry() }
                        await loadDiscover(force: true)
                    }
                }
            }
        }
        .navigationDestination(item: $selected) { listing in
            DetailView(
                listing: listing,
                namespace: surface == .discover ? discoverNamespace : searchNamespace,
                referrer: selectedReferrer
            )
        }
        .onChange(of: store.session) {
            Task {
                if surface == .search { await store.retry() }
                await loadDiscover()
            }
        }
        // A confirmed change of place, and both surfaces catch up.
        //
        // Observe the coordinate too: two selected points can share one slug.
        // The search refreshes first, then Discover rebuilds behind it.
        .onChange(of: prefs.resolvedPlace) {
            // Set the origin before either feed captures distances for its new pages.
            distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace,
                                                              deviceFix: location.coordinate))
            Task {
                if surface == .search {
                    await rerunCurrentQuery()
                }
                discover.markStale()
                await loadDiscover()
            }
        }
        // The fix can land long after a search starts; hand it straight to
        // the distance resolver whenever it does.
        .onChange(of: location.coordinate?.latitude) {
            distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace, deviceFix: location.coordinate))
        }
        // Clearing the field means "back to what I was browsing." Discover
        // remains mounted underneath Search, so this is only a surface switch:
        // no feed reset, no network request, and no lost scroll position.
        .onChange(of: searchText) { _, text in
            guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { @MainActor in
                await Task.yield()
                if surface == .search {
                    returnToDiscover()
                }
            }
        }
        // Switching the filter on takes its snapshot there and then, so it
        // applies to what's already on screen instead of waiting for the
        // next search. Switching it off drops the snapshot, and everything
        // it was holding back comes straight back.
        .onChange(of: prefs.hideViewed) { _, isOn in
            withAnimation(.easeOut(duration: 0.2)) {
                hiddenAsViewed = isOn ? viewed.allIDs : []
                store.updateHiddenAsViewed(hiddenAsViewed)
            }
        }
        .task {
            distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace, deviceFix: location.coordinate))
        }
        // Filled on arrival, then stands for the rest of the launch:
        // `loadIfNeeded` is a no-op after the first fill, so coming back from a
        // listing or the seller tab finds the same cards in the same places.
        .task { await loadDiscover() }
        // Onboarding just handed over a place, which is what the feed was
        // waiting for. `.task` above has already run and come back empty by
        // then, so this is the fill for every first launch.
        .onChange(of: prefs.needsOnboarding) { _, needed in
            if !needed { Task { await loadDiscover() } }
        }
        // The radius is applied *during* the fill, so widening it can't be
        // honoured by re-filtering what's in hand — the cards it would now keep
        // were never stored. Marked rather than refilled on the spot because the
        // sheet that changed it is covering the feed; both such sheets are
        // watched as one flag to stay under the type checker's limit.
        .onChange(of: prefs.radiusKM) { discover.markStale() }
        .onChange(of: isCoveredBySheet) { _, covered in
            if !covered { Task { await loadDiscover() } }
        }
    }

    /// Two stable scroll views occupy the same shell. Hiding one instead of
    /// replacing it is intentional: its UIKit scroll view, lazy-cell identity,
    /// and exact offset remain alive while the other surface is visible.
    private var browseSurfaces: some View {
        ZStack {
            discoverSurface
                .opacity(surface == .discover ? 1 : 0)
                .allowsHitTesting(surface == .discover && !isSearching)
                .accessibilityHidden(surface != .discover || isSearching)

            searchSurface
                .opacity(surface == .search ? 1 : 0)
                .allowsHitTesting(surface == .search && !isSearching)
                .accessibilityHidden(surface != .search || isSearching)

            if isSearching {
                SearchSuggestions(onSelect: replaySearch, onAlert: { alert in
                    isSearching = false
                    searchAlertSource = "search_history"
                    selectedSearchAlert = alert
                })
            }
        }
        .navigationTitle("Openmarket")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var discoverSurface: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if account.needsPhoneLink {
                    PhoneAccountLinkBanner {
                        linkedProvider = nil
                        showAccountLink = true
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                }
                home
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 12)
                .onChanged { _ in discover.noteScroll() }
        )
        .refreshable { await loadDiscover(force: true) }
    }

    private var searchSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id(Self.searchTopAnchor)
                    searchContent
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { _ in
                        store.noteScroll(hiddenAsViewed: hiddenAsViewed)
                    }
            )
            .refreshable { await rerunCurrentQuery() }
            // A new result set starts at the top; pagination does not.
            .onChange(of: store.resultsGeneration) {
                proxy.scrollTo(Self.searchTopAnchor, anchor: .top)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Pieces

    private var currentSearchTerm: String {
        guard case .search(let term) = store.query?.kind else { return "" }
        return term
    }

    private var currentSearchAlert: SearchAlert? {
        searchAlerts.matching(query: currentSearchTerm, minPrice: prefs.minPrice,
                              maxPrice: prefs.maxPrice, for: account.state.viewer?.id)
    }

    private func openSearchAlert() {
        isSearching = false
        searchAlertSource = "search"
        if let alert = currentSearchAlert {
            selectedSearchAlert = alert
        } else {
            alertDraft = ListingAlertDraft(query: currentSearchTerm, minPrice: prefs.minPrice,
                                          maxPrice: prefs.maxPrice, source: "search")
        }
    }

    /// An explicit row keeps filters beside the field on every supported iOS
    /// version, including while the keyboard and search suggestions are open.
    private var searchBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search local listings", text: $searchText)
                    .focused($isSearching)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit(submitSearch)
                    .accessibilityIdentifier("browse-search-field")
                if !searchText.isEmpty || isSearching {
                    Button {
                        isSearching = false
                        returnToDiscover()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, searchText.isEmpty && !isSearching ? 12 : 0)
            .frame(minHeight: 44)
            .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

            if surface == .search && !isSearching {
                SearchAlertButton(alert: currentSearchAlert, iconOnly: true, action: openSearchAlert)
            }

            filtersButton
                .frame(width: 44, height: 44)
                .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))

        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, surface == .search && !isSearching ? 0 : 8)
    }

    private var savedButton: some View {
        Button {
            isSearching = false
            showSaved = true
        } label: {
            Image(systemName: "bookmark")
        }
        .accessibilityLabel("Saved listings")
    }

    /// Account and settings. Shows whether a session exists, because that
    /// changes what the app can see — seller identity, and how far the results
    /// go — so it is worth being able to tell at a glance.
    private var profileButton: some View {
        Button { showSettings = true } label: {
            Image(systemName: store.session == .authed
                  ? "person.crop.circle.fill"
                  : "person.crop.circle")
        }
        .accessibilityLabel(store.session == .authed ? "Account, signed in" : "Account")
    }

    /// Active state is a tint plus a badge, not `.fill` on the symbol: the
    /// filled and unfilled variants of this glyph differ by 1 pixel out of
    /// 30,301 at toolbar size, so the affordance communicated nothing.
    private var filtersButton: some View {
        Button {
            isSearching = false
            showFilters = true
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .foregroundStyle(prefs.hasNonDefaultFilters ? Color.accentColor : Color.primary)
                .overlay(alignment: .topTrailing) {
                    if prefs.hasNonDefaultFilters {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .offset(x: 5, y: -4)
                    }
                }
                .padding(.trailing, 3)      // room for the badge to sit in
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel(prefs.hasNonDefaultFilters ? "Filters, active" : "Filters")
    }

    @ViewBuilder
    private var searchContent: some View {
        switch store.feedState {
        case .loginWall:
            LoginWallCard(signIn: { presentSignIn(from: .search) },
                          retry: { Task { await store.retry() } })
                .padding()
        // A failure replaces the screen only when there is nothing to replace:
        // a load can fail after cards were restored from cache or a partial
        // read, and an error banner over held listings reads as "broken".
        case .failed(let message) where store.listings.isEmpty:
            InlineNotice(text: message, actionTitle: "Try again") { Task { await store.retry() } }
                .padding()
        default:
            if store.isLoadingFirstPage {
                SkeletonGrid()
            } else if store.listings.isEmpty {
                if store.canLoadMore {
                    searchPaginationFooter(items: [])
                } else {
                    InlineNotice(text: "Nothing found nearby.", actionTitle: nil, action: nil).padding()
                }
            } else {
                searchGrid
            }
        }
    }

    /// Saved listings have their own sheet; Discover leads with the feed.
    private var home: some View {
        let discovered = winnowed(discover.listings, hidingViewed: false, radiusKM: discover.radiusKM,
                                  distanceSnapshot: discover.distanceSnapshot)

        return discoverSection(discovered)
            .padding(.top, 16)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 12)
    }

    /// Facebook's own Marketplace feed for this place, cut to the user's radius.
    ///
    /// Runs to the bottom of the selected feed transport.
    @ViewBuilder
    private func discoverSection(_ w: WinnowedListings) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Discover")
                Text(discover.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
            // A fresh fill uses the full skeleton until its first usable batch
            // arrives. On refresh the current cards stay up instead, because
            // there is something better than a placeholder to look at.
            if discover.isLoading && discover.listings.isEmpty {
                SkeletonGrid()
            } else {
                PaginatedListingGrid(
                    items: w.items,
                    namespace: discoverNamespace,
                    loadingPlaceholderCount: 0,
                    tracksVisibleListings: canRecordShownListings && surface == .discover,
                    onItemVisible: { FilterTotals.shared.recordShownListing($0.id, on: .discover) },
                    onSelect: { open($0, from: .discover, at: $1) },
                    onItemAppear: { await discover.loadMoreIfNeeded(currentItem: $0) }
                ) {
                    // The home feed fills itself without being asked, so an
                    // empty one has no user action behind it to explain it.
                    if w.isEmptiedByDistance {
                        distanceNotice(w)
                    }
                    discoverFooter(items: w.items)
                }
            }
        }
    }

    private func discoverFooter(items: [Listing]) -> some View {
        VStack(spacing: 8) {
            FeedPaginationFooter(
                position: .init(generation: discover.generation, visibleCount: items.count,
                                lastVisibleID: items.last?.id),
                canLoadMore: surface == .discover && selected == nil && !discover.reachedEnd
                    && !discover.isLoading && discover.loadError == nil && !discover.paginationPaused,
                isLoading: discover.isLoading || discover.isLoadingMore,
                loadingMessage: "Finding more nearby listings…"
            ) {
                Task { await discover.loadMore() }
            }
            if !discover.isLoading && !discover.isLoadingMore {
                if let error = discover.loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await discover.retryLoadingMore() } }
                        .buttonStyle(.bordered)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func searchPaginationFooter(items: [Listing]) -> some View {
        VStack(spacing: 8) {
            FeedPaginationFooter(
                position: .init(generation: store.resultsGeneration, visibleCount: items.count,
                                lastVisibleID: items.last?.id),
                canLoadMore: surface == .search && selected == nil && store.canLoadMore
                    && !store.isRefreshingSearch && store.paginationError == nil && !store.paginationPaused,
                isLoading: store.isLoadingMore,
                loadingMessage: "Finding more matching listings…"
            ) {
                Task {
                    store.updateHiddenAsViewed(hiddenAsViewed)
                    await store.loadMore()
                }
            }
            if !store.isRefreshingSearch && !store.isLoadingMore, let error = store.paginationError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Try again") { Task { await store.retryLoadingMore() } }
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// The grid, after the two filters Facebook won't apply for us — and what
    /// each of them took, because a filter that removes cards without saying so
    /// is indistinguishable from a broken search.
    ///
    /// Distance is enforced here because no surface honours `radius`: the chip
    /// changes and the results don't (`docs/filter-parameters.md` §3). Listings
    /// whose distance isn't known yet are **kept**, not hidden — geocoding is
    /// asynchronous, and filtering on missing data would make cards disappear
    /// and come back as the queue drains. `nearestHiddenKM` is the diagnostic
    /// that separates "your radius is tight" from "these results are for the
    /// wrong city", which otherwise look identical: a blank grid.
    ///
    /// Discover has already been through this once — `DiscoverFeed.nearby`
    /// filters as it pages, because a feed that can't tell how much it dropped
    /// can't tell whether to keep scrolling. Re-running it here costs a few
    /// cached lookups and keeps one rule for every list on the screen.
    ///
    /// `hidingViewed` is off for Discover: that filter means "new to me in this
    /// search", and a home feed nobody asked for is not a search. The seen
    /// marker on each card already says which ones have been opened.
    private func winnowed(
        _ listings: [Listing],
        hidingViewed: Bool = true,
        radiusKM: Int? = nil,
        distanceSnapshot: ListingDistanceSnapshot? = nil
    ) -> WinnowedListings {
        ListingWinnower.apply(
            to: listings,
            hiddenAsViewed: hiddenAsViewed,
            hidingViewed: hidingViewed,
            radiusKM: radiusKM ?? prefs.radiusKM,
            distances: distances,
            distanceSnapshot: distanceSnapshot ?? store.distanceSnapshot
        )
    }

    private var filteredNonLocalIDs: [String] {
        switch surface {
        case .search: return winnowed(store.listings).nonLocalIDs
        case .discover:
            return winnowed(discover.listings, hidingViewed: false,
                            radiusKM: discover.radiusKM,
                            distanceSnapshot: discover.distanceSnapshot).nonLocalIDs
        }
    }

    private var searchGrid: some View {
        let winnowed = winnowed(store.listings)
        return PaginatedListingGrid(
            items: winnowed.items,
            namespace: searchNamespace,
            loadingPlaceholderCount: 0,
            tracksVisibleListings: canRecordShownListings && surface == .search,
            onItemVisible: { FilterTotals.shared.recordShownListing($0.id, on: .search) },
            onSelect: { open($0, from: .search, at: $1) },
            onItemAppear: {
                await store.loadMoreIfNeeded(
                    currentItem: $0,
                    hiddenAsViewed: hiddenAsViewed
                )
            }
        ) {
            // "Only new listings" runs here rather than at Facebook, so the
            // cards it removes disappear with no explanation unless one is given.
            if winnowed.hiddenAsViewed > 0 {
                viewedNotice(winnowed)
            }

            // Distance first: "nothing in your area" is a claim about the area,
            // and it is false when listings came back but measured out of view.
            if winnowed.isEmptiedByDistance {
                distanceNotice(winnowed)
            } else if store.requiresFacebookForMore {
                if !winnowed.items.isEmpty { endOfResultsSignIn }
            } else if store.reachedEnd, !winnowed.items.isEmpty {
                endOfSearchResults
            }
            searchPaginationFooter(items: winnowed.items)
        }
    }

    /// Why the screen is empty when the distance filter took all of it: a
    /// client-side filter that can empty a screen has to say that it did.
    /// Anything producing distant results arrives here — a tight radius, a place
    /// that resolved somewhere unexpected, or Facebook quietly serving the
    /// IP-inferred city (`docs/location.md` §3).
    ///
    /// The nearest distance is the whole diagnostic: "the nearest is 12 mi" is a
    /// radius that needs widening, "2,050 mi" is not a distance problem at all,
    /// and the number says which without the app having to guess.
    private func distanceNotice(_ w: WinnowedListings) -> some View {
        VStack(spacing: 8) {
            Text(placeScopedHeadline)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.center)
            if let detail = distanceDetail(w) {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            // The home screen has no filter bar, so the place and the radius
            // have no other readout and nothing else to tap.
            Button("Change location or distance") { showLocationPicker = true }
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    private var placeScopedHeadline: String {
        let radius = SearchQuery.kilometresToMiles(prefs.radiusKM)
        guard let place = prefs.locationName else { return "Nothing within \(radius) mi." }
        return "Nothing within \(radius) mi of \(place)."
    }

    /// States what *did* come back, so an empty screen reads as a filter working
    /// rather than a search failing.
    private func distanceDetail(_ w: WinnowedListings) -> String? {
        guard let km = w.nearestHiddenKM else { return nil }
        // Grouped: "2051 mi" reads as a typo where "2,051 mi" reads as a
        // continent, which is the distinction being drawn.
        let miles = Int((km / 1.60934).rounded()).formatted()
        let count = w.hiddenByDistance == 1 ? "1 listing" : "\(w.hiddenByDistance) listings"
        return "\(count) came back, and the nearest is \(miles) mi away."
    }

    /// What "only new listings" is holding back, and the way out of it.
    private func viewedNotice(_ w: WinnowedListings) -> some View {
        let showingNothing = w.items.isEmpty
        return VStack(spacing: 8) {
            Text(showingNothing
                 ? "You've opened all \(w.hiddenAsViewed) of these already"
                 : "\(w.hiddenAsViewed) you've already viewed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show viewed") {
                prefs.hideViewed = false
                // The one filter change outside the filter sheet.
                Analytics.capture(.filtersApplied, [
                    "source": Analytics.Surface.resultsNotice.rawValue,
                    "changed": ["hide_viewed"],
                    "hide_viewed": false
                ])
            }
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, showingNothing ? 40 : 24)
    }

    /// The anonymous browser fallback cannot continue past its first page.
    private var endOfResultsSignIn: some View {
        VStack(spacing: 12) {
            Text("Log in to see seller details and try more results.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { presentSignIn(from: .resultsFooter) } label: {
                Text("Log in to Facebook")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 20)
    }

    /// Shown only after the hidden Marketplace feed has stayed at a valid,
    /// unchanged bottom through its confirmation window. Dry pagination batches
    /// and WebKit failures remain retryable and never reach this footer.
    private var endOfSearchResults: some View {
        Text("You've reached the end of these results.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 20)
    }

    // MARK: - Actions

    private func open(_ listing: Listing, from surface: Analytics.Surface, at position: Int) {
        selectedReferrer = surface
        selected = listing
        recordListingOpen(listing, from: surface, at: position)
    }

    /// The Saved sheet owns its navigation, but shares the same tap analytics.
    private func recordListingOpen(_ listing: Listing, from surface: Analytics.Surface, at position: Int) {
        var properties = Analytics.listingOpenProperties(listing, surface: surface, position: position,
            isSaved: saved.contains(listing), isSeen: viewed.contains(listing.id))
        // Same precedence the card's label uses, and absent rather than zero
        // when the geocode hasn't landed.
        if let km = distances.distanceKM(for: listing.locationText,
                                         coordinate: distances.enrichedCoordinate(for: listing)) {
            properties["distance_km"] = (km * 10).rounded() / 10
        }
        Analytics.capture(.listingOpened, properties)
    }

    private func presentSignIn(from surface: Analytics.Surface) {
        signInSurface = surface
        showSignIn = true
    }

    private func submitSearch() {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        isSearching = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        Task { await search(term) }
    }

    /// Runs a term from search suggestions. The field is filled first so
    /// Search opens in the state it would be in had the term been typed, and
    /// clearing the field returns to Discover.
    private func replaySearch(_ term: String) {
        isSearching = false
        searchText = term
        Task { await search(term) }
    }

    /// Reveals the already-mounted home feed. Search results remain in their
    /// store for a subsequent search, but the field is reset to its home state.
    private func returnToDiscover() {
        surface = .discover
        if !searchText.isEmpty {
            searchText = ""
        }
    }

    private func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Switch in the same main-actor turn that clears/replaces Search's
        // results, so a retained result set cannot flash between submission
        // and the new query entering its loading state.
        surface = .search
        // Before `recordSearch`, which is what makes the provenance readable at
        // all: that call puts this term at the top of the recents, so asking
        // afterwards whether it was already there always answers yes.
        let source = searchSource(for: trimmed)
        prefs.recordSearch(trimmed)
        var properties: [String: Any] = [
            "source": source.rawValue,
            "term_length": trimmed.count,
            "word_count": trimmed.split(separator: " ").count,
            "has_active_filters": prefs.hasNonDefaultFilters,
            "sort": prefs.sort.rawValue,
            "radius_km": prefs.radiusKM
        ]
        // Lowercased so "Weber Grill" and "weber grill" are one breakdown row.
        properties["term"] = Analytics.text(trimmed.lowercased())
        Analytics.capture(.searchSubmitted, properties)
        await run(.search(trimmed))
    }

    /// A guess: a tapped completion and a typed word reach `onSubmit`
    /// identically, so this matches against the recent searches the field offers.
    private func searchSource(for term: String) -> Analytics.SearchSource {
        let matches = { (candidate: String) in
            candidate.caseInsensitiveCompare(term) == .orderedSame
        }
        if prefs.recentSearches.contains(where: matches) { return .recent }
        return .typed
    }

    /// Every search goes through here, which is what makes the "only new"
    /// snapshot honest: it is taken once, at the start of a search, and holds
    /// for as long as those results are on screen.
    private func run(_ kind: SearchQuery.Kind) async {
        hiddenAsViewed = prefs.hideViewed ? viewed.allIDs : []
        await store.run(makeQuery(kind), hiddenAsViewed: hiddenAsViewed)
    }

    private func rerunCurrentQuery() async {
        guard let existing = store.query else { return }
        await run(existing.kind)
    }

    private func refreshVisibleSurfaceAfterFilters() {
        Task {
            if surface == .search {
                await rerunCurrentQuery()
            } else {
                await loadDiscover()
            }
        }
    }

    /// The same place every search uses, so Discover and a search from the home
    /// screen are looking at the same city.
    ///
    /// Held back while onboarding is up. This view exists behind that cover
    /// from launch, so without the guard the feed would fetch a fallback city —
    /// and then be marked filled, so the place the user was in the middle of
    /// choosing wouldn't reach it until the next launch.
    private func loadDiscover(force: Bool = false) async {
        guard !prefs.needsOnboarding else { return }
        await discover.loadIfNeeded(citySlug: prefs.locationSlug ?? "sanfrancisco", force: force)
    }

    /// Location is an enhancement, never a gate: searching uses whatever
    /// coordinate is cached and asks for a fresh one in the background, so a
    /// slow or refused fix can't stall the results.
    ///
    /// And never a prompt — `prompt: .never` is the default. This runs on every
    /// search, including one after the user skipped the location step, and
    /// asking belongs to the controls that offer it: the location sheet,
    /// onboarding, and the enable card under a listing.
    private func makeQuery(_ kind: SearchQuery.Kind) -> SearchQuery {
        if location.coordinate == nil {
            Task {
                let coordinate = await location.resolveOnce()
                distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace,
                                                                  deviceFix: coordinate))
            }
        } else {
            distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace, deviceFix: location.coordinate))
        }
        return SearchQuery(
            kind: kind,
            // Sent for shape only — no surface filters on it. The real distance
            // filter is `visibleListings`.
            radiusKM: prefs.radiusKM == 0 ? 40 : prefs.radiusKM,
            citySlug: prefs.locationSlug ?? "sanfrancisco",
            coordinate: prefs.resolvedPlace?.coordinate,
            sort: prefs.sort,
            delivery: prefs.delivery,
            conditions: prefs.conditions,
            minPrice: prefs.minPrice,
            maxPrice: prefs.maxPrice
        )
    }
}

/// The structure Search and Discover genuinely share: the aligned listing grid,
/// pagination placeholders, selection, and per-card prefetch callback. Each
/// surface supplies its own store and footer because their loading and terminal
/// semantics are deliberately different.
private struct PaginatedListingGrid<Footer: View>: View {
    let items: [Listing]
    let namespace: Namespace.ID
    let loadingPlaceholderCount: Int
    let tracksVisibleListings: Bool
    let onItemVisible: (Listing) -> Void
    /// The tapped listing and its index — only this view knows the draw order.
    let onSelect: (Listing, Int) -> Void
    let onItemAppear: (Listing) async -> Void
    let footer: Footer

    init(items: [Listing],
         namespace: Namespace.ID,
         loadingPlaceholderCount: Int,
         tracksVisibleListings: Bool,
         onItemVisible: @escaping (Listing) -> Void,
         onSelect: @escaping (Listing, Int) -> Void,
         onItemAppear: @escaping (Listing) async -> Void,
         @ViewBuilder footer: () -> Footer) {
        self.items = items
        self.namespace = namespace
        self.loadingPlaceholderCount = loadingPlaceholderCount
        self.tracksVisibleListings = tracksVisibleListings
        self.onItemVisible = onItemVisible
        self.onSelect = onSelect
        self.onItemAppear = onItemAppear
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            ListingGrid(
                items: items,
                columns: 2,
                spacing: 12,
                loadingPlaceholderCount: loadingPlaceholderCount
            ) { listing in
                ListingCard(listing: listing, namespace: namespace)
                    .modifier(ListingVisibilityTracker(isEnabled: tracksVisibleListings) {
                        onItemVisible(listing)
                    })
                    // Scanned on the tap rather than changing `ListingGrid`'s
                    // builder signature, which every other screen also uses.
                    .onTapGesture {
                        onSelect(listing, items.firstIndex { $0.id == listing.id } ?? -1)
                    }
                    .task { await onItemAppear(listing) }
            }
            .padding(.horizontal, 12)

            footer
        }
    }
}

/// Suggestions stay above the mounted feeds while the search field has focus.
private struct SearchSuggestions: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var account: AccountSession
    @ObservedObject private var searchAlerts = SearchAlerts.shared
    let onSelect: (String) -> Void
    let onAlert: (SearchAlert) -> Void

    var body: some View {
        List {
            if !prefs.recentSearches.isEmpty {
                Section("Recent") {
                    ForEach(prefs.recentSearches, id: \.self) { term in
                        SearchHistoryRow(term: term,
                            alert: searchAlerts.matchingHistory(term, for: account.state.viewer?.id),
                            onSelect: { onSelect(term) }, onAlert: onAlert)
                    }
                }
            }
        }
        .listStyle(.plain)
        .background(Color(.systemBackground))
    }
}

struct SearchHistoryRow: View {
    let term: String
    let alert: SearchAlert?
    let onSelect: () -> Void
    let onAlert: (SearchAlert) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                Label(term, systemImage: "clock.arrow.circlepath")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let alert { SearchAlertButton(alert: alert) { onAlert(alert) } }
        }
    }
}

/// No login form of this app's own, ever: Facebook's page, or a way out.
///
/// The one moment where being signed out has stopped the app rather than merely
/// thinned it, so signing in leads. Retry and the handoff stay, because a rate
/// limit does pass on its own and not everyone wants to sign in mid-search.
struct LoginWallCard: View {
    let signIn: () -> Void
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Facebook is limiting browsing without an account.")
                .font(.headline)
            Text("Signing in clears this and keeps results loading. You can also wait a moment and try again, or open Marketplace in the Facebook app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Sign in", action: signIn)
                    .buttonStyle(.borderedProminent)
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                Button("Open Facebook") { Handoff.openMarketplace() }
                    .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct InlineNotice: View {
    let text: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action).font(.subheadline)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }
}
