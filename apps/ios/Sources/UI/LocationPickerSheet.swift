import SwiftUI
import MapKit
import CoreLocation

/// Choose where to browse: here, or anywhere.
///
/// Replaces a hand-curated list of seven cities, which was never really a
/// feature — it was a workaround for the app having to guess slugs, and it
/// guessed wrong for five of the twelve it originally shipped.
///
/// Both routes end in the same place: Apple supplies a coordinate and display
/// name, and Facebook supplies the URL segment. Account sessions go through its
/// picker; anonymous sessions ask the picker's URL resolver directly. The slug
/// is valid in either case because Facebook produced it.
struct LocationPickerSheet: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @StateObject private var cities = AppleMapsCitySearch()
    /// The two-step resolution and its failure wording, shared with the
    /// location step of onboarding so the two screens can't drift apart.
    ///
    /// From the environment rather than owned here: this sheet now dismisses on
    /// the tap and the switch carries on without it, so the state has to belong
    /// to something that outlives the screen.
    @EnvironmentObject private var chooser: PlaceChooser
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    /// Whether the search field has the screen. Bound rather than left to
    /// itself so that picking a city can put it away — the answer to the search
    /// is on the screen behind it.
    @State private var isSearchActive = false

    /// Typing takes the screen over. As a third section below the map and the
    /// distance pills, results for what you just typed land off the bottom of
    /// the screen — a search field whose results aren't where you are looking.
    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    suggestionSection
                } else {
                    currentSection
                    distanceSection
                }
                if let failure = chooser.failure { failureSection(failure) }
            }
            .searchable(text: $query, isPresented: $isSearchActive,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a city")
            .onChange(of: query) { cities.search(query) }
            .navigationTitle("Location")
            .navigationBarTitleDisplayMode(.inline)
            .locationSettingsAlert(isPresented: $chooser.needsLocationSettings)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    /// What the map centres on, in order of how much it actually tells you.
    ///
    /// The chosen place first. Failing that the device's own fix, which is the
    /// most useful thing to look at while deciding — "Use my current location"
    /// is right underneath, and the map is showing what it would pick.
    ///
    /// Last, San Francisco. Not arbitrary: `sanfrancisco` is the slug every
    /// search falls back to with nothing set (`ResultsView.makeQuery`,
    /// `SellerToolsModel.run`), so with no place and no fix, this is honestly
    /// where searching would happen right now.
    /// The place being switched to comes first: while a change is in flight it
    /// is what the screen is about, and seeing it on the map is how "Berkeley,
    /// CA" is told apart from "Berkeley, NJ" before any resolution is spent on
    /// the wrong one.
    private var mapCentre: CLLocationCoordinate2D {
        chooser.switching?.coordinate
            ?? prefs.resolvedPlace?.coordinate
            ?? location.coordinate
            ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    }

    /// What the map is showing: the target of a change in flight, then the
    /// confirmed place, then nothing chosen yet.
    private var mapPlace: String? {
        chooser.switching?.name ?? prefs.resolvedPlace?.name
    }

    @ViewBuilder
    private var currentSection: some View {
        Section {
            // Always drawn, chosen place or not: the map is most useful
            // *before* the decision, when it shows what "here" would mean. With
            // nothing set it makes no claim — no circle — and simply orients.
            LocationMapCard(place: mapPlace ?? "no location",
                            coordinate: mapCentre,
                            precision: mapPlace == nil ? .unset : .city,
                            userLocation: location.coordinate)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if let change = chooser.switching {
                // A change picked but not yet agreed. Said as a change rather
                // than a fact — the results are still the old city's until
                // Facebook confirms, and this screen shouldn't be the one place
                // in the app that implies otherwise.
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Switching to \(change.name)…")
                        .font(.subheadline.weight(.semibold))
                }
            } else if let place = prefs.resolvedPlace {
                // Just the name. No URL segment (an implementation detail) and
                // no "confirmed on Facebook" badge — an unconfirmed place is
                // never stored, so it would state an invariant, not a fact.
                HStack {
                    Image(systemName: place.isUserLocation ? "location.fill" : "mappin.and.ellipse")
                        .foregroundStyle(.tint)
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
                }
            }

            // Deliberately **not** disabled while a switch is in flight.
            //
            // The sheet closes on the tap now, so "busy" is a state the user
            // can walk back into — and the only reason to reopen this screen
            // mid-switch is to correct the thing they just picked. Making them
            // wait for fallback resolution to fix a mistyped city would be a
            // strange way to spend the responsiveness this was all for. A
            // second choice supersedes the first (`PlaceChooser.resolve`).
            Button {
                Task { await useDeviceLocation() }
            } label: {
                HStack {
                    Label("Use my current location", systemImage: "location")
                    Spacer()
                    if chooser.pending == .deviceFix { ProgressView().controlSize(.small) }
                }
            }
        } header: {
            Text(prefs.resolvedPlace == nil ? "Location" : "Browsing")
        } footer: {
            Text("Your coordinate is sent to Facebook once, to name the place. "
                 + "Searches after that use the place name, not your position.")
        }
    }

    /// Distance lives here rather than in the filter sheet.
    ///
    /// "San Francisco · 10 mi" is one thought — where, and how far — and the
    /// bar states it as one readout, so the control that changes it should be
    /// one screen too. Splitting them meant tapping the location pill to change
    /// the place, then a different sheet to change the radius, for a phrase the
    /// user reads as a single fact.
    private var distanceSection: some View {
        Section {
            WrapLayout(spacing: 8) {
                ForEach(distanceOptions, id: \.self) { km in
                    distancePill("\(SearchQuery.kilometresToMiles(km)) mi", isOn: prefs.radiusKM == km) {
                        setRadius(km)
                    }
                }
                distancePill("Any", isOn: prefs.radiusKM == 0) { setRadius(0) }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Distance")
        } footer: {
            // Worth repeating here: this one is ours, and it is the reason a
            // result set can look emptier than the place suggests.
            Text("Applied on this device — Facebook ignores distance in a search.")
        }
    }

    /// The standard rungs, plus wherever the user actually is.
    ///
    /// "Try 15 mi" on the results screen sets a radius the ladder doesn't
    /// contain, and a picker that couldn't show it would present every pill
    /// unselected — reading as "no distance set" for a search that is very
    /// much filtered. Inserting the current value keeps the control honest,
    /// and it disappears again the moment a rung is chosen.
    private var distanceOptions: [Int] {
        let options = Preferences.radiusOptions
        guard prefs.radiusKM > 0, !options.contains(prefs.radiusKM) else { return options }
        return (options + [prefs.radiusKM]).sorted()
    }

    /// Per tap, unlike the filter sheet: each pill is a complete decision
    /// applied immediately, and the sequence is the point — widening twice in a
    /// row is somebody finding nothing nearby. The previous value gives it a
    /// direction; "32 from 16" says something "32" doesn't.
    private func setRadius(_ km: Int) {
        guard km != prefs.radiusKM else { return }
        let previous = prefs.radiusKM
        prefs.radiusKM = km
        Analytics.capture(.distanceChanged, [
            "radius_km": km,
            "previous_radius_km": previous,
            // `0` is "Any" — the absence of a radius, not a zero-mile one.
            "is_unlimited": km == 0
        ])
    }

    private func distancePill(_ text: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Capsule().fill(isOn ? Color.accentColor : Color(.secondarySystemBackground)))
                .foregroundStyle(isOn ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var suggestionSection: some View {
        Section("Cities") {
            // Now that this is the only thing on screen while typing, it has to
            // account for having nothing to show — an empty section would read
            // as the field being broken.
            if cities.suggestions.isEmpty {
                Text(cities.isSearching ? "Searching…" : "No places found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ForEach(cities.suggestions) { suggestion in
                Button {
                    use(suggestion)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if chooser.pending == .city(suggestion.display) {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            }
        }
    }

    /// Both halves, unlike the bar on the results screen, which leads with the
    /// headline. This is the screen the user is on *because* they are changing
    /// location, so the specific reason is worth the second line — "Facebook
    /// didn't recognise that place" and "too many requests just now" call for
    /// different next moves.
    private func failureSection(_ failure: PlaceChooser.Failed) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(failure.summary)
                    if failure.hasDetail {
                        Text(failure.reason).foregroundStyle(.tertiary)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resolution

    /// Both routes live in `PlaceChooser`. What's left here is what the *sheet*
    /// does about a choice, and the answer is: shows it.
    ///
    /// **Nothing here dismisses.** Choosing a place is the reason this screen
    /// is open, and closing it on the tap takes the screen away at the exact
    /// moment it has something to say — the new target, on the map, with the
    /// change still running. It also makes the choice feel final in a way it
    /// isn't yet, and leaves nowhere to correct a mistyped city from. The
    /// optimism is that resolution no longer *holds* the sheet, not that the
    /// sheet goes away; Done still means done, whenever the user says so.
    private func useDeviceLocation() async {
        await chooser.switchToDeviceLocation(via: location)
    }

    /// Puts the search away, since what was searched for is now the subject of
    /// the screen behind it.
    private func use(_ suggestion: AppleMapsCitySearch.Suggestion) {
        chooser.switchTo(suggestion, from: cities)
        query = ""
        cities.clear()
        isSearchActive = false
    }
}
