import SwiftUI
import MapKit

/// An approximate-area map for a listing.
///
/// Facebook labels every location "Location is approximate", so this draws an
/// area rather than a pin: a pin would imply a precision that doesn't exist and
/// would point at an address the seller never shared.
///
/// The blue area is reserved for Facebook's listing-specific coordinate. A
/// city centroid is useful for orientation, but drawing an area around it would
/// imply that Facebook narrowed the listing down when it did not.
struct LocationMapCard: View {
    /// Not rendered — the place is named under the title, where it stays put
    /// whether or not this card can draw. Kept for the accessibility label.
    let place: String
    let coordinate: CLLocationCoordinate2D
    let precision: Precision
    /// The device's own fix, when there is one. Drawn as a live dot so the
    /// listing's area can be read against where the user actually is.
    var userLocation: CLLocationCoordinate2D?

    /// Where the centre came from — and therefore how much of the map around it
    /// the listing could actually be in.
    enum Precision {
        /// Facebook's own published point for this listing, off the item page.
        /// Snapped to a lattice, but tied to the listing: a sample sat ~4.5 km
        /// from the San Francisco centroid the city fallback would have used.
        case listing
        /// A geocoded centroid of the place name, the only thing available
        /// before the item page loads. The listing is somewhere in the city,
        /// which is a far weaker claim: show the city-level map without an
        /// uncertainty circle.
        case city
        /// Nothing has been chosen yet, so there is no area to draw.
        ///
        /// The map still renders — orientation is useful before a decision,
        /// not only after one — but it makes no claim: no circle, because a
        /// circle here would assert a search area that hasn't been set.
        case unset

        /// Radius of the circle drawn for a city centroid, in metres. Still a
        /// guess — a city-sized blob, not a measurement, unlike `.listing`.
        var cityRadius: CLLocationDistance { 6_000 }

        var caption: String {
            switch self {
            // Saying the size is worth a few words: "approximate" on its own
            // invites the reader to imagine a street, and it's a district.
            case .listing: "Approximate area · within about 0.4 mi"
            case .city: "City only"
            case .unset: "No location chosen yet"
            }
        }
    }

    /// Radius of the drawn circle, in metres.
    ///
    /// A circle rather than the lattice cell it stands for, deliberately.
    /// Facebook draws an area around its own listings, and a user
    /// cross-referencing the two screens shouldn't have to wonder why ours is
    /// a rectangle — the familiar shape is worth more here than the extra
    /// fidelity, since both are saying the same thing: "somewhere around
    /// here".
    ///
    /// The *size* is still measured rather than invented. This is the cell's
    /// half-diagonal, so the circle circumscribes the real uncertainty region:
    /// it can overstate the area slightly at the corners, and can never
    /// understate it. ~572 m in San Francisco, widening towards the equator as
    /// the cell does.
    private var areaRadius: CLLocationDistance {
        switch precision {
        case .listing: FacebookCoordinateGrid.worstCaseError(at: coordinate.latitude)
        case .city: precision.cityRadius
        // Nothing is drawn at this size; it only sets the framing below, wide
        // enough to read as a metro area rather than a street.
        case .unset: 8_000
        }
    }

    /// Frames the drawn area at roughly a third of the map's width, so the
    /// zoom follows the claim instead of being fixed at city scale.
    private var span: CLLocationDistance { areaRadius * 3 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Map(initialPosition: .region(region), interactionModes: []) {
                // Only a listing-specific point defines an uncertainty area.
                // A city centroid is map framing, not evidence that the item
                // is within any particular radius of downtown.
                if precision == .listing {
                    MapCircle(center: coordinate, radius: areaRadius)
                        .foregroundStyle(.tint.opacity(0.18))
                        .stroke(.tint.opacity(0.55), lineWidth: 1)
                }

                if let userLocation {
                    // Drawn from the fix the app already holds rather than with
                    // `UserAnnotation`, which would start MapKit tracking the
                    // device continuously — §7.3 takes one fix on demand and
                    // nothing else, and that principle outranks getting the
                    // system dot for free.
                    Annotation("Your location", coordinate: userLocation) {
                        LiveLocationDot()
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)

            Text(precision.caption)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        // The map is re-centred when the item page's coordinate lands, and
        // again when the user's fix arrives, both after the first frame.
        // `initialPosition` is read once, so the view has to be rebuilt rather
        // than updated.
        .id("\(coordinate.latitude),\(coordinate.longitude),\(userLocation?.latitude ?? 0)")
    }

    private var accessibilityLabel: String {
        let base = precision == .unset ? precision.caption : "\(precision.caption) around \(place)"
        return userLocation == nil ? base : base + ", with your location shown"
    }

    /// Framed on the listing, widened to take in the user only when they're
    /// close enough that both still read.
    ///
    /// Zooming out to fit a listing thirty miles away would shrink the area
    /// itself to a dot and turn the card into a map of the Bay — the listing is
    /// the subject, and the dot is context when there's room for it.
    private var region: MKCoordinateRegion {
        let listingOnly = MKCoordinateRegion(center: coordinate,
                                             latitudinalMeters: span,
                                             longitudinalMeters: span)
        guard let userLocation else { return listingOnly }
        let separation = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: userLocation.latitude, longitude: userLocation.longitude))
        guard separation < span * 1.5 else { return listingOnly }
        let centre = CLLocationCoordinate2D(
            latitude: (coordinate.latitude + userLocation.latitude) / 2,
            longitude: (coordinate.longitude + userLocation.longitude) / 2
        )
        // 2.6x the separation leaves a comfortable margin around both ends.
        let meters = max(span, separation * 2.6)
        return MKCoordinateRegion(center: centre,
                                  latitudinalMeters: meters,
                                  longitudinalMeters: meters)
    }
}

/// A live "you are here" dot with a slow outward ping.
///
/// The ping is doing a job, not decorating: this map is otherwise entirely
/// static, so a still dot would read as one more drawn feature rather than as
/// the user's own position, updating.
private struct LiveLocationDot: View {
    private static let period: TimeInterval = 1.8

    var body: some View {
        // Driven off the timeline rather than by a `repeatForever` animation on
        // `@State`: inside a map annotation the implicit animation never ran —
        // two screenshots seconds apart were pixel-identical — and a ping that
        // doesn't move is worse than no ping, because it reads as a drawn
        // feature of the map.
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.35))
                    .frame(width: 30, height: 30)
                    .scaleEffect(0.5 + 1.3 * phase)
                    .opacity(1 - phase)
                Circle()
                    .fill(.tint)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .shadow(radius: 1)
            }
        }
    }
}
