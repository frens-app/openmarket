import Foundation
import CoreLocation

/// Turning "here" or "that city" into a place Facebook recognises.
///
/// Both routes end in the same three steps — get a coordinate, hand it to
/// Facebook's own picker, store what Facebook calls the result — and there are
/// now two screens that need them: the location sheet, and the location step of
/// onboarding. This holds the in-flight state and the failure wording so the
/// two can't drift apart; each screen keeps its own `AppleMapsCitySearch`,
/// which is view state and doesn't survive nesting inside another
/// `ObservableObject` anyway.
@MainActor
final class PlaceChooser: ObservableObject {
    /// What is being waited on, so the right row shows the spinner.
    enum Pending: Equatable {
        case deviceFix
        case city(String)
    }

    @Published private(set) var pending: Pending?
    @Published private(set) var failure: String?

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

    var isBusy: Bool { pending != nil }

    private let prefs: Preferences

    init(prefs: Preferences = .shared) {
        self.prefs = prefs
    }

    /// The device's own fix. Returns whether a place was stored, so a caller
    /// that wants to move on can.
    ///
    /// Both callers are a tap on "Use my location", which is the whole reason
    /// this is one of the few places allowed to raise the permission dialog.
    @discardableResult
    func useDeviceLocation(via location: LocationProvider) async -> Bool {
        failure = nil
        pending = .deviceFix
        defer { pending = nil }
        guard let coordinate = await location.resolveOnce(prompt: .ifNeeded) else {
            if location.isDenied {
                needsLocationSettings = true
            } else {
                failure = "Couldn't get a location fix. Try again, or search for a city instead."
            }
            return false
        }
        return await apply(coordinate, origin: .deviceFix)
    }

    @discardableResult
    func use(_ suggestion: AppleMapsCitySearch.Suggestion,
             from cities: AppleMapsCitySearch) async -> Bool {
        failure = nil
        pending = .city(suggestion.display)
        defer { pending = nil }
        guard let coordinate = await cities.coordinate(for: suggestion) else {
            failure = "Couldn't place \(suggestion.title) on the map."
            return false
        }
        return await apply(coordinate, origin: .searchedCity)
    }

    private func apply(_ coordinate: CLLocationCoordinate2D,
                       origin: ResolvedPlace.Origin) async -> Bool {
        let resolver = MarketplacePlaceResolver()
        switch await resolver.resolve(coordinate, origin: origin) {
        case .success(let place):
            prefs.setResolvedPlace(place)
            return true
        case .failure(let error):
            failure = Self.message(for: error)
            return false
        }
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
        case .notConfirmed(let shown):
            if let shown {
                "Facebook set the location but then served \(shown) instead. Not saved."
            } else {
                "Couldn't confirm the location took effect. Not saved."
            }
        }
    }
}
