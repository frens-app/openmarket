import Foundation
import CoreLocation
import os

/// Turning "here" or "that city" into a place Facebook recognises, for the two
/// screens that need it: the location sheet and the location step of onboarding.
///
/// Signed-in sessions use Facebook's own picker, because its precise coordinate
/// becomes durable session state. Signed-out sessions call the picker's
/// URL-resolution request directly, falling back to the picker if that internal
/// endpoint changes. Holding the in-flight state here keeps the two screens from
/// drifting apart; each keeps its own `AppleMapsCitySearch`, which is view state.
///
/// ## Optimistic, and precisely how far
///
/// Picker resolution is a ten-second round trip — 8.5 s signed in, 15.5 s
/// signed out (`docs/location.md` §4) — so the **label** is committed
/// immediately from Apple's name for the place.
///
/// The **segment** is not. Nothing may search without one, and the app never
/// derives one — it only stores a segment Facebook handed back. Committing it
/// optimistically would search the old city under the new city's name, this
/// area's characteristic silent failure. So `Preferences.resolvedPlace` changes
/// exactly once, on confirmation, which also makes rollback free: a failed
/// switch has written nothing.
///
/// Onboarding works the same way, with resolution overlapping the interests
/// step. Its last step is the one thing that waits — see `settle`.
@MainActor
final class PlaceChooser: ObservableObject {
    /// One per app: the sheet dismisses on the tap, so a switch outlives it and
    /// the results screen behind is what shows it in flight.
    static let shared = PlaceChooser()

    /// What is being waited on, so the right row shows the spinner.
    enum Pending: Equatable {
        case deviceFix
        case city(String)
    }

    /// A place the UI is already showing, which Facebook hasn't agreed to yet.
    struct Switch {
        /// What to call it meanwhile — Apple's name for the searched city, or
        /// the reverse-geocoded name of the device fix. Replaced by Facebook's
        /// own name on confirmation; the two naming systems disagree often,
        /// which is why `confirm` compares segments instead.
        var name: String
        /// Where it is, once known — immediately for a device fix, after
        /// Apple's lookup for a searched city. The picker's map recentres on it.
        var coordinate: CLLocationCoordinate2D?
        /// The place being left, so the UI can say what the user is still
        /// looking at rather than implying the results have already moved.
        let previous: String?
        let pending: Pending
    }

    /// A switch that didn't take. Held until dismissed or superseded.
    struct Failed: Equatable {
        let attempted: String
        let previous: String?
        /// What actually went wrong, in `message(for:)`'s words.
        let reason: String

        /// Names the place the user is *still on*: "it failed" alone leaves them
        /// guessing which city the results in front of them belong to.
        var summary: String {
            guard let previous else { return reason }
            return "Couldn't switch to \(attempted) — still browsing \(previous)."
        }

        /// Whether `reason` says anything `summary` didn't.
        var hasDetail: Bool { previous != nil }
    }

    @Published private(set) var switching: Switch?
    @Published private(set) var failure: Failed?

    /// The device fix was *refused*, rather than merely not arriving.
    ///
    /// Kept apart from `failure` because a fix that didn't land is worth
    /// retrying, while a refusal can't be retried from inside the app at all —
    /// iOS won't show the dialog twice — so it gets an alert pointing at
    /// Settings. Settable from outside because dismissing that alert clears it.
    @Published var needsLocationSettings = false

    /// What the UI should call the current place: the switch in flight if there
    /// is one, otherwise the confirmed place.
    var displayName: String? { switching?.name ?? prefs.locationName }

    var pending: Pending? { switching?.pending }
    var isBusy: Bool { switching != nil }

    private let prefs: Preferences

    /// Which switch is current.
    ///
    /// Bumped by every new intent, and checked before anything is applied, so a
    /// resolution that finishes after a newer one started is discarded rather
    /// than written over the newer answer.
    private var generation = 0
    private var inFlight: Task<Void, Never>?

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    func dismissFailure() {
        failure = nil
    }

    // MARK: - Starting a switch

    /// Commit to the device's own place now; agree it with Facebook after.
    ///
    /// The fix is awaited because it is the step that can raise the permission
    /// dialog, and a refusal has to be answered on the screen that asked. It is
    /// also the fast half — usually cached, capped at six seconds by
    /// `LocationProvider`.
    ///
    /// Returns whether a switch started, which is the sheet's cue to dismiss.
    @discardableResult
    func switchToDeviceLocation(via location: LocationProvider) async -> Bool {
        // Claimed before the fix, so the row can show a spinner while it lands.
        let mine = claim(Switch(name: "Current location",
                                coordinate: nil,
                                previous: prefs.locationName,
                                pending: .deviceFix))
        guard let point = await fix(from: location, for: mine) else { return false }
        guard mine == generation else { return false }
        // `LocationProvider` reverse-geocodes every fix, so there is usually a
        // real city name to show instead of "Current location". Label only —
        // deliberately no slug.
        if case .resolved(let name) = location.state, !name.isEmpty {
            switching?.name = name
        }
        switching?.coordinate = point
        resolve(mine, origin: .deviceFix, coordinate: { point },
                unplaceable: "Couldn't place that fix on the map.")
        return true
    }

    /// Commit to a searched city now. Nothing is awaited: Apple has already
    /// named the place, and the coordinate lookup runs in the background.
    func switchTo(_ suggestion: AppleMapsCitySearch.Suggestion,
                  from cities: AppleMapsCitySearch) {
        let mine = claim(Switch(name: suggestion.title,
                                coordinate: nil,
                                previous: prefs.locationName,
                                pending: .city(suggestion.display)))
        // Built here, not inside `resolve`: the picker clears its search field
        // on this same tap, and a request captured now is unaffected by the
        // completer being reset behind it.
        let lookup = cities.search(for: suggestion)
        resolve(mine, origin: .searchedCity,
                coordinate: { (try? await lookup.start())?.mapItems.first?.placemark.coordinate },
                unplaceable: "Couldn't place \(suggestion.title) on the map.")
    }

    /// Waits for whatever is in flight. For the one caller that cannot proceed
    /// on an optimistic answer: the end of onboarding, which must not let
    /// anyone into the app without a place it can search.
    func settle() async {
        await inFlight?.value
    }

    // MARK: - Machinery

    /// Takes ownership of the UI for a new intent, and returns the generation
    /// that owns it. Anything older is now stale by definition.
    private func claim(_ change: Switch) -> Int {
        failure = nil
        switching = change
        generation += 1
        return generation
    }

    private func fix(from location: LocationProvider,
                     for mine: Int) async -> CLLocationCoordinate2D? {
        guard let coordinate = await location.resolveOnce(prompt: .ifNeeded) else {
            if location.isDenied {
                // No `failure` too: the alert already says it.
                needsLocationSettings = true
                finish(mine, failure: nil)
            } else {
                finish(mine, failure: "Couldn't get a location fix. "
                       + "Try again, or search for a city instead.")
            }
            return nil
        }
        return coordinate
    }

    /// Hands the coordinate to Facebook, and applies the answer only if this is
    /// still the switch the user is waiting on.
    private func resolve(_ mine: Int,
                         origin: ResolvedPlace.Origin,
                         coordinate: @escaping () async -> CLLocationCoordinate2D?,
                         unplaceable: String) {
        let previous = inFlight
        // Cancelled *and* waited for: the signed-in resolution feeds a
        // coordinate into Facebook's session state and reads the result back
        // out, so a second overlapping one can read the first's answer and
        // store a place nobody asked for. The picker resolver checks for
        // cancellation between steps, so the old one unwinds in about a poll
        // interval rather than the full ten seconds.
        previous?.cancel()
        inFlight = Task {
            await previous?.value
            guard mine == generation else { return }

            guard let point = await coordinate() else {
                finish(mine, failure: unplaceable)
                return
            }
            guard mine == generation else { return }
            // The picker's map can now move to where this is going — the first
            // confirmation that Apple found the right city, since "Berkeley, CA"
            // and "Berkeley, NJ" read the same in a list.
            switching?.coordinate = point

            let name = switching?.name ?? "that place"
            switch await resolveForCurrentSession(point, name: name, origin: origin) {
            case .success(let place):
                guard mine == generation else { return }
                // The one write, and only ever from here: a confirmed place.
                prefs.setResolvedPlace(place)
                finish(mine, failure: nil)
            case .failure(.superseded):
                // A newer switch owns the UI and its own failure wording.
                return
            case .failure(let error):
                finish(mine, failure: Self.message(for: error))
            }
        }
    }

    /// Anonymous sessions only need Facebook's URL identifier. The exact
    /// coordinate the picker also writes into its cookie-backed session is
    /// skipped: it disappears with that short-lived session and costs most of
    /// the location-change latency. Account sessions keep the full picker route
    /// so their more precise ranking state is preserved.
    private func resolveForCurrentSession(_ coordinate: CLLocationCoordinate2D,
                                          name: String,
                                          origin: ResolvedPlace.Origin) async
        -> Result<ResolvedPlace, MarketplacePlaceResolver.Failure> {
        guard !Task.isCancelled else { return .failure(.superseded) }

        if await SessionState.isSignedIn(settleFor: .milliseconds(300)) {
            guard !Task.isCancelled else { return .failure(.superseded) }
            return await MarketplacePlaceResolver().resolve(coordinate, origin: origin)
        }

        let direct = await UnauthenticatedMarketplacePlaceResolver()
            .resolve(coordinate, name: name, origin: origin)
        switch direct {
        case .success, .failure(.paced), .failure(.superseded):
            return direct
        case .failure:
            guard !Task.isCancelled else { return .failure(.superseded) }
            Logger.place.info("anonymous direct resolver unavailable; falling back to location picker")
            return await MarketplacePlaceResolver().resolve(coordinate, origin: origin)
        }
    }

    /// Drops the optimistic state, which is the whole of the rollback: the
    /// label reverts to `Preferences.locationName` because nothing wrote over it.
    private func finish(_ mine: Int, failure reason: String?) {
        guard mine == generation else { return }
        let change = switching
        switching = nil
        guard let reason else {
            failure = nil
            return
        }
        failure = Failed(attempted: change?.name ?? "that place",
                         previous: change?.previous,
                         reason: reason)
    }

    /// Named rather than generic: the distinction is what makes a bug report
    /// from a user useful.
    static func message(for error: MarketplacePlaceResolver.Failure) -> String {
        switch error {
        case .noPill: "Facebook's location control wasn't on the page."
        case .noArrow: "Facebook's location dialog didn't offer the current-location button."
        case .notAsked: "Facebook didn't ask for a position."
        case .unresolved: "Facebook didn't recognise that place."
        case .paced: "Too many requests just now. Try again shortly."
        // Never shown — `resolve` returns before composing a message for it —
        // but listed rather than defaulted so a future caller says something true.
        case .superseded: "Replaced by a newer location change."
        case .notConfirmed(let shown):
            if let shown {
                "Facebook set the location but then served \(shown) instead. Not saved."
            } else {
                "Couldn't confirm the location took effect. Not saved."
            }
        }
    }
}
