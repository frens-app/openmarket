import Foundation
import CoreLocation
import MapKit

/// "How long would it actually take me to go get this?" — answered by Apple's
/// routing service through `MKDirections.calculateETA`.
///
/// Straight-line distance is a poor proxy for effort: two miles across the bay
/// is an hour, two miles down Valencia is a walk. This measures the route.
///
/// Named for where the numbers come from. Nothing here is derived from
/// Facebook: the destination is the point the map is already drawing, the
/// origin is the device's own fix, and the travel time is Apple's.
///
/// Two things bound what this can honestly claim:
///
/// - The destination is Facebook's *approximate* point, deliberately fuzzed,
///   so the answer is rounded to whole minutes and captioned as an estimate.
/// - Transit is ETA-only. `MKDirectionsTransportType.transit` is documented in
///   the SDK header as "Only supported for ETA calculations" — a travel time
///   comes back, a route never does. Route planning is handed off to Maps.
@MainActor
final class MapKitTravelTime: ObservableObject {
    static let shared = MapKitTravelTime()

    enum Mode: String, CaseIterable, Identifiable {
        case walking, driving, transit

        var id: String { rawValue }

        var label: String {
            switch self {
            case .walking: "Walk"
            case .driving: "Drive"
            case .transit: "Transit"
            }
        }

        var symbol: String {
            switch self {
            case .walking: "figure.walk"
            case .driving: "car.fill"
            case .transit: "tram.fill"
            }
        }

        var transportType: MKDirectionsTransportType {
            switch self {
            case .walking: .walking
            case .driving: .automobile
            case .transit: .transit
            }
        }

        var launchDirectionsMode: String {
            switch self {
            case .walking: MKLaunchOptionsDirectionsModeWalking
            case .driving: MKLaunchOptionsDirectionsModeDriving
            case .transit: MKLaunchOptionsDirectionsModeTransit
            }
        }
    }

    enum Estimate: Equatable {
        case pending
        /// Apple returned a route. Seconds, as given.
        case travelTime(TimeInterval)
        /// Apple answered, and the answer is "you can't get there this way" —
        /// no transit coverage, or a walk across water. A real result, not an
        /// error, so it's shown rather than retried.
        case unroutable
        /// Throttled, offline, or a server failure. Worth another tap.
        case failed

        /// Worth keeping. A failure deliberately isn't: it says nothing about
        /// the route, only about the moment it was asked, so caching one would
        /// make the retry button do nothing for ten minutes.
        var isCacheable: Bool {
            switch self {
            case .travelTime, .unroutable: true
            case .pending, .failed: false
            }
        }
    }

    /// Keyed on the destination rather than the listing id, because the point
    /// under the map is replaced when the item page lands — the city centroid
    /// gives way to the listing's own coordinate — and an ETA to the old point
    /// must not survive that swap. Rounding to four decimals (~11 m) keeps a
    /// jittering coordinate from missing its own cache entry.
    struct Key: Hashable {
        let latitude: Double
        let longitude: Double
        let mode: Mode

        init(destination: CLLocationCoordinate2D, mode: Mode) {
            latitude = (destination.latitude * 10_000).rounded() / 10_000
            longitude = (destination.longitude * 10_000).rounded() / 10_000
            self.mode = mode
        }
    }

    @Published private(set) var estimates: [Key: Estimate] = [:]
    private var computedAt: [Key: Date] = [:]

    /// Traffic moves and buses run to a timetable, so a cached answer is only
    /// good for so long. Ten minutes is long enough that scrolling back to a
    /// listing is free and short enough that the number is still true.
    private static let freshness: TimeInterval = 600

    func estimate(for destination: CLLocationCoordinate2D, mode: Mode) -> Estimate? {
        estimates[Key(destination: destination, mode: mode)]
    }

    /// Every mode at once, for one listing.
    ///
    /// Three requests is the whole budget for a screen. `MKDirections` is a
    /// rate-limited service that answers with `MKError.loadingThrottled` when
    /// leaned on, so the caller is expected to have a *settled* destination
    /// before asking — see `TravelTimeRow`, which waits for the item page
    /// rather than routing to the city centroid and then again to the listing.
    /// Nothing here is ever computed for a listing the user hasn't opened.
    func estimateAll(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async {
        await withTaskGroup(of: Void.self) { group in
            for mode in Mode.allCases {
                group.addTask { @MainActor in
                    await self.request(from: origin, to: destination, mode: mode)
                }
            }
        }
    }

    private func request(from origin: CLLocationCoordinate2D,
                         to destination: CLLocationCoordinate2D,
                         mode: Mode) async {
        let key = Key(destination: destination, mode: mode)
        if let existing = estimates[key], existing.isCacheable,
           let at = computedAt[key], Date().timeIntervalSince(at) < Self.freshness {
            return
        }
        if estimates[key] == .pending { return }     // already in flight
        estimates[key] = .pending

        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = mode.transportType
        // Transit without a departure time is meaningless — the next bus is the
        // whole answer. Harmless for the other two.
        request.departureDate = Date()

        do {
            let response = try await MKDirections(request: request).calculateETA()
            estimates[key] = .travelTime(response.expectedTravelTime)
        } catch let error as MKError {
            switch error.code {
            case .directionsNotFound, .placemarkNotFound:
                estimates[key] = .unroutable
            default:
                estimates[key] = .failed
            }
        } catch {
            estimates[key] = .failed
        }
        computedAt[key] = Date()
    }

    /// Whole minutes, then hours — the precision the input deserves. An ETA to
    /// a fuzzed point is not a number anyone should read to the second.
    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }
}
