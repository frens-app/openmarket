import Foundation

/// The client-side filters shared by the rendered grid and Search pagination.
///
/// Facebook does not reliably apply the requested radius, and "Only new" is
/// local app state. Keeping this calculation in one place prevents pagination
/// from counting cards that the grid will immediately hide.
struct WinnowedListings {
    var items: [Listing] = []
    var hiddenAsViewed = 0
    var hiddenByDistance = 0
    var nearestHiddenKM: Double?

    var isEmptiedByDistance: Bool { items.isEmpty && hiddenByDistance > 0 }
}

@MainActor
enum ListingWinnower {
    static func apply(
        to listings: [Listing],
        hiddenAsViewed: Set<String>,
        hidingViewed: Bool,
        radiusKM: Int,
        distances: DistanceResolver
    ) -> WinnowedListings {
        var result = WinnowedListings()
        for listing in listings {
            if hidingViewed, hiddenAsViewed.contains(listing.id) {
                result.hiddenAsViewed += 1
                continue
            }
            guard radiusKM > 0 else {
                result.items.append(listing)
                continue
            }
            // Same precedence as the card's label: a known listing is filtered
            // on its own point, everything else on its city's centroid.
            let coordinate = distances.enrichedCoordinate(for: listing)
            if let km = distances.distanceKM(
                for: listing.locationText,
                coordinate: coordinate
            ), km > Double(radiusKM) {
                result.hiddenByDistance += 1
                result.nearestHiddenKM = min(
                    km,
                    result.nearestHiddenKM ?? .greatestFiniteMagnitude
                )
                continue
            }
            // Unknown distance stays visible. Batch geocoding has already had
            // its turn before Search publishes, and hiding an unresolved local
            // result would make the grid depend on geocoder coverage.
            result.items.append(listing)
        }
        return result
    }
}
