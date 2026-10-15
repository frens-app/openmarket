import Foundation

/// Filtering holds the distance measured when a page arrived, including unknown
/// distances. Detail updates can change the label without moving grid cards.
@MainActor
struct ListingDistanceSnapshot {
    private struct Estimate {
        let kilometres: Double?
    }
    private var estimates: [String: Estimate] = [:]

    mutating func capture(_ listings: [Listing], using distances: DistanceResolver) {
        for listing in listings {
            estimates[listing.id] = Estimate(kilometres: distances.distanceKM(
                for: listing.locationText, coordinate: distances.enrichedCoordinate(for: listing)))
        }
    }

    func distanceKM(for id: String) -> Double? {
        estimates[id]?.kilometres
    }
}

/// The client-side filters shared by the rendered grid and Search pagination.
///
/// Facebook does not reliably apply the requested radius, and "Only new" is
/// local app state. Keeping this calculation in one place prevents pagination
/// from counting cards that the grid will immediately hide.
struct WinnowedListings {
    var items: [Listing] = []
    var hiddenAsViewed = 0
    var hiddenByDistance = 0
    var nonLocalIDs: [String] = []
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
        distances: DistanceResolver,
        distanceSnapshot: ListingDistanceSnapshot? = nil
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
            let kilometres: Double?
            if let distanceSnapshot {
                kilometres = distanceSnapshot.distanceKM(for: listing.id)
            } else {
                kilometres = distances.distanceKM(for: listing.locationText,
                                                   coordinate: distances.enrichedCoordinate(for: listing))
            }
            if let km = kilometres, km > Double(radiusKM) {
                result.hiddenByDistance += 1
                result.nonLocalIDs.append(listing.id)
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
