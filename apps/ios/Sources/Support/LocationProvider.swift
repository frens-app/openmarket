import Foundation
import CoreLocation

/// Radius pinning needs a coordinate. When-in-use, requested on first
/// search, cached afterwards — never continuous tracking (there is no
/// background activity of any kind).
@MainActor
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle, requesting, resolved(String), denied, failed
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var coordinate: CLLocationCoordinate2D?
    @Published private(set) var countryCode: String?

    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    /// Gives up on a fix that never arrives. Started when the fix is asked for
    /// — see `askForFix`.
    private var watchdog: Task<Void, Never>?
    /// How long this request is willing to wait, kept because the authorisation
    /// callback is where a first-run fix actually starts and it has no caller.
    private var pendingTimeout: Duration = .seconds(6)

    override init() {
        super.init()
        manager.delegate = self
        // A kilometre was enough when this only had to pick a city for radius
        // pinning. It isn't any more: the same fix is now the origin of a
        // per-listing distance quoted to a tenth of a mile and of a walking
        // time quoted to the minute, and a kilometre of slack is twenty minutes
        // on foot. Still a single on-demand fix, so the cost is one slightly
        // longer wait rather than any ongoing draw.
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus)
    }

    /// Never asked. A prompt here can still summon the system dialog, so it's
    /// worth offering one.
    var isUndecided: Bool { manager.authorizationStatus == .notDetermined }

    /// Asked and refused, or refused on the user's behalf by a restriction.
    /// The system dialog will not appear again, so the only honest offer is a
    /// trip to Settings.
    var isDenied: Bool {
        [.denied, .restricted].contains(manager.authorizationStatus)
    }

    /// Whether a call may summon the system permission dialog.
    ///
    /// The dialog is a once-per-install event and iOS gives it to whichever call
    /// arrives first, so asking is opt-in: only a control the user pressed *to
    /// enable location* may raise it — "Use my location" in onboarding or the
    /// location sheet, and the enable card under a listing. Everything else
    /// takes a fix if one is already authorised and quietly does without.
    enum Prompt {
        /// The caller is a deliberate tap on an enable-location control.
        case ifNeeded
        /// Use an existing authorisation or return nil. Never shows a dialog.
        case never
    }

    /// Resolves once and caches. Returns nil if the user declines, hasn't been
    /// asked, or the fix doesn't arrive — searching still works, it just falls
    /// back to the stored city slug, so this must never block indefinitely.
    func resolveOnce(timeout: Duration = .seconds(6),
                     prompt: Prompt = .never) async -> CLLocationCoordinate2D? {
        if let coordinate { return coordinate }
        return await requestFix(timeout: timeout, prompt: prompt)
    }

    /// Takes a **new** fix, ignoring the cached one.
    ///
    /// Everything else in the app deliberately reuses one fix: the search
    /// location is resolved once and held (`ResolvedPlace`), and distances are
    /// measured from that saved point so they don't drift as the user walks.
    ///
    /// Travel time is the exception, and the only one. "How long would it take
    /// me to get there" is a question about where the user is standing right
    /// now, and answering it from a fix taken when the app launched is how you
    /// get a confident twenty-minute drive that is actually five.
    func resolveFresh(timeout: Duration = .seconds(6),
                      prompt: Prompt = .never) async -> CLLocationCoordinate2D? {
        await requestFix(timeout: timeout, prompt: prompt)
    }

    private func requestFix(timeout: Duration, prompt: Prompt) async -> CLLocationCoordinate2D? {
        guard manager.authorizationStatus != .denied, manager.authorizationStatus != .restricted else {
            state = .denied
            return nil
        }
        // Undecided and not asked to ask: leave the state alone. `.idle` is
        // what the enable-location cards key off to know a dialog is still
        // available, and `.failed` here would be a lie — nothing was tried.
        if manager.authorizationStatus == .notDetermined, prompt == .never { return nil }
        guard continuation == nil else { return nil }   // a request is already in flight
        state = .requesting
        pendingTimeout = timeout

        return await withCheckedContinuation { cont in
            continuation = cont
            if manager.authorizationStatus == .notDetermined {
                // No clock yet. The permission dialog is up and however long
                // somebody takes to read it is not the location system being
                // slow — `askForFix` starts the timer once they've answered.
                manager.requestWhenInUseAuthorization()
            } else {
                askForFix()
            }
        }
    }

    /// Asks for the fix and starts the clock in the same breath. Starting it
    /// when the permission dialog appears instead means anyone who reads the
    /// dialog before tapping Allow burns the six seconds on reading, and is told
    /// "Couldn't get a location fix" as the fix arrives.
    private func askForFix() {
        manager.requestLocation()
        // The authorisation callback also fires at launch for an app that was
        // already granted permission, which is where the cached coordinate
        // comes from before anyone asks for one. Nobody is waiting on that, so
        // it needs no clock.
        guard continuation != nil else { return }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: self?.pendingTimeout ?? .seconds(6))
            guard !Task.isCancelled, let self, let pending = self.continuation else { return }
            self.continuation = nil
            if self.state == .requesting { self.state = .failed }
            pending.resume(returning: nil)
        }
    }

    private func finish(_ coord: CLLocationCoordinate2D?) {
        watchdog?.cancel()
        watchdog = nil
        continuation?.resume(returning: coord)
        continuation = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            // Granted just now, which on a first run is where the fix — and
            // therefore its timeout — actually begins.
            case .authorizedWhenInUse, .authorizedAlways: askForFix()
            case .denied, .restricted: state = .denied; finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            coordinate = loc.coordinate
            await reverseGeocode(loc)
            finish(loc.coordinate)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            state = .failed
            finish(nil)
        }
    }

    private func reverseGeocode(_ location: CLLocation) async {
        let places = try? await CLGeocoder().reverseGeocodeLocation(location)
        guard let place = places?.first else {
            countryCode = nil
            state = .resolved("Your area")
            return
        }
        countryCode = place.isoCountryCode?.uppercased()
        guard let city = place.locality else {
            state = .resolved("Your area")
            return
        }
        let name = [city, place.administrativeArea].compactMap { $0 }.joined(separator: ", ")
        state = .resolved(name)
        // Deliberately writes **no slug** — a display name only. Deriving one
        // here is the guessing that doesn't work ("Daly City" → `dalycity` is
        // not a place Facebook knows, and the search silently runs against the
        // IP-inferred city), and it would fire on every fix, overwriting
        // whichever city the user chose. Targeting is
        // `MarketplacePlaceResolver`'s job and nothing else's.
    }
}
