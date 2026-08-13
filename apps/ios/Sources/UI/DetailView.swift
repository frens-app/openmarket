import SwiftUI
import CoreLocation

/// The progressive preview. The transition never waits on the network:
/// everything the grid already knows renders on the first frame, and detail
/// fades in behind it.
struct DetailView: View {
    let listing: Listing
    let namespace: Namespace.ID

    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var distances: DistanceResolver
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var viewed: ViewedListings
    @EnvironmentObject private var location: LocationProvider
    @State private var current: Listing
    @State private var didFail = false
    @State private var isEnriching = true
    @State private var showSignIn = false

    init(listing: Listing, namespace: Namespace.ID) {
        self.listing = listing
        self.namespace = namespace
        _current = State(initialValue: listing)
    }

    private var detail: ListingDetail? { current.detail }

    /// Whether this is still for sale.
    ///
    /// Two sources, and the item page wins when it has spoken. The card's badge
    /// is whatever was true when the search ran, which for anything restored
    /// from cache can be days old — and sold state is, with price, exactly what
    /// goes stale in a cache and exactly what someone opening a listing most
    /// needs to be right.
    ///
    /// `nil` from the item page means *nothing told us*, not *available*, so it
    /// falls back to the badge rather than overriding it.
    private enum Availability {
        case available, pending, sold

        var isGone: Bool { self != .available }
    }

    private var availability: Availability {
        if let sold = detail?.isSold {
            if sold { return .sold }
            if detail?.isPending == true { return .pending }
            return .available
        }
        // Nothing from the item page yet — fall back to the card.
        switch current.badgeText?.lowercased() {
        case "sold": return .sold
        case "pending": return .pending
        default: return .available
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                gallery
                priceBlock
                fulfillmentBlock
                descriptionBlock
                factsBlock
                sellerBlock
                mapBlock
                if didFail { unavailableNotice }
            }
            .padding(.horizontal)
            .padding(.bottom, 100)
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { primaryAction }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { saveButton }
            if let url = current.itemURL {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .task {
            // Opening a listing is what "seen" means — this is the only place
            // it's recorded, so every route in counts and none can miss it.
            // Before enrichment rather than after: a listing whose detail fetch
            // fails was still deliberately opened, and a slow one shouldn't be
            // forgotten because the user backed out while it loaded.
            viewed.record(listing.id)
            // And the card itself, for the same reason `saveButton` does it —
            // the recently-viewed strip draws from the profile store, so
            // something has to be there whether or not the fetch below lands.
            // Never destructive: `store` keeps any detail already held.
            store.remember(listing)

            distances.resolve(place: listing.locationText)
            // Words land seconds before the gallery, so they're shown the
            // moment they exist rather than waiting on the photos. The strip
            // keeps its own placeholders until the second stage arrives.
            let enriched = await store.enrich(listing) { staged in
                withAnimation(.easeOut(duration: 0.2)) {
                    current = staged
                    isEnriching = false
                }
            }
            distances.resolve(place: enriched.locationText ?? enriched.detail?.locationText)
            withAnimation(.easeOut(duration: 0.25)) {
                current = enriched
                didFail = enriched.detail == nil
                isEnriching = false
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView(surface: .listingDetail) {
                // Signing in doesn't retroactively fill this listing in — the
                // seller fields were never fetched, because Facebook didn't
                // render them to an anonymous session. So re-open it against
                // the new session rather than just closing the sheet.
                Task { await refetchAfterSignIn() }
            }
        }
        // Keyed on the listing this screen was pushed for, not on `current`:
        // the id has to be the one the grid card marked itself with, and it
        // has to stay put for the life of the screen — enrichment replaces
        // `current` wholesale, and a source id that changes mid-flight is a
        // transition with nothing to run back into.
        .zoomTransitionDestination(id: listing.id, in: namespace)
    }

    /// Re-reads this listing now that a session exists.
    ///
    /// Deliberately bypasses the profile cache: the stored record is real, it
    /// simply predates the session and has *unknown* seller fields rather than
    /// absent ones (`CachedProfile.sellerFieldsAreKnown`). Re-fetching is the
    /// only way to learn them.
    private func refetchAfterSignIn() async {
        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
        guard store.session == .authed else { return }
        isEnriching = true
        let refreshed = await store.enrich(current)
        withAnimation(.easeOut(duration: 0.25)) {
            current = refreshed
            isEnriching = false
        }
    }

    /// Keyed on the listing id — the photo FBID — so the grid reflects a save
    /// the moment it happens, with no separate plumbing between the screens.
    private var saveButton: some View {
        let isSaved = saved.contains(current.id)
        return Button {
            // Record before flagging, so the saved-items screen always has a
            // card to draw even when this fires before enrichment lands.
            store.remember(current)
            withAnimation(.snappy(duration: 0.2)) { saved.toggle(current.id) }
            // `isSaved` is the state before the toggle, so the event names what
            // just happened. Two events, because a bookmark rate and a regret
            // rate are different questions.
            var properties: [String: Any] = [
                "surface": Analytics.Surface.listingDetail.rawValue,
                "listing_id": current.id,
                // No price means no price alert can ever fire for it.
                "has_price": current.priceText != nil,
                // Saved off the thumbnail, or after the item page landed.
                "is_enriched": current.detail != nil
            ]
            properties["title"] = Analytics.text(current.title)
            properties["place"] = Analytics.text(placeName)
            if let price = PriceGuide.parse(current.priceText) { properties["price"] = price }
            Analytics.capture(isSaved ? .listingUnsaved : .listingSaved, properties)
        } label: {
            Label(isSaved ? "Saved" : "Save",
                  systemImage: isSaved ? "bookmark.fill" : "bookmark")
        }
        .accessibilityLabel(isSaved ? "Saved. Tap to remove." : "Save listing")
    }

    /// The photos, as a paginated deck at a **fixed height** — see
    /// `PhotoGallery`, which owns the paging, the dots and the full-screen
    /// viewer.
    ///
    /// Nothing here is sized by the photo that lands in it, so the page can't
    /// reflow when one decodes. That reflow was the bug the fixed height fixed:
    /// a bare `AsyncImage` with no height has a `Color` placeholder, which has
    /// no intrinsic size and collapses to nothing — so the decoded image
    /// expanded the frame to its full aspect height and shoved the whole page
    /// down. It showed up on prefetched listings because everything below is
    /// already laid out on the first frame; cold ones hid it behind their own
    /// loading.
    ///
    /// The card's thumbnail carries the first frame on its own, before
    /// enrichment has said how many photos there are — so the deck starts as a
    /// single page and grows, rather than staying blank until the item page
    /// lands. `photoURLs` replaces it wholesale once it exists: it starts with
    /// the same photo, and de-duplicating a CDN URL against itself across two
    /// different size variants isn't reliable.
    private var photos: [URL] {
        if let photos = detail?.photoURLs, !photos.isEmpty { return photos }
        return [current.thumbnailURL].compactMap { $0 }
    }

    private var gallery: some View {
        PhotoGallery(
            photos: photos,
            // Dimmed, not just badged. A sold listing that looks exactly like
            // an available one until you read a label is a listing someone will
            // message about.
            overlay: availability.isGone
                ? AnyView(
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.45))
                        soldStamp
                    }
                    .allowsHitTesting(false)
                  )
                : nil
        )
    }

    /// Across the photo, because that is where the eye lands first and the
    /// whole point is that this is unmissable before anything else is read.
    private var soldStamp: some View {
        Text(availability == .sold ? "SOLD" : "SALE PENDING")
            .font(.title2.weight(.heavy))
            .kerning(2)
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 11)
            .background(
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().stroke(.white.opacity(0.7), lineWidth: 2))
            )
            .accessibilityLabel(availability == .sold ? "Sold" : "Sale pending")
    }

    private var priceBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(current.priceText ?? "—")
                    .font(.title2.weight(.semibold))
                    // A struck-through price says "not for sale at this price"
                    // in the one place nobody can miss it, and it is the same
                    // language the was-price beside it already speaks.
                    .strikethrough(availability == .sold)
                    .foregroundStyle(availability == .sold ? .secondary : .primary)
                if let original = current.originalPriceText {
                    Text(original).font(.subheadline).foregroundStyle(.secondary).strikethrough()
                }
                if availability.isGone {
                    Text(availability == .sold ? "Sold" : "Pending")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(availability == .sold ? Color.secondary : Color.orange))
                }
            }
            if let title = current.title {
                Text(title).font(.title3)
            }
            // Unconditional: hiding it once the map can render makes a line
            // appear and then vanish under the title as a geocode lands. The map
            // card doesn't repeat the place, so there's nothing to duplicate.
            if let location = placeName {
                HStack(spacing: 5) {
                    Text(location)
                    if let distance = bestDistanceText {
                        Text("·").foregroundStyle(.tertiary)
                        Text(distance)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// Two sources, card first.
    ///
    /// The desktop search payload carries `delivery_types` per card, so for
    /// anything in the first server-rendered page this is known before the item
    /// page has loaded and can draw on the first frame. The item page's own
    /// answer replaces it when it lands — it is the listing's own object rather
    /// than a search result's, and it is the only source for everything past
    /// the payload's ~15-card reach.
    private var fulfillment: Fulfillment? {
        detail?.fulfillment ?? current.fulfillment
    }

    /// Directly under the price, because "do I have to drive somewhere" is
    /// decided in the same glance as "can I afford it" — and above the
    /// description, so it can't be missed by anyone who doesn't scroll.
    ///
    /// **Absent, not guessed.** Mobile-sourced cards and cards past the
    /// payload's reach have no delivery information at all, and the mistake
    /// available here would be to render "Local pickup" for them because it is
    /// usually true. A buyer reads a badge as a fact about the listing; drawing
    /// nothing is the honest form of not knowing.
    @ViewBuilder
    private var fulfillmentBlock: some View {
        if let fulfillment {
            VStack(alignment: .leading, spacing: 6) {
                Label(fulfillment.headline, systemImage: fulfillment.symbol)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemBackground), in: Capsule())
                    // Grey when there's nothing to buy, for the same reason the
                    // price is struck through: the delivery terms of a sold
                    // listing are trivia, not a call to action.
                    .foregroundStyle(availability.isGone ? AnyShapeStyle(.secondary)
                                                         : AnyShapeStyle(.tint))

                // One caption line rather than a second row of pills. These
                // qualify the headline, and a badge of equal weight beside it
                // reads as a separate option the seller is offering.
                if !fulfillment.refinements.isEmpty {
                    Text(fulfillment.refinements.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(fulfillment.accessibilityDescription)
        }
    }

    /// Reserves height so the fade-in doesn't shove the page around. Shows the
    /// seller's own words only — the heading is dropped entirely when there's
    /// nothing to put under it, rather than leaving a bare label.
    @ViewBuilder
    private var descriptionBlock: some View {
        if let description = detail?.description, !description.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.headline)
                Text(description)
                    .font(.body)
                    .textSelection(.enabled)
            }
        } else if isEnriching {
            VStack(alignment: .leading, spacing: 8) {
                Text("Description").font(.headline)
                ForEach(0..<3, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.tertiarySystemFill))
                        .frame(height: 13)
                }
            }
            .frame(minHeight: 90, alignment: .top)
        }
    }

    /// Facebook only renders seller identity to a signed-in session, so when
    /// browsing anonymously this section is *unknown* rather than empty.
    ///
    /// Saying so is more honest than showing nothing — a blank space reads as
    /// "this seller has no name or rating", which is exactly the wrong
    /// conclusion, and it's the one place where signing in has an obvious,
    /// concrete payoff to point at.
    @ViewBuilder
    private var sellerSignInPrompt: some View {
        Button {
            showSignIn = true
        } label: {
            // Icon aligned to the first line of text rather than to the centre
            // of the whole block: centring floats it into the gap between the
            // title and the subtitle whenever the title wraps.
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.body)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Log in to see seller details")
                        .font(.subheadline.weight(.semibold))
                    Text("Name, rating, and how long they've been on Facebook.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        // No horizontal padding here: the enclosing VStack already applies it,
        // and adding a second inset made this card visibly narrower than the
        // description and map it sits between.
    }

    /// Seller identity requires a signed-in desktop session.
    ///
    /// Laid out as a card with one fact per line, rather than name-and-stars
    /// crammed onto one row. That row was fine for "Kelsey Jones ★★★★★ 4.8
    /// (44)" and fell apart for everything else: a long name pushed the rating
    /// off the edge, and an unrated seller left a lone name floating under a
    /// heading with no indication whether the rating was missing or the seller
    /// simply had none.
    ///
    /// **The unrated case is stated, not omitted.** Plenty of sellers have
    /// never been rated — it tracks the category, with plant sellers rated and
    /// one-off furniture sellers mostly not (`logged-in-findings.md` §1a) — so
    /// silence there reads as a broken screen rather than as information. It is
    /// also the case the user hit when reporting the stars "missing".
    @ViewBuilder
    private var sellerBlock: some View {
        if let name = detail?.sellerName {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // Initials, because no seller photo is extracted from this
                    // surface. A generic silhouette would take the same space
                    // and say less.
                    Text(Self.initials(from: name))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color(.tertiarySystemFill)))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        // One line, always. A name is a name; if extraction
                        // ever hands this a paragraph again it should look
                        // wrong and stay small rather than becoming a
                        // three-line heading (which is exactly what a
                        // flattened seller block did here).
                        Text(name)
                            .font(.body.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        ratingLine
                    }
                    Spacer(minLength: 0)
                }

                if detail?.sellerIsHighlyRated == true {
                    Label("Highly rated on Marketplace", systemImage: "rosette")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                }
                if let joined = detail?.sellerJoined {
                    Label(joined, systemImage: "calendar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 4)
        } else if store.session == .unauthed, !isEnriching {
            // Only once enrichment has settled: offering this while the fetch
            // is still running would flash a "log in" prompt at a signed-in
            // user a moment before their seller details arrived.
            sellerSignInPrompt
        }
    }

    /// Stars, score and count — or an explicit statement that there are none.
    @ViewBuilder
    private var ratingLine: some View {
        if let rating = detail?.sellerRating {
            HStack(spacing: 3) {
                HStack(spacing: 1) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: Self.starSymbol(star, rating: rating))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text(String(format: "%.1f", rating))
                    .font(.caption.weight(.medium))
                if let count = detail?.sellerRatingCount {
                    Text("· \(count) rating\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(String(format: "%.1f", rating)) out of 5"
                + (detail?.sellerRatingCount.map { " from \($0) ratings" } ?? ""))
        } else {
            Text("No ratings yet")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Half-filled where the score is genuinely between two stars.
    ///
    /// The previous version compared against `rating.rounded()`, which drew a
    /// 4.5 as five full stars — rounding a rating *up* in the seller's favour
    /// is exactly the kind of small dishonesty this screen shouldn't commit.
    static func starSymbol(_ index: Int, rating: Double) -> String {
        if rating >= Double(index) - 0.25 { return "star.fill" }
        if rating >= Double(index) - 0.75 { return "star.leadinghalf.filled" }
        return "star"
    }

    /// "Kelsey Jones" → "KJ". Falls back to one letter, then to nothing at all
    /// rather than rendering a stray character for an unusual name.
    static func initials(from name: String) -> String {
        let letters = name.split(separator: " ")
            .prefix(2)
            .compactMap { $0.first(where: \.isLetter) }
        return String(letters).uppercased()
    }

    @ViewBuilder
    private var factsBlock: some View {
        // The card label already carried the condition, so it can render on the
        // first frame instead of waiting for the detail page to load.
        let condition = current.conditionText ?? detail?.conditionText
        let rows = [
            condition.map { ("Condition", $0) },
            detail?.postedText.map { ("Posted", $0) }
        ].compactMap { $0 }

        if !rows.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var placeName: String? { current.locationText ?? detail?.locationText }

    /// Two sources, in order of how much they actually know.
    ///
    /// The listing's own coordinate comes off the item page and doesn't exist
    /// until enrichment lands, so the city centroid carries the first frame and
    /// is replaced in place when the real point arrives.
    private var mapPoint: (CLLocationCoordinate2D, LocationMapCard.Precision)? {
        if let latitude = detail?.latitude, let longitude = detail?.longitude {
            return (CLLocationCoordinate2D(latitude: latitude, longitude: longitude), .listing)
        }
        if let coordinate = distances.coordinate(for: placeName) {
            return (coordinate, .city)
        }
        return nil
    }

    /// Measured from the listing's own point when we have it, falling back to
    /// the geocoded city centroid otherwise.
    ///
    /// Shares `DistanceResolver.bestDistanceText` with the grid rather than
    /// deciding for itself: this screen and the card that opened it disagreeing
    /// about how far away something is would be a bug the user could see.
    private var bestDistanceText: String? {
        distances.bestDistanceText(for: current)
    }

    @ViewBuilder
    private var mapBlock: some View {
        if let place = placeName, let (coordinate, precision) = mapPoint {
            VStack(alignment: .leading, spacing: 10) {
                LocationMapCard(place: place, coordinate: coordinate, precision: precision,
                                userLocation: location.coordinate)
                // Under the map, because it answers the question the map
                // raises. Draws nothing without a device fix — see
                // `TravelTimeRow`.
                TravelTimeRow(destination: coordinate, precision: precision)
            }
        }
    }

    /// A quiet inline row, never a dialog. The preview above it still
    /// has the price, title, location and photo, which is most of what anyone
    /// needs to decide.
    private var unavailableNotice: some View {
        InlineNotice(
            text: current.itemURL == nil
                ? "Couldn't match this listing on Facebook."
                : "Full details unavailable.",
            actionTitle: viewOnFacebookTitle,
            action: openInFacebook
        )
    }

    /// The button says what it does. It deep-links to this listing's own
    /// Marketplace page when the id resolved, and says so when it couldn't —
    /// rather than promising "Message Seller" and landing somewhere generic.
    ///
    /// When the listing is gone the link stays — there is still a page there,
    /// and a seller with other things — but it leads with that fact rather than
    /// offering an unqualified call to action for something nobody can buy.
    private var viewOnFacebookTitle: String {
        guard current.itemURL != nil else { return "Search on Facebook" }
        switch availability {
        case .sold: return "Sold — view on Facebook"
        case .pending: return "Sale pending — view on Facebook"
        case .available: return "View on Facebook"
        }
    }

    /// Every route out is a link. When the canonical URL never resolved,
    /// fall back to a Marketplace search for the title rather than a dead end.
    private func openInFacebook() {
        if let url = current.itemURL {
            Handoff.open(url, kind: "view-listing")
        } else {
            Handoff.openSearch(for: current, citySlug: prefs.locationSlug)
        }
    }

    /// Every action is a link-out, never an in-app flow.
    private var primaryAction: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: openInFacebook) {
                Label(viewOnFacebookTitle,
                      systemImage: availability.isGone ? "tag.slash" : "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            // Grey rather than accent-blue when there is nothing to buy: the
            // control still works, and it should stop reading as the thing to
            // do next.
            .tint(availability.isGone ? Color.secondary : Color.accentColor)
            .padding()
        }
        .background(.bar)
    }
}
