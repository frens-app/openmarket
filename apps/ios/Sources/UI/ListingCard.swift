import SwiftUI

struct ListingCard: View {
    let listing: Listing
    let namespace: Namespace.ID
    @EnvironmentObject private var distances: DistanceResolver
    @EnvironmentObject private var saved: SavedListings
    @EnvironmentObject private var viewed: ViewedListings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            // Price carries the heaviest weight in the cell.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(listing.priceText ?? "—")
                    .font(.headline)
                if let original = listing.originalPriceText {
                    Text(original)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .strikethrough()
                }
            }
            Text(listing.title ?? " ")
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            // Location and distance are the point of a *local* browser,
            // so they get their own line whenever the surface provides them.
            HStack(spacing: 4) {
                Text(listing.locationText ?? " ")
                    .lineLimit(1)
                if listing.locationText != nil {
                    // Measured from the listing's own point once it's a known
                    // listing, and from its city's centroid until then — see
                    // "Enriched known listings" in `DistanceResolver`. A card
                    // the user has opened before therefore gets a sharper,
                    // decimal distance than the ones around it, which is
                    // information Facebook never shows at all.
                    if let distance = distances.bestDistanceText(for: listing) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(distance)
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .task { distances.resolve(place: listing.locationText) }
    }

    private var thumbnail: some View {
        ZStack(alignment: .topLeading) {
            RemoteImage(url: listing.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failed:
                    MissingPhoto()
                case .loading:
                    Color(.tertiarySystemFill)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .zoomTransitionSource(id: listing.id, in: namespace)

            if let badge = listing.badgeText {
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        // Top-*trailing*, so it can never collide with the "Price drop" badge
        // above. Read-only here: saving is a deliberate act on the detail
        // screen, not something a thumb can do by brushing the grid.
        // Bottom-leading, the one free corner — "Price drop" sits top-left and
        // the bookmark top-right. Live rather than snapshotted, unlike the
        // "only new" filter: a card marking itself the moment you come back
        // from it is useful feedback, where a card *vanishing* at that moment
        // is not (see `hiddenAsViewed`).
        .overlay(alignment: .bottomLeading) {
            if viewed.contains(listing.id) {
                Text("Seen")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if saved.contains(listing.id) {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityLabel("Saved")
            }
        }
    }
}
