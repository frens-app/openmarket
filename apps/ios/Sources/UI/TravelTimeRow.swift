import SwiftUI
import CoreLocation
import UIKit

/// "How long to go get it?", under the map.
///
/// Runs on its own, as soon as there's a point worth routing to. Opening a
/// listing is already the deliberate act — nobody taps into a detail screen by
/// accident — so making the user ask a second time bought nothing.
///
/// **Both ends have to be real, or there is no row.**
///
/// The destination must be the listing's own published point, off the item
/// page. A city centroid is not a weaker version of that answer, it is a
/// different one: routing to the middle of San Francisco from the Inner Sunset
/// gives a confident "8 min walk" for something that is an hour away. A
/// distance shown against a centroid is at least captioned as approximate and
/// reads as a rough sort order; a travel time reads as a plan. So the row
/// stays away entirely until enrichment lands.
///
/// The origin must be the device's own fix. Everything else on this screen
/// degrades gracefully without one; a travel time cannot, because there would
/// be nowhere to travel *from*. The chosen search city is not a substitute: it
/// says which listings Facebook returns, not where the user is.
///
/// **And the search itself has to be one the user is inside.** Browsing Toronto
/// from San Francisco, "how long to get there" has no useful answer — the
/// honest one is a flight, and nobody asked. So the row appears only while the
/// saved location came from the device (`ResolvedPlace.isUserLocation`) rather
/// than from a city someone searched for.
///
/// That is *in addition to* the distance cutoff, not instead of it — the two
/// catch different things. The type gate handles browsing a city you are not
/// in; the cutoff handles the individual listing that is 90 miles out of a
/// search you ran from home, which "Newest first" produces regularly.
///
/// The fix it routes from is taken **fresh**, unlike everything else here.
/// Distances measure from the saved search point precisely so they hold still
/// as the user walks; travel time has the opposite requirement, because it is a
/// question about where they are standing now.
struct TravelTimeRow: View {
    let destination: CLLocationCoordinate2D
    let precision: LocationMapCard.Precision

    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var prefs: Preferences
    @StateObject private var travel = MapKitTravelTime.shared
    @Environment(\.openURL) private var openURL

    /// Where the user is *now*, re-fixed when this listing was opened. Nil
    /// until it lands, so the row waits rather than routing from a stale point.
    @State private var freshOrigin: CLLocationCoordinate2D?

    @ViewBuilder
    var body: some View {
        if precision == .listing, prefs.resolvedPlace?.isUserLocation == true {
            if let origin = freshOrigin {
                if isWorthRouting(from: origin) {
                    estimates(from: origin)
                }
            } else if location.isUndecided {
                // The one place in the app where location has an obvious,
                // concrete payoff to point at — same argument as the seller
                // sign-in prompt this is modelled on. Tapping summons the
                // system dialog; nothing here asks for anything itself.
                LocationPrompt(
                    title: "Enable location for travel estimates",
                    subtitle: "Walking, driving and transit times from where you are. Your location never leaves your device.",
                    action: { Task { freshOrigin = await location.resolveFresh(prompt: .ifNeeded) } }
                )
            } else if location.isDenied {
                LocationPrompt(
                    title: "Location is off for Open Market",
                    subtitle: "Turn it on in Settings to see how long it takes to get here.",
                    action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                )
            } else {
                // Authorised, fix not landed yet. Nothing to show and nothing
                // to ask for — just take the fix. Keyed on the destination so
                // opening a different listing re-fixes rather than reusing the
                // position from the last one.
                Color.clear
                    .frame(height: 0)
                    .task(id: trigger) { freshOrigin = await location.resolveFresh() }
            }
        }
    }

    private func estimates(from origin: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            modes
            HStack(spacing: 8) {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                // Throttling and dropped connections are both transient and
                // both look identical from here, so the only sensible
                // response is to offer another go.
                if anyFailed {
                    Button("Try again") { Task { await run(from: origin) } }
                        .font(.caption)
                }
            }
        }
        // Keyed on the destination, so this fires once per point. The point
        // can only be the listing's own by the time we're here, and that never
        // changes again — so this runs exactly once per listing, and returning
        // within the freshness window reuses the answer rather than
        // re-requesting it.
        .task(id: trigger) { await run(from: origin) }
    }

    /// A hundred miles is past any "go and collect it" trip and well short of a
    /// normal metro-area search — which routinely reaches 60-90 miles under
    /// "Newest first". Past that the drive is a two-day answer to a question
    /// nobody asked, and the transit leg is a flight MapKit won't route anyway.
    private func isWorthRouting(from origin: CLLocationCoordinate2D) -> Bool {
        CLLocation(latitude: destination.latitude, longitude: destination.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)) < 160_000
    }

    private func run(from origin: CLLocationCoordinate2D) async {
        await travel.estimateAll(from: origin, to: destination)
    }

    private var trigger: String {
        "\(destination.latitude),\(destination.longitude)"
    }

    private var anyFailed: Bool {
        MapKitTravelTime.Mode.allCases
            .contains { travel.estimate(for: destination, mode: $0) == .failed }
    }

    private var modes: some View {
        HStack(spacing: 8) {
            ForEach(MapKitTravelTime.Mode.allCases) { mode in
                ModeChip(mode: mode, estimate: travel.estimate(for: destination, mode: mode) ?? .pending)
            }
        }
    }

    /// Only one case can reach this, but it still says what it measured to:
    /// the destination is Facebook's *approximate* point, so these are minutes
    /// to a neighbourhood and not to a door.
    private let caption = "Estimated to the approximate area, from your location"
}

/// Deliberately the same card as `sellerSignInPrompt`: an absent capability
/// explained where its payoff would have been, rather than a blank space that
/// reads as "there is nothing to say here".
private struct LocationPrompt: View {
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "location.circle")
                    .font(.body)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
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
    }
}

private struct ModeChip: View {
    let mode: MapKitTravelTime.Mode
    let estimate: MapKitTravelTime.Estimate

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: mode.symbol)
                .font(.subheadline)
            value
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(isKnown ? .primary : .secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var value: some View {
        switch estimate {
        case .pending: ProgressView().controlSize(.mini)
        case .travelTime(let seconds): Text(MapKitTravelTime.format(seconds))
        case .unroutable: Text("No route")
        case .failed: Text("—")
        }
    }

    private var isKnown: Bool {
        if case .travelTime = estimate { return true }
        return false
    }

    private var accessibilityText: String {
        switch estimate {
        case .pending: "\(mode.label), estimating"
        case .travelTime(let seconds): "\(mode.label), about \(MapKitTravelTime.format(seconds))"
        case .unroutable: "\(mode.label), no route"
        case .failed: "\(mode.label), unavailable"
        }
    }
}
