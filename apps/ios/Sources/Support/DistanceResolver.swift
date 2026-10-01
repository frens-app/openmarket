import Foundation
import CoreLocation
import os

/// Resolves city centers for filtering and approximate listing points for display.
/// Numeric listing distances require a point supplied by the item's detail page.
@MainActor
final class DistanceResolver: ObservableObject {
    static let shared = DistanceResolver()

    @Published private(set) var placeCoordinates: [String: [Double]] {
        didSet { defaults.set(placeCoordinates, forKey: Self.cacheKey) }
    }
    @Published private(set) var userLocation: CLLocation?

    private let defaults: UserDefaults
    private var queued: [String] = []
    private var known: Set<String> = []     // queued, resolved, or given up on
    private var isDraining = false
    private var failed: Set<String> = []
    private let geocoder = CLGeocoder()
    private static let cacheKey = "placeCoordinates"

    /// One `CLGeocoder` handles one request at a time, so the trickle queue
    /// spaces its lookups rather than firing one per visible card.
    private static let gapBetweenLookups = Duration.milliseconds(250)

    /// How many lookups `resolveAll` runs at once, each on its own geocoder.
    ///
    /// The one-at-a-time limit is a property of a `CLGeocoder` instance, not of
    /// the service, so a batch can have several in flight. Measured against the
    /// live service with twelve Bay Area city names: 205 ms for all twelve
    /// concurrently, against 439 ms for four serially — and ~4 s for twelve
    /// through the queue above, whose gap dominates everything.
    ///
    /// Eight rather than unlimited because the service does rate-limit, and a
    /// throttled lookup fails rather than waiting. A refused name is not a
    /// disaster — an unknown distance is *kept*, which is today's behaviour —
    /// but it is the failure this batch exists to avoid.
    private static let batchWidth = 8

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        placeCoordinates = defaults.dictionary(forKey: Self.cacheKey) as? [String: [Double]] ?? [:]
    }

    func setUserLocation(_ coordinate: CLLocationCoordinate2D?) {
        guard let coordinate else { return }
        userLocation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    /// Where distances should be measured *from*: the coordinate the current
    /// search was built on, whichever kind it is.
    ///
    /// Two reasons it is the saved point rather than the live device fix.
    ///
    /// Browsing another city breaks the assumption that "the user" and "the
    /// search" are in the same place. Measured from a San Francisco fix, every
    /// Toronto listing reads "~2273 mi" and the radius filter hides the entire
    /// result set — technically true and useless, since the question a distance
    /// answers here is "how far across *this* city".
    ///
    /// And even when the search *is* where the user is, a live fix means the
    /// numbers drift as they walk: cards slide in and out of the radius with no
    /// search having happened, which reads as the grid glitching. Distances
    /// belong to the search that produced them, so they hold still until the
    /// next one.
    ///
    /// The device fix is used only before any place has been resolved.
    static func origin(for place: ResolvedPlace?,
                       deviceFix: CLLocationCoordinate2D?) -> CLLocationCoordinate2D? {
        place?.coordinate ?? deviceFix
    }

    /// The geocoded centre of a place name, once resolved. This is a city or
    /// neighbourhood centroid, never the listing itself — Facebook only ever
    /// says "Location is approximate".
    func coordinate(for place: String?) -> CLLocationCoordinate2D? {
        guard let key = normalize(place),
              let pair = placeCoordinates[key], pair.count == 2 else { return nil }
        return CLLocationCoordinate2D(latitude: pair[0], longitude: pair[1])
    }

    /// Straight-line distance from the search origin to Facebook's approximate
    /// listing point. City centroids cannot establish an item's distance.
    func enrichedDistanceText(for listing: Listing) -> String? {
        guard let userLocation, let point = enrichedCoordinate(for: listing) else { return nil }
        let miles = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: userLocation) / 1609.34
        if miles < 0.1 { return "Nearby" }
        if miles < 10 { return String(format: "~%.1f mi", miles) }
        return "~\(Int(miles.rounded())) mi"
    }

    /// The listing's own approximate point, present only for listings whose
    /// item page has been read.
    func enrichedCoordinate(for listing: Listing) -> CLLocationCoordinate2D? {
        guard let latitude = listing.detail?.latitude,
              let longitude = listing.detail?.longitude else { return nil }
        let point = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard latitude.isFinite, longitude.isFinite, CLLocationCoordinate2DIsValid(point) else { return nil }
        return point
    }

    /// Shared by cards and detail; city-only listings show their place name.
    func bestDistanceText(for listing: Listing) -> String? {
        enrichedDistanceText(for: listing)
    }

    /// Kilometres to a listing, preferring its own approximate point over the
    /// centroid of its city.
    ///
    /// Returns nil when the answer isn't known yet — the user has no fix, or
    /// the place hasn't been geocoded. Callers filtering on distance must treat
    /// that as "keep", never "hide": geocoding is asynchronous, and hiding on
    /// missing data makes listings vanish and reappear as the queue drains.
    func distanceKM(for place: String?, coordinate: CLLocationCoordinate2D? = nil) -> Double? {
        guard let userLocation else { return nil }
        let point: CLLocationCoordinate2D?
        if let coordinate {
            point = coordinate
        } else {
            point = self.coordinate(for: place)
        }
        guard let point else { return nil }
        let metres = CLLocation(latitude: point.latitude, longitude: point.longitude)
            .distance(from: userLocation)
        return metres / 1000
    }

    /// Resolve a whole result set at once, and don't come back until it's done.
    ///
    /// **This is what stops the grid resizing under the user.** A result set is
    /// filtered on distance in `ResultsView.winnowed`, and a listing whose
    /// distance isn't known yet has to be *kept* — hiding on missing data would
    /// make cards vanish and reappear as lookups landed. So the cards were drawn
    /// first and removed afterwards, one every 250 ms as the trickle queue
    /// drained, and the grid visibly shrank for several seconds after a search
    /// completed. Worse, `ListingCard` starts its own lookup from `.task`, which
    /// inside a `LazyVStack` only fires near the viewport — so the shrinking
    /// followed the user down the page as they scrolled.
    ///
    /// Called before a result set is published, that whole class of behaviour
    /// stops existing: every distance is known by the time anything is drawn,
    /// so the filter has already run and the grid arrives at its final size.
    ///
    /// Cheap, because it is concurrent and because the cache is persistent —
    /// after a search or two in a metro area this is a no-op. The trickle queue
    /// stays for listings that arrive by other routes (the saved and recently
    /// viewed rails, a detail screen), where nothing is filtered and a distance
    /// appearing a moment later costs nothing.
    ///
    /// - Parameter deadline: how long to keep starting new batches. Checked
    ///   between batches rather than enforced with cancellation, because
    ///   `CLGeocoder` won't reliably abandon a request in flight — racing it
    ///   would hold the grid *longer*. The real bound is that every failure mode
    ///   here (offline, rate-limited, unplaceable) returns fast rather than
    ///   hanging; the deadline is for the case that assumption is wrong.
    func resolveAll(_ places: [String?], deadline: Duration = .seconds(5)) async {
        let names = Set(places.compactMap(normalize))
            .filter { placeCoordinates[$0] == nil && !failed.contains($0) }
        guard !names.isEmpty else { return }
        // Claimed up front so the trickle queue doesn't chase the same names.
        known.formUnion(names)

        let started = ContinuousClock.now
        let expiry = started.advanced(by: deadline)
        var resolved: [String: [Double]] = [:]
        for batch in Array(names).chunked(into: Self.batchWidth) {
            guard ContinuousClock.now < expiry else {
                Logger.distance.info("batch deadline reached, \(names.count - resolved.count, privacy: .public) left to the queue")
                break
            }
            await withTaskGroup(of: (String, [Double]?).self) { group in
                for name in batch {
                    group.addTask {
                        // A geocoder each: the one-request-at-a-time rule is per
                        // instance, and sharing one is what makes a batch serial.
                        let marks = try? await CLGeocoder().geocodeAddressString(name)
                        guard let location = marks?.first?.location else { return (name, nil) }
                        return (name, [location.coordinate.latitude, location.coordinate.longitude])
                    }
                }
                for await (name, pair) in group {
                    if let pair { resolved[name] = pair } else { failed.insert(name) }
                }
            }
        }
        let ms = Int(started.duration(to: .now) / .milliseconds(1))
        Logger.distance.info("batch: \(resolved.count, privacy: .public)/\(names.count, privacy: .public) places in \(ms, privacy: .public)ms")
        guard !resolved.isEmpty else { return }
        // One assignment for the whole batch: `placeCoordinates` is `@Published`
        // and persists on every write, so merging key by key would be a render
        // and a `UserDefaults` write per city.
        placeCoordinates.merge(resolved) { _, new in new }
    }

    /// Safe to call from a card's `task` on every render — repeats and
    /// already-known places are no-ops. Deliberately does *not* require the
    /// user's location, so places seen before the GPS fix still get resolved.
    func resolve(place: String?) {
        guard let key = normalize(place),
              placeCoordinates[key] == nil,
              !known.contains(key) else { return }
        known.insert(key)
        queued.append(key)
        drain()
    }

    private func drain() {
        guard !isDraining else { return }
        isDraining = true
        Task {
            defer { isDraining = false }
            while !queued.isEmpty {
                let key = queued.removeFirst()
                if let placemarks = try? await geocoder.geocodeAddressString(key),
                   let location = placemarks.first?.location {
                    placeCoordinates[key] = [location.coordinate.latitude, location.coordinate.longitude]
                } else {
                    // Not retried this session — `known` already holds it, and
                    // `failed` is what keeps `resolveAll` from firing a fresh
                    // batch at the same unplaceable names on every search.
                    // Deliberately not persisted: a launch spent offline would
                    // otherwise blacklist half a metro area permanently.
                    failed.insert(key)
                }
                try? await Task.sleep(for: Self.gapBetweenLookups)
            }
        }
    }

    private func normalize(_ place: String?) -> String? {
        guard let place else { return nil }
        let trimmed = place.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}

extension Logger {
    static let distance = Logger(subsystem: "lol.frens.openmarket", category: "distance")
}
