import Foundation
import CoreLocation
import os

/// Turning "here" or "that city" into a place Facebook recognises.
///
/// Both routes end in the same three steps — get a coordinate, ask Facebook
/// what URL represents it, store what Facebook calls the result — and there are
/// now two screens that need them: the location sheet, and the location step of
/// onboarding. Signed-in sessions use Facebook's own picker because its precise
/// coordinate becomes durable session state. Signed-out sessions call the
/// picker's URL-resolution request directly and fall back to the picker if that
/// internal endpoint changes. This holds the in-flight state and the failure
/// wording so the two screens can't drift apart; each screen keeps its own
/// `AppleMapsCitySearch`, which is view state and doesn't survive nesting inside
/// another `ObservableObject` anyway.
///
/// ## Optimistic, and precisely how far
///
/// Picker resolution is a ten-second round trip — 8.5 s signed in, 15.5 s
/// signed out (`docs/location.md` §4). The anonymous direct route is normally a
/// few hundred milliseconds, but the UI remains optimistic because fallback
/// still has to be correct. So the **label is committed immediately**: Apple has
/// already named the place, or the device fix has, and that name is good enough
/// to put in the pill while the real resolution runs underneath.
///
/// What is deliberately *not* committed is the **segment**. Nothing may search
/// without one, and the app never derives one — it only ever stores a segment
/// Facebook handed back. Searching optimistically would mean searching the old
/// city under the new city's name, this area's characteristic silent failure.
/// So `Preferences.resolvedPlace` still changes exactly once, after Facebook's
/// direct URL response or the picker confirmation.
///
/// That split is also what makes rollback free: a failed switch has written
/// nothing, so undoing it is dropping `switching`, and an app killed mid-switch
/// relaunches on the place it had.
///
/// Both screens work this way, onboarding included — a first run is the worst
/// possible place to spend ten seconds staring at a spinner, and the resolution
/// there overlaps with the user picking their interests instead. The one thing
/// that still waits is the very last step of onboarding, which cannot hand
/// somebody a home screen with no place behind it: see `settle`.
@MainActor
final class PlaceChooser: ObservableObject {
    /// One per app, because a switch now outlives the sheet that started it.
    ///
    /// Each screen used to own a `@StateObject`, which was fine while the sheet
    /// stayed up for the whole resolution — the state died with the only thing
    /// displaying it. Now the sheet dismisses on the tap, and the results
    /// screen behind it is what has to show the switch in flight.
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
        /// own name on confirmation, which is not a failure: `confirm` compares
        /// segments precisely because the two naming systems disagree often.
        var name: String
        /// Where it is, once known — immediately for a device fix, and after
        /// Apple's lookup for a searched city. The picker's map recentres on
        /// this, so the target is somewhere you can look at rather than only a
        /// name you have to trust.
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

        /// The headline. Names the place the user is *still on*, because that
        /// is the fact they need — "it failed" leaves them guessing which city
        /// the results in front of them belong to.
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
    /// Kept apart from `failure` because the two need different answers. A fix
    /// that didn't land is worth retrying, and a footnote saying so is enough.
    /// A refusal can't be retried from inside the app at all — iOS won't show
    /// the dialog a second time — so it gets an alert with the only action that
    /// changes anything (`locationSettingsAlert`). Screens bind to this
    /// directly, which is why it's settable from outside: dismissing the alert
    /// clears it.
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
    /// The **fix** is still awaited, for two reasons: it is the step that can
    /// raise the permission dialog, and a refusal has to be answered on the
    /// screen that asked rather than in a banner behind a sheet that has
    /// already gone. It is also the fast half — usually already cached, and
    /// capped at six seconds by `LocationProvider`.
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
        // `LocationProvider` reverse-geocodes every fix before it returns one,
        // so by here there is usually a real city name to show instead of
        // "Current location". Only a label — it writes no slug, deliberately.
        if case .resolved(let name) = location.state, !name.isEmpty {
            switching?.name = name
        }
        switching?.coordinate = point
        resolve(mine, origin: .deviceFix, coordinate: { point },
                unplaceable: "Couldn't place that fix on the map.")
        return true
    }

    /// Commit to a searched city now.
    ///
    /// Nothing is awaited at all: Apple has already named the place, and the
    /// coordinate lookup behind the suggestion is part of the background work
    /// rather than a reason to hold the sheet open for a round trip.
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

    /// Waits for whatever is in flight, if anything.
    ///
    /// For the one place that genuinely cannot proceed on an optimistic answer:
    /// the end of onboarding, which must not let anyone into the app without a
    /// place the app can actually search. Everywhere else, waiting is the thing
    /// this class exists to avoid — and even there the wait is usually already
    /// over, because it overlaps with the user picking their interests.
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
                // The alert says all of it, and it is already on screen. A
                // banner underneath repeating the refusal would be the same
                // news twice.
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
        // Cancelled *and* waited for.
        //
        // The signed-in resolution feeds a coordinate into Facebook's session
        // state and reads the result back out, so two overlapping ones don't
        // merely waste a round trip — the second can read the first's answer
        // and store a place nobody asked for. The anonymous route is isolated,
        // but sharing this cancellation rule keeps both paths ordered. The
        // picker resolver checks for cancellation between steps, so the old one
        // unwinds in about a poll interval rather than the full ten seconds.
        previous?.cancel()
        inFlight = Task {
            await previous?.value
            guard mine == generation else { return }

            guard let point = await coordinate() else {
                finish(mine, failure: unplaceable)
                return
            }
            guard mine == generation else { return }
            // Now the picker's map can move to where this is going, which for a
            // searched city is the first honest confirmation that Apple found
            // the right one — "Berkeley, CA" and "Berkeley, NJ" read the same
            // in a list and not at all the same on a map.
            switching?.coordinate = point

            let name = switching?.name ?? "that place"
            switch await resolveForCurrentSession(point, name: name, origin: origin) {
            case .success(let place):
                guard mine == generation else { return }
                // The one write, and only ever from here: a confirmed place.
                prefs.setResolvedPlace(place)
                finish(mine, failure: nil)
            case .failure(.superseded):
                // A newer switch owns the UI and its own failure wording. Say
                // nothing — the user is already watching the change they meant.
                return
            case .failure(let error):
                finish(mine, failure: Self.message(for: error))
            }
        }
    }

    /// Anonymous sessions only need Facebook's URL identifier. The exact
    /// coordinate the picker also writes into its cookie-backed session is
    /// intentionally skipped: it disappears with that short-lived session and
    /// costs most of the location-change latency. Account sessions retain the
    /// full picker route so their more precise ranking state is preserved.
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
    /// label reverts to `Preferences.locationName` on its own, because nothing
    /// ever wrote over it.
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

    /// Named rather than generic: each of these is a different thing going
    /// wrong, and the distinction is what makes a report useful.
    static func message(for error: MarketplacePlaceResolver.Failure) -> String {
        switch error {
        case .noPill: "Facebook's location control wasn't on the page."
        case .noArrow: "Facebook's location dialog didn't offer the current-location button."
        case .notAsked: "Facebook didn't ask for a position."
        case .unresolved: "Facebook didn't recognise that place."
        case .paced: "Too many requests just now. Try again shortly."
        // Never shown — `resolve` returns before composing a message for it —
        // but the wording is here rather than a `default`, so a future caller
        // that does surface it says something true.
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
