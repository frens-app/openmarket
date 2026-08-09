import SwiftUI
import CoreLocation

struct ResultsView: View {
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var distances: DistanceResolver
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var viewed: ViewedListings
    @EnvironmentObject private var discover: DiscoverFeed

    @State private var searchText = ""
    /// Whether the search field is presented. Only needed to tell a deliberate
    /// clear from the field simply closing — see the `searchText` handler.
    @State private var isSearching = false
    /// The term the results currently on screen belong to. Kept separately from
    /// `store.query` because it has to be readable the instant the field is
    /// dismissed, which is before the search it triggered has run.
    @State private var activeTerm = ""
    @State private var selected: Listing?
    @State private var showSettings = false
    @State private var showFilters = false
    @State private var showLocationPicker = false

    @State private var showSignIn = false

    /// Which listings the "only new" filter is hiding *right now*.
    ///
    /// A snapshot of `ViewedListings`, taken when a search runs or when the
    /// filter is switched on — never read live. Reading it live would mean that
    /// opening a listing and coming back made that card vanish under the user's
    /// thumb and the grid reflow around the gap, which reads as a bug even
    /// though it is the filter working. "New" therefore means new *as of when
    /// you ran this search*, and things opened since stay where they were until
    /// the next one.
    @State private var hiddenAsViewed: Set<String> = []

    @Namespace private var heroNamespace

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0) {
                    content
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Open Market")
            .navigationBarTitleDisplayMode(.inline)
            // Pinned under the title rather than left to `.automatic`, which on
            // iOS 26 floats it at the bottom of the screen. Searching is the
            // first thing this app does, so the field belongs at the top with
            // the filters that shape the search, not detached at the other end
            // of the screen from them.
            .searchable(text: $searchText,
                        isPresented: $isSearching,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search local listings")
            .searchSuggestions { SearchSuggestions() }
            .keepToolbarDuringSearch()
            // The search session is deliberately *not* closed here. A field left
            // open keeps showing what it was searched for, which is the point:
            // results with an empty-looking search bar over them don't say what
            // they are. `keepToolbarDuringSearch` is what makes that affordable
            // — without it, staying open would cost the title and both toolbar
            // buttons for as long as the results were on screen.
            //
            // The only visible difference from the un-searched screen is the
            // Cancel button beside the field, and dismissing with it keeps both
            // the results and the term.
            .onSubmit(of: .search) {
                let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else { return }
                activeTerm = term
                Task { await search(term) }
            }
            // Pinned rather than scrolled with the results: the point of the
            // bar is that what shaped this result set is readable *while*
            // reading the result set, and a readout that scrolls away answers
            // the question only before it gets asked.
            //
            // Only over results. On the home screen there is no query for a
            // sort to order, and a control that does nothing is worse than no
            // control.
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.query != nil {
                    ActiveFilterBar(
                        onLocation: { showLocationPicker = true },
                        onRerun: { Task { await rerunCurrentQuery() } }
                    )
                }
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { profileButton }
                ToolbarItem(placement: .topBarTrailing) { filtersButton }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showFilters) {
                FilterSheet { Task { await rerunCurrentQuery() } }
            }
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    // A signed-in query returns a different result set, not
                    // merely a longer one, so this re-runs rather than
                    // appending to what's already on screen.
                    //
                    // Discover is rebuilt for a stronger reason: signing in
                    // changes which feed it *is*, from three of the user's own
                    // searches to Facebook's own picks. `loadIfNeeded` notices
                    // the session changed on its own, so this is a plain reload.
                    Task {
                        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                        await store.retry()
                        await loadDiscover()
                    }
                }
            }
            .navigationDestination(item: $selected) { listing in
                DetailView(listing: listing, namespace: heroNamespace)
            }
            // The fix can land long after a search starts; hand it straight to
            // the distance resolver whenever it does.
            .onChange(of: location.coordinate?.latitude) {
                distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace, deviceFix: location.coordinate))
            }
            // Emptying the search bar goes home, to the saved list — but Cancel
            // empties it too, and cancelling a search field should not throw
            // away the results behind it.
            //
            // The two are told apart on the next tick, once the text and the
            // dismissal have both landed: an empty field with the search UI
            // still up is a deliberate clear, and an empty field because the
            // field went away restores the term instead. That restore is also
            // what puts the term back on screen — a field that closed without
            // its binding changing keeps drawing the prompt until something
            // writes to it.
            .onChange(of: searchText) { _, text in
                guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                Task { @MainActor in
                    await Task.yield()
                    if isSearching {
                        activeTerm = ""
                        store.clearQuery()
                    } else if !activeTerm.isEmpty {
                        searchText = activeTerm
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
                }
            }
            .task {
                distances.setUserLocation(DistanceResolver.origin(for: prefs.resolvedPlace, deviceFix: location.coordinate))
            }
            // The home feed, filled on arrival rather than on demand — it is
            // the thing the user is meant to land in, so waiting for a gesture
            // to start it would defeat the point. It then stands for the rest
            // of the launch: `loadIfNeeded` is a no-op after the first fill, so
            // coming back from a listing or the seller tab costs nothing and
            // finds the same cards in the same places.
            //
            // Nothing else invalidates it — not a new search, not a change of
            // city, not signing in. It is three page loads, it is deliberately
            // a shuffle, and rebuilding it under someone who is halfway down it
            // is worse than showing them a feed that is an hour old. Relaunch
            // and pull-to-refresh are the two ways to get a new one.
            .task { await loadDiscover() }
            // Onboarding just handed over a place and three interests, which is
            // everything the feed was waiting for. `.task` above has already
            // run and returned empty-handed by then, so this is the fill for
            // every first launch.
            .onChange(of: prefs.needsOnboarding) { _, needed in
                if !needed { Task { await loadDiscover() } }
            }
            // Editing interests changes what Discover is *for*, unlike the
            // things that deliberately don't invalidate it. It doesn't refill
            // on the spot — the Settings sheet is over the top of the feed, and
            // there'd be nothing to watch — so it's marked stale here and
            // rebuilt when the sheet closes.
            .onChange(of: prefs.interests) { discover.markStale() }
            .onChange(of: showSettings) { _, shown in
                if !shown { Task { await loadDiscover() } }
            }
            .refreshable {
                // The gesture means "get me a fresh version of this screen",
                // and which screen that is depends on whether a search is up.
                if store.query == nil {
                    await loadDiscover(force: true)
                } else {
                    await rerunCurrentQuery()
                }
            }
        }
    }

    // MARK: - Pieces

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

    /// §3.1 — the radius was in the toolbar on the thesis that it is the
    /// product's whole point and should never be buried. It is one tap away
    /// rather than zero now, but it sits with every other filter instead of
    /// alone, and the dot says when anything is narrowing the results.
    ///
    /// Active state is a tint plus a badge, not `.fill` on the symbol. The
    /// filled and unfilled variants of this glyph are indistinguishable at
    /// toolbar size — measured, 1 differing pixel out of 30,301 between the two
    /// states — so the affordance communicated nothing at all.
    private var filtersButton: some View {
        Button { showFilters = true } label: {
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
        }
        .accessibilityLabel(prefs.hasNonDefaultFilters ? "Filters, active" : "Filters")
    }

    // Recent searches and suggested categories used to sit in a pill row above
    // the results, where they cost a strip of vertical space on every screen —
    // including the ones where nobody is looking for them. They now appear
    // inside the search field, which is where someone is when they want them.

    @ViewBuilder
    private var content: some View {
        switch store.feedState {
        case .loginWall:
            LoginWallCard { Task { await store.retry() } }
                .padding()
        // A failure replaces the screen only when there is nothing to replace.
        //
        // Engine state and collected results are separate facts, and they can
        // disagree — a load can fail after cards were restored from cache, or
        // after a partial read. Letting the state win meant an error banner
        // drawn over listings the app was holding, which reads as "broken" when
        // the honest report is "here is what I have, and something went wrong".
        case .failed(let message) where store.listings.isEmpty:
            InlineNotice(text: message, actionTitle: "Try again") { Task { await store.retry() } }
                .padding()
        default:
            if store.isLoadingFirstPage {
                SkeletonGrid()
            } else if store.listings.isEmpty && store.query != nil {
                InlineNotice(text: "Nothing found nearby.", actionTitle: nil, action: nil)
                    .padding()
            } else if store.query == nil {
                home
            } else {
                grid
            }
        }
    }

    /// With an empty search bar: what the user came back for, then something to
    /// scroll.
    ///
    /// The two personal sections are entirely local — every card in them comes
    /// out of the profile store, which is why they render with no network at
    /// all — and both are one row deep. That is what makes them affordable
    /// above the fold: together they cost two rows and then hand the screen to
    /// Discover, which is the part someone arriving with nothing saved and
    /// nothing viewed is actually here for.
    ///
    /// Either personal section disappears when it's empty rather than showing a
    /// placeholder. A new install therefore lands directly on Discover, and the
    /// screen fills in from the top as the app gets used.
    ///
    /// **Discover is always here, even with nothing in it.** There used to be a
    /// blanket empty state — "Nothing saved yet", plus advice about bookmarks —
    /// covering the whole screen when every section came back empty. It answered
    /// the wrong question: an empty feed is a statement about the area or the
    /// session, not about the user's bookmarking habits, and both of those now
    /// have something better to say under the heading (`discoverFooter`).
    private var home: some View {
        let savedItems = store.listings(for: saved.ids)
        // Saved listings are excluded from the recent strip: the same card in
        // two adjacent rails is clutter rather than information.
        let recentIDs = viewed.ids
            .filter { !saved.contains($0) }
            .prefix(ViewedListings.recentStripLength)
        let recentItems = store.listings(for: Array(recentIDs))
        let discovered = winnowed(discover.listings, hidingViewed: false)

        return VStack(alignment: .leading, spacing: 24) {
            if !recentItems.isEmpty {
                strip("Recently viewed", items: recentItems)
            }
            if !savedItems.isEmpty {
                strip("Saved", items: savedItems)
            }
            discoverSection(discovered)
        }
        .padding(.top, 4)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, 12)
    }

    /// A one-row rail of listings the app already has on disk.
    ///
    /// Both personal sections use it, and that similarity is the point: they
    /// answer the same kind of question — "the thing I was just looking at",
    /// "the thing I kept" — and both are a way *back* to a specific listing
    /// rather than something to browse. A rail says that; a grid says "start
    /// here", which is Discover's job now.
    ///
    /// `RecentCard` rather than `ListingCard` also keeps `heroNamespace` ids
    /// unique across the screen, which `matchedGeometryEffect` requires: a
    /// saved listing may perfectly well appear in Discover as well, and two
    /// views claiming one id would break the transition into the detail view.
    private func strip(_ title: String, items: [Listing]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(items) { listing in
                        RecentCard(listing: listing)
                            .onTapGesture { selected = listing }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
    }

    /// Facebook's own Marketplace feed when there's an account behind it, and a
    /// mix drawn from the user's own recent searches when there isn't.
    ///
    /// It runs to the bottom of the scroll, because it is the only section here
    /// that can — the other two are bounded by what the user has done to
    /// individual listings. Signed in, "the bottom" means the bottom of
    /// Facebook's feed, reached a screen at a time as the user gets near it.
    ///
    /// The caption under the heading is not decoration. A feed with no stated
    /// basis is indistinguishable from a random one — which is exactly the
    /// complaint that got Facebook's own feed removed from this screen the
    /// first time. Signed out it names the seeds ("from lamp · couch · desk"),
    /// which makes the mix legible as a consequence of something the user did;
    /// signed in it names the place and the radius, which is the only thing
    /// this app did to a feed it didn't build.
    @ViewBuilder
    private func discoverSection(_ w: Winnowed) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("Discover")
                if let caption = discover.caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            // The skeleton holds for the whole fill.
            //
            // The searches run concurrently and publish together, so there is
            // no half-built state to show — and nothing that could be shown
            // would survive: a partial feed reflows when the rest lands, which
            // moves cards out from under whoever is already reading them.
            //
            // On a refresh the current cards stay up instead, because there is
            // something better than a skeleton to look at and the gesture was
            // "get me a fresh version of this", not "take this away".
            if discover.isLoading && discover.listings.isEmpty {
                SkeletonGrid()
            } else {
                StaggeredGrid(items: w.items, columns: 2, spacing: 12) { listing in
                    ListingCard(listing: listing, namespace: heroNamespace)
                        .onTapGesture { selected = listing }
                        // A no-op unless this is the browse feed and the card is
                        // near the end of it.
                        .task { await discover.loadMoreIfNeeded(currentItem: listing) }
                }
                .padding(.horizontal, 12)

                if discover.isLoadingMore {
                    ProgressView().frame(maxWidth: .infinity).padding()
                }
                discoverFooter(isEmpty: w.items.isEmpty)
            }
        }
    }

    /// What sits under Discover once there is nothing more to add.
    ///
    /// There used to be a count of what the distance filter had removed, with a
    /// button to widen the radius. It is gone. On a result set that footer works
    /// — the user reads to the end — but a home feed is scrolled until something
    /// catches the eye, so it was addressed to nobody, and the offer it made was
    /// a lie for exactly the users who now get this feed: signed in, Facebook's
    /// own account radius is a floor the app cannot raise, so tapping "try 15
    /// mi" would change the number and not the results
    /// (`docs/filter-parameters.md` §11). The radius is stated in the caption
    /// instead, where it is read before the scrolling starts rather than after
    /// it stops.
    @ViewBuilder
    private func discoverFooter(isEmpty: Bool) -> some View {
        switch discover.mode {
        // Signed out the feed is a fixed sample of three searches, so its end is
        // always the end — and the honest thing to offer there is the account
        // that turns this screen into Facebook's real one.
        case .searches:
            endOfResultsSignIn
        case .browse:
            if discover.reachedEnd {
                endOfArea(isEmpty: isEmpty)
            }
        }
    }

    /// The end of what's nearby.
    ///
    /// Deliberately about the *area* rather than the feed, because the area is
    /// what ran out: Facebook keeps going, and this is the point at which
    /// nothing it offers next is close enough to be worth showing.
    ///
    /// "Nothing else" would be a small lie on a screen that never had anything
    /// on it, so an empty one drops the word.
    private func endOfArea(isEmpty: Bool) -> some View {
        Text(isEmpty ? "There's nothing in your area." : "There's nothing else in your area.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 24)
            .padding(.bottom, 20)
    }

    /// The grid, after the two filters Facebook won't apply for us — and the
    /// count the one with an undo took, because a filter that removes cards
    /// without saying so is indistinguishable from a broken search.
    ///
    /// Distance is no longer counted here. It used to be, to feed a footer that
    /// offered to widen the radius; that footer is gone (`discoverFooter`), and
    /// the radius is stated on the filter bar over a result set and in the
    /// caption over Discover — both of them before the scrolling rather than
    /// after it.
    private struct Winnowed {
        var items: [Listing] = []
        var hiddenAsViewed = 0
    }

    /// Distance is enforced here because no surface honours `radius` — the chip
    /// changes and the results don't (`docs/filter-parameters.md` §3). Listings
    /// whose distance isn't known yet are **kept**, not hidden: geocoding is
    /// asynchronous, and filtering on missing data would make cards disappear
    /// and come back as the queue drains.
    ///
    /// Signed in, Discover has already been through this once —
    /// `DiscoverFeed.nearby` filters as it pages, because a feed that can't tell
    /// how much it dropped can't tell whether to keep scrolling. Running it
    /// again here costs a few cached lookups and keeps one rule in one place for
    /// every list on the screen.
    ///
    /// `hidingViewed` is off for Discover. That filter means "only listings new
    /// to me *in this search*", and a home feed nobody asked for is not a
    /// search — silently emptying it because the user has been using the app
    /// would be a strange reward for it. The seen marker on each card already
    /// says which ones have been opened.
    private func winnowed(_ listings: [Listing], hidingViewed: Bool = true) -> Winnowed {
        var result = Winnowed()
        for listing in listings {
            if hidingViewed, hiddenAsViewed.contains(listing.id) {
                result.hiddenAsViewed += 1
                continue
            }
            guard prefs.radiusKM > 0 else {
                result.items.append(listing)
                continue
            }
            // Same precedence as the card's label: a known listing is filtered
            // on its own point, everything else on its city's centroid.
            let coordinate = distances.enrichedCoordinate(for: listing)
            if let km = distances.distanceKM(for: listing.locationText, coordinate: coordinate),
               km > Double(prefs.radiusKM) {
                continue
            }
            result.items.append(listing)
        }
        return result
    }

    private var grid: some View {
        VStack(spacing: 0) {
            let winnowed = winnowed(store.listings)
            let items = winnowed.items
            StaggeredGrid(items: items, columns: 2, spacing: 12) { listing in
                ListingCard(listing: listing, namespace: heroNamespace)
                    .onTapGesture { selected = listing }
                    .task { await store.loadMoreIfNeeded(currentItem: listing) }
            }
            .padding(.horizontal, 12)
            .overlay(alignment: .bottom) {
                if store.isLoadingMore {
                    ProgressView().padding()
                }
            }

            // "Only new listings" runs here rather than at Facebook, so the
            // cards it removes disappear with no explanation unless one is
            // given — and it has an undo, which is the point of naming it.
            //
            // The distance filter used to be reported alongside it, with an
            // offer to widen. Both are gone; see `discoverFooter` for why the
            // offer had to go, and note that the radius is already stated on the
            // bar pinned above these results, which is where it belongs.
            if winnowed.hiddenAsViewed > 0 {
                viewedNotice(winnowed)
            }

            if store.session == .unauthed {
                if !items.isEmpty { endOfResultsSignIn }
            } else if store.reachedEnd || items.isEmpty {
                endOfArea(isEmpty: items.isEmpty)
            }
        }
    }

    /// What "only new listings" is holding back, and the way out of it.
    private func viewedNotice(_ w: Winnowed) -> some View {
        let showingNothing = w.items.isEmpty
        return VStack(spacing: 8) {
            Text(showingNothing
                 ? "You've opened all \(w.hiddenAsViewed) of these already"
                 : "\(w.hiddenAsViewed) you've already viewed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Show viewed") { prefs.hideViewed = false }
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, showingNothing ? 40 : 24)
    }

    /// The bottom of anything an anonymous session can see, which really is the
    /// bottom — Facebook serves about fifteen listings to a signed-out session
    /// and then blocks scrolling behind an overlay that can be dismissed exactly
    /// once.
    ///
    /// It ends Discover as well as a result set now, and there it is the whole
    /// reason the signed-out home screen is built the way it is: signing in
    /// replaces three of the user's own searches with Facebook's own feed,
    /// scrollable, so the offer below is a description of what happens rather
    /// than a nag.
    ///
    /// The offer alone carries it; explaining the cap out loud only draws
    /// attention to the ceiling.
    private var endOfResultsSignIn: some View {
        VStack(spacing: 12) {
            Text("Log in to keep scrolling, and to see who's selling.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { showSignIn = true } label: {
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

    // MARK: - Actions

    private func search(_ term: String) async {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        activeTerm = trimmed
        prefs.recordSearch(trimmed)
        prefs.recordLastQuery(.search(trimmed))
        await run(.search(trimmed))
    }

    /// Every search goes through here, which is what makes the "only new"
    /// snapshot honest: it is taken once, at the start of a search, and holds
    /// for as long as those results are on screen.
    private func run(_ kind: SearchQuery.Kind) async {
        hiddenAsViewed = prefs.hideViewed ? viewed.allIDs : []
        await store.run(makeQuery(kind))
    }

    /// Currently unreachable: the category pills that called it are gone, and
    /// the suggestions run categories as ordinary searches. Kept because
    /// `SearchQuery.Kind.category` still builds a valid URL — but note that
    /// category *paths* have never been through the desktop payload extractor,
    /// which is verified only against `/search/`. Anything reviving this should
    /// check the payload parses there first.
    private func browse(category: String) async {
        prefs.recordLastQuery(.category(category))
        await run(.category(category))
    }

    private func rerunCurrentQuery() async {
        guard let existing = store.query else { return }
        await run(existing.kind)
    }

    /// The same place every search uses, so Discover and a search from the home
    /// screen are looking at the same city.
    ///
    /// Held back while onboarding is up. This view exists behind that cover
    /// from launch, so without the guard the feed would spend three page loads
    /// on a fallback city and a default category list — and then be marked
    /// filled, so the place and interests the user was in the middle of
    /// choosing wouldn't reach it until the next launch.
    private func loadDiscover(force: Bool = false) async {
        guard !prefs.needsOnboarding else { return }
        await discover.loadIfNeeded(citySlug: prefs.locationSlug ?? "sanfrancisco", force: force)
    }

    /// Location is an enhancement, never a gate: searching uses whatever
    /// coordinate is already cached and asks for a fresh one in the background,
    /// so a slow or refused fix can't stall the results.
    ///
    /// And never a *prompt*. This runs on every search, including the first one
    /// after a user skipped the location step, so it takes a fix only where
    /// permission already exists (`prompt: .never`, the default). Raising the
    /// system dialog from here put it on a screen that had said nothing about
    /// location — asking belongs to the controls that offer it: the location
    /// sheet, onboarding, and the enable card under a listing.
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
            coordinate: location.coordinate,
            sort: prefs.sort,
            delivery: prefs.delivery,
            conditions: prefs.conditions,
            minPrice: prefs.minPrice,
            maxPrice: prefs.maxPrice
        )
    }
}

/// What the search field offers while it has focus: what you looked for
/// before, or somewhere to start if you never have.
///
/// Uses `.searchCompletion` rather than buttons. A button has to call
/// `dismissSearch()`, which *clears the field* — so the term the user just
/// picked vanished from the search bar, and the empty value tripped the
/// "emptied the field, go home" handler on its way past. A completion puts the
/// term in the field and submits it, which is the behaviour wanted here.
///
/// Categories run as searches for the same reason anything else does: the
/// desktop payload is only verified on `/search/` paths, and a category path
/// is a different page shape that has never been through this extractor.
private struct SearchSuggestions: View {
    @EnvironmentObject private var prefs: Preferences

    var body: some View {
        if !prefs.recentSearches.isEmpty {
            Section("Recent") {
                ForEach(prefs.recentSearches, id: \.self) { term in
                    Label(term, systemImage: "clock.arrow.circlepath")
                        .searchCompletion(term)
                }
            }
        }
        // The user's own interests rather than a fixed list of five.
        //
        // Same list Discover seeds from, which is the point: what the home
        // screen offers and what the search field offers should be the same
        // answer to the same question. The completion is the interest's search
        // *term*, not its label — running a search for "Home & garden" would
        // find nothing, because Marketplace matches listing text.
        Section(prefs.recentSearches.isEmpty ? "Try" : "Your interests") {
            ForEach(prefs.chosenInterests) { interest in
                Label(interest.label, systemImage: "square.grid.2x2")
                    .searchCompletion(interest.term)
            }
        }
    }
}

private extension View {
    /// Stops an active search from emptying the navigation bar.
    ///
    /// By default iOS hands the whole bar to the search field while a search is
    /// in progress, taking the title and both toolbar buttons with it — which
    /// is why the filters button used to disappear the moment anyone searched.
    @ViewBuilder
    func keepToolbarDuringSearch() -> some View {
        if #available(iOS 17.1, *) {
            searchPresentationToolbarBehavior(.avoidHidingContent)
        } else {
            self
        }
    }
}

/// A listing at strip size: square photo, price, one line of title.
///
/// Deliberately not a `ListingCard`. That card is built for a column of a
/// staggered grid — variable height, distance line, saved bookmark — and none of
/// that survives being squeezed into a 128pt horizontal rail. It also carries a
/// `matchedGeometryEffect`, which would collide with the grid above if the same
/// listing appeared in both.
private struct RecentCard: View {
    let listing: Listing

    private static let side: CGFloat = 128

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Color(.tertiarySystemFill)
                .frame(width: Self.side, height: Self.side)
                .overlay {
                    RemoteImage(url: listing.thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else if phase.hasFailed {
                            MissingPhoto()
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(listing.priceText ?? "—")
                .font(.subheadline.weight(.semibold))
            if let title = listing.title {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: Self.side, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// `EmptyStatePrompt` lived here: a full-screen "Nothing saved yet" with advice
// about bookmarks, shown when every home section came back empty. Removed with
// the blanket empty state (`home`) — an empty home screen is a statement about
// the area or the session, and Discover's own footer makes it.

/// §3.3 — no login form, ever. Just an honest explanation and a way out.
struct LoginWallCard: View {
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Facebook is limiting anonymous browsing right now.")
                .font(.headline)
            Text("You can keep browsing in a moment, or open Marketplace in the Facebook app.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                Button("Try again", action: retry)
                    .buttonStyle(.bordered)
                Button("Open Facebook") { Handoff.openMarketplace() }
                    .buttonStyle(.borderedProminent)
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
