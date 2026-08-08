import SwiftUI
import MapKit
import CoreLocation

/// Choose where to browse: here, or anywhere.
///
/// Replaces a hand-curated list of seven cities, which was never really a
/// feature — it was a workaround for the app having to guess slugs, and it
/// guessed wrong for five of the twelve it originally shipped.
///
/// Both routes end in the same place: a coordinate is handed to Facebook's own
/// picker and Facebook names the place (`MarketplacePlaceResolver`). Apple
/// answers "where is what the user typed", Facebook answers "what do you call
/// that", and the slug is valid because Facebook produced it.
struct LocationPickerSheet: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @StateObject private var cities = AppleMapsCitySearch()
    /// The two-step resolution and its failure wording, shared with the
    /// location step of onboarding so the two screens can't drift apart.
    @StateObject private var chooser = PlaceChooser()
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""

    /// Typing takes the screen over.
    ///
    /// The suggestions used to be a third section, below the map and the
    /// distance pills — so results for what you had just typed appeared off the
    /// bottom of the screen and had to be scrolled to. A search field whose
    /// results aren't where you are looking isn't a search field.
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
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
    private var mapCentre: CLLocationCoordinate2D {
        prefs.resolvedPlace?.coordinate
            ?? location.coordinate
            ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    }

    @ViewBuilder
    private var currentSection: some View {
        Section {
            // Always drawn, chosen place or not.
            //
            // The screen used to be a bare button until something had been
            // picked, which is backwards: the map is most useful *before* the
            // decision, when it can show where you are and therefore what
            // "here" would mean. With nothing set it makes no claim — no
            // circle — and simply orients.
            LocationMapCard(place: prefs.resolvedPlace?.name ?? "no location",
                            coordinate: mapCentre,
                            precision: prefs.resolvedPlace == nil ? .unset : .city,
                            userLocation: location.coordinate)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

            if let place = prefs.resolvedPlace {
                // Just the name.
                //
                // This used to also print the URL segment and a "confirmed on
                // Facebook" badge. Both were really notes to ourselves: the
                // segment is an implementation detail, and the badge reassured
                // the reader about something that is now an invariant — an
                // unconfirmed place is never stored at all, so anything on this
                // screen has already been checked. Saying so added a line
                // without adding a fact.
                HStack {
                    Image(systemName: place.isUserLocation ? "location.fill" : "mappin.and.ellipse")
                        .foregroundStyle(.tint)
                    Text(place.name)
                        .font(.subheadline.weight(.semibold))
                }
            }

            Button {
                Task { await useDeviceLocation() }
            } label: {
                HStack {
                    Label("Use my current location", systemImage: "location")
                    Spacer()
                    if chooser.pending == .deviceFix { ProgressView().controlSize(.small) }
                }
            }
            .disabled(chooser.isBusy)
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
                        prefs.radiusKM = km
                    }
                }
                distancePill("Any", isOn: prefs.radiusKM == 0) { prefs.radiusKM = 0 }
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
                    Task { await use(suggestion) }
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
                .disabled(chooser.isBusy)
            }
        }
    }

    private func failureSection(_ message: String) -> some View {
        Section {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Resolution

    /// Both routes live in `PlaceChooser`; what's left here is what the *sheet*
    /// does about a success — put the search field away, since the list behind
    /// it is now showing the place that was just chosen.
    private func useDeviceLocation() async {
        await chooser.useDeviceLocation(via: location)
    }

    private func use(_ suggestion: AppleMapsCitySearch.Suggestion) async {
        guard await chooser.use(suggestion, from: cities) else { return }
        query = ""
        cities.clear()
    }
}
