import SwiftUI
import CoreLocation
import UIKit

/// "How long to go get it?", under the map.
///
/// Runs on its own, as soon as there's a point worth routing to. Opening a
/// listing is already the deliberate act — nobody taps into a detail screen by
/// accident — so making the user ask a second time bought nothing.
///
/// Both ends need coordinates before estimates can be calculated.
///
/// The destination must be the listing's own published point, off the item
/// page. A city centroid is not a weaker version of that answer, it is a
/// different one: routing to the middle of San Francisco from the Inner Sunset
/// gives a confident "8 min walk" for something that is an hour away. A
/// distance shown against a centroid is at least captioned as approximate and
/// reads as a rough sort order; a travel time reads as a plan. Until enrichment
/// lands, explain why estimates aren't available.
///
/// The origin must be the device's own fix. Everything else on this screen
/// degrades gracefully without one; a travel time cannot, because there would
/// be nowhere to travel *from*. The chosen search city is not a substitute: it
/// says which listings Facebook returns, not where the user is.
///
/// The listing must be within 160 km of the device's current location.
/// How the user selected their search city does not affect travel estimates.
///
/// The fix it routes from is taken **fresh**, unlike everything else here.
/// Distances measure from the saved search point precisely so they hold still
/// as the user walks; travel time has the opposite requirement, because it is a
/// question about where they are standing now.
struct TravelTimeRow: View {
    let destination: CLLocationCoordinate2D?
    let isLoadingDestination: Bool
    let openDirections: (MapKitTravelTime.Mode) -> Void

    var body: some View {
        if let destination {
            LocatedTravelTimeRow(destination: destination, openDirections: openDirections)
                .id("\(destination.latitude),\(destination.longitude)")
        } else if isLoadingDestination {
            TravelEstimateNote("Loading the listing’s location for travel estimates…", isLoading: true)
        } else {
            TravelEstimateNote("Travel estimates aren’t available because this listing’s approximate location is missing.")
        }
    }
}

private struct LocatedTravelTimeRow: View {
    let destination: CLLocationCoordinate2D
    let openDirections: (MapKitTravelTime.Mode) -> Void

    @EnvironmentObject private var location: LocationProvider
    @StateObject private var travel = MapKitTravelTime.shared
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    /// Where the user is *now*, re-fixed when this listing was opened. Nil
    /// until it lands, so the row waits rather than routing from a stale point.
    @State private var freshOrigin: CLLocationCoordinate2D?
    @State private var isResolvingLocation = false
    @State private var locationFailed = false

    @ViewBuilder
    var body: some View {
        Group {
            if location.isUndecided {
                // The one place in the app where location has an obvious,
                // concrete payoff to point at — same argument as the seller
                // sign-in prompt this is modelled on. Tapping summons the
                // system dialog; nothing here asks for anything itself.
                LocationPrompt(
                    title: "Enable location for travel estimates",
                    subtitle: "Walking, driving and transit times from where you are.",
                    action: { Task { await resolveLocation(prompt: .ifNeeded) } }
                )
            } else if location.isDenied {
                LocationPrompt(
                    title: "Location is off for Openmarket",
                    subtitle: "Turn it on in Settings to see how long it takes to get here.",
                    action: {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                )
            } else if let origin = freshOrigin {
                if isWorthRouting(from: origin) {
                    estimates(from: origin)
                } else {
                    TravelEstimateNote("Travel estimates are only shown for listings within about 100 miles of your current location. You can still tap the map for directions.")
                }
            } else if locationFailed, !isResolvingLocation {
                LocationPrompt(
                    title: "Try your location again",
                    subtitle: "We couldn’t get your current location to estimate travel times.",
                    action: { Task { await resolveLocation() } }
                )
            } else {
                TravelEstimateNote("Finding your location for travel estimates…", isLoading: true)
            }
        }
        .task { if location.isAuthorized { await resolveLocation() } }
        .onChange(of: location.isAuthorized) { _, authorized in
            if !authorized { freshOrigin = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from Settings should replace the enable-location card
            // with estimates without requiring the listing to be reopened.
            if phase == .active, location.isAuthorized, freshOrigin == nil {
                Task { await resolveLocation() }
            }
        }
    }

    private func resolveLocation(prompt: LocationProvider.Prompt = .never) async {
        guard !isResolvingLocation else { return }
        isResolvingLocation = true
        locationFailed = false
        defer { isResolvingLocation = false }
        freshOrigin = await location.resolveFresh(prompt: prompt)
        locationFailed = freshOrigin == nil
    }

    private func estimates(from origin: CLLocationCoordinate2D) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            modes
            HStack(spacing: 8) {
                Text(anyFailed ? "Some travel estimates couldn’t be loaded." : caption)
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

    /// Only request estimates for local pickup trips, measured from the device.
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
                Button {
                    openDirections(mode)
                } label: {
                    ModeChip(mode: mode, estimate: travel.estimate(for: destination, mode: mode) ?? .pending)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(mode.label.lowercased()) directions to the approximate area in Apple Maps")
            }
        }
    }

    /// Only one case can reach this, but it still says what it measured to:
    /// the destination is Facebook's *approximate* point, so these are minutes
    /// to a neighbourhood and not to a door.
    private let caption = "Estimated to the approximate area, from your location"
}

private struct TravelEstimateNote: View {
    let message: String
    var isLoading = false

    init(_ message: String, isLoading: Bool = false) {
        self.message = message
        self.isLoading = isLoading
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "info.circle")
                    .accessibilityHidden(true)
            }
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
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
