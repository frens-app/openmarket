import SwiftUI

struct SellerView: View {
    let profile: SellerProfile
    @EnvironmentObject private var following: FollowedSellers
    @EnvironmentObject private var store: ListingStore
    @StateObject private var inventory = SellerInventory()
    @State private var filter: SellerListingFilter = .available
    @State private var selected: Listing?
    @State private var authorized = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Namespace private var namespace

    private var displayedProfile: SellerProfile {
        var result = profile
        result.photoURL = inventory.sellerPhotoURL
            ?? following.profiles.first(where: { $0.id == profile.id })?.photoURL ?? profile.photoURL
        return result
    }

    var body: some View {
        Group {
            if authorized { screen }
            else { ProgressView("Checking Facebook session…") }
        }
        .task(id: filter) {
            guard await validateAccess() else { return }
            await inventory.loadIfNeeded(profile: profile, filter: filter)
        }
        .onChange(of: store.session) { _, session in
            if session == .unauthed { revokeAccess() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { _ = await validateAccess() } }
        }
        .onChange(of: inventory.needsSignIn) { _, needed in
            if needed { revokeAccess() }
        }
        .onChange(of: inventory.sellerPhotoURL) { _, photoURL in
            if photoURL != nil { following.refresh(displayedProfile) }
        }
    }

    private func validateAccess() async -> Bool {
        guard await SessionState.isSignedIn() else {
            revokeAccess()
            return false
        }
        store.setSession(.authed)
        authorized = true
        return true
    }

    private func revokeAccess() {
        authorized = false
        inventory.cancel()
        dismiss()
    }

    private var screen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                filters
                listings
            }
            .padding()
        }
        .background(Color(.systemBackground))
        .background {
            HiddenWebViewHost(webView: inventory.webView)
                .frame(width: 1280, height: 900)
                .offset(x: 3000)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipped()
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ShareLink(item: profile.url) { Label("Share seller", systemImage: "square.and.arrow.up") } }
        .onDisappear { inventory.cancel() }
        .refreshable { await inventory.load(profile: profile, filter: filter) }
        .navigationDestination(item: $selected) { listing in
            DetailView(listing: listing, namespace: namespace)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SellerAvatar(profile: displayedProfile)
                VStack(alignment: .leading, spacing: 5) {
                    Text(profile.name).font(.title2.bold())
                    if let joined = profile.joinedText {
                        Text(joined).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if let rating = profile.rating {
                Label {
                    Text(rating, format: .number.precision(.fractionLength(1)))
                    if let count = profile.ratingCount { Text("(\(count) ratings)") }
                } icon: { Image(systemName: "star.fill").foregroundStyle(.orange) }
                .font(.subheadline)
            }
            if profile.isHighlyRated == true {
                Label("Highly rated on Marketplace", systemImage: "rosette")
                    .font(.subheadline).foregroundStyle(.orange)
            }
            Button {
                following.toggle(displayedProfile)
            } label: {
                Label(following.contains(profile.id) ? "Following" : "Follow seller",
                      systemImage: following.contains(profile.id) ? "checkmark" : "person.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Text("Following is saved on this device.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Listings").font(.title3.bold())
            ViewThatFits(in: .horizontal) {
                filterButtons(horizontal: true)
                filterButtons(horizontal: false)
            }
        }
    }

    private func filterButtons(horizontal: Bool) -> some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
        return layout {
            ForEach(SellerListingFilter.allCases) { value in
                Button { filter = value } label: {
                    Text(value.title)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .foregroundStyle(filter == value ? Color.white : Color.primary)
                        .background(filter == value ? Color.accentColor : Color(.secondarySystemBackground), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == value ? .isSelected : [])
            }
        }
    }

    @ViewBuilder private var listings: some View {
        if !inventory.items.isEmpty {
            ListingGrid(items: inventory.items, columns: 2, spacing: 12) { listing in
                Button { selected = listing } label: {
                    ListingCard(listing: listing, namespace: namespace)
                }
                .buttonStyle(.plain)
            }
        }
        if !inventory.isLoading, let error = inventory.errorMessage {
            VStack(spacing: 12) {
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await inventory.retry(profile: profile, filter: filter) }
                }
                Link("View on Facebook", destination: profile.url)
            }
            .frame(maxWidth: .infinity).padding()
        } else if !inventory.isLoading && inventory.items.isEmpty {
            ContentUnavailableView("No listings", systemImage: "shippingbox",
                description: Text(filter == .available ? "This seller has no available listings to show." : "This seller has no pending, sold or out-of-stock listings to show."))
        }
        FeedPaginationFooter(
            position: .init(generation: inventory.generation, visibleCount: inventory.items.count,
                            lastVisibleID: inventory.items.last?.id),
            canLoadMore: authorized && selected == nil && inventory.canLoadMore
                && inventory.errorMessage == nil && !inventory.needsSignIn,
            isLoading: inventory.isLoading,
            loadingMessage: inventory.items.isEmpty ? "Loading listings…" : "Loading more listings…"
        ) {
            Task { await inventory.loadMore() }
        }
    }
}
