import SwiftUI
import CoreLocation

/// The three screens between installing the app and using it.
///
/// It replaces a first run that was three explanatory cards and a Start button.
/// Those cards were honest and completely inert: the app came out of them
/// knowing nothing, so the first thing anyone saw was a home screen searching
/// San Francisco for a shuffle of default categories. Whether that was any good
/// depended entirely on whether the user happened to live in San Francisco and
/// happened to want furniture.
///
/// So two of the three screens now ask for something, and **both are required**:
///
/// * **A place**, because every search this app runs is centred on one, and
///   without it there is a hardcoded fallback city standing in for the user's.
/// * **Three interests**, because Discover is built out of recent searches and
///   a new install has none (`docs/discover.md` §1).
///
/// Required is the whole point rather than a default that could be skipped: a
/// skip link here buys thirty seconds and costs the app any idea of what to
/// show, and the screen it skips to is the one that then can't do its job. The
/// explaining is folded into the first screen instead, where it costs one tap
/// rather than three.
struct OnboardingView: View {
    /// Called once, from the last step. Sets `hasCompletedOnboarding`, which is
    /// what actually dismisses this — see `Preferences.needsOnboarding`.
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences

    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, place, interests
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch step {
                case .welcome:
                    WelcomePage { go(to: .place) }
                        .transition(.opacity)
                case .place:
                    PlacePage { go(to: .interests) }
                        .transition(.opacity)
                case .interests:
                    InterestsPage(done: done)
                        .transition(.opacity)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    /// A back chevron and three dots.
    ///
    /// The dots are there because two of these screens ask for work, and a
    /// required question with no visible end is a different experience from the
    /// same question when you can see it's the last one.
    private var header: some View {
        HStack {
            Button {
                go(to: Step(rawValue: step.rawValue - 1) ?? .welcome)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
            }
            .opacity(step == .welcome ? 0 : 1)
            .disabled(step == .welcome)
            .accessibilityLabel("Back")
            .accessibilityHidden(step == .welcome)

            Spacer()

            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { dot in
                    Circle()
                        .fill(dot == step ? Color.primary : Color(.tertiaryLabel))
                        .frame(width: 6, height: 6)
                }
            }

            Spacer()

            // Balances the chevron so the dots sit centred.
            Image(systemName: "chevron.left").opacity(0).accessibilityHidden(true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func go(to next: Step) {
        withAnimation(.easeInOut(duration: 0.22)) { step = next }
    }
}

// MARK: - 1. What this is

/// The old first run, compressed into one screen.
///
/// It was three swipeable cards, which is three taps to read three sentences
/// that fit on one page together. The no-login promise is the one that has to
/// survive the edit — it is the first question anyone asks about an app that
/// shows Facebook listings, and the answer is genuinely yes.
private struct WelcomePage: View {
    let next: () -> Void

    private struct Promise {
        let symbol: String
        let title: String
        let body: String
    }

    private let promises = [
        Promise(symbol: "square.grid.2x2",
                title: "Local listings, fast",
                body: "A clean way to browse what's for sale near you — no feed, no clutter, no ads in the way."),
        Promise(symbol: "lock.open",
                title: "No login. Ever.",
                body: "This app browses public listings without signing in. It never asks for your Facebook password, and it can't see your account."),
        Promise(symbol: "arrow.up.forward.app",
                title: "Messaging opens Facebook",
                body: "When you want to message a seller or make an offer, we hand you to the Facebook app to finish up.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Open Market")
                    .font(.largeTitle.weight(.bold))
                Text("Marketplace, without the rest of Facebook.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            VStack(alignment: .leading, spacing: 24) {
                ForEach(promises.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: promises[index].symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(promises[index].title)
                                .font(.headline)
                            Text(promises[index].body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 40)

            Spacer(minLength: 24)

            OnboardingButton(title: "Get started", isEnabled: true, action: next)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

// MARK: - 2. Where

/// Required, and required for a reason worth stating on the screen: distance is
/// the app's organising idea, and it is applied on this device rather than by
/// Facebook (`docs/filter-parameters.md` §3). Without a place there is nothing
/// to measure from, and the app would quietly measure from a hardcoded city.
///
/// Two routes, both ending in the same place — Apple answers "where is that",
/// Facebook answers "what do you call it" (`PlaceChooser`). The device fix is
/// the primary action because it is one tap and exact; searching a city is a
/// full alternative rather than a fallback, since plenty of people want to
/// browse somewhere they aren't.
private struct PlacePage: View {
    let next: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @StateObject private var chooser = PlaceChooser()
    @State private var showCitySearch = false

    private var centre: CLLocationCoordinate2D {
        prefs.resolvedPlace?.coordinate
            ?? location.coordinate
            // The slug every search falls back to with nothing set, so with no
            // place and no fix this is honestly where searching would happen.
            ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationMapCard(place: prefs.resolvedPlace?.name ?? "no location",
                            coordinate: centre,
                            precision: prefs.resolvedPlace == nil ? .unset : .city,
                            userLocation: location.coordinate)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Where are you shopping?")
                    .font(.largeTitle.weight(.bold))
                Text("Listings are sorted and filtered by how far away they are, so the app needs somewhere to measure from. You can change it any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24)

            VStack(spacing: 10) {
                Button {
                    Task { await chooser.useDeviceLocation(via: location) }
                } label: {
                    HStack(spacing: 8) {
                        if chooser.pending == .deviceFix {
                            ProgressView().controlSize(.small).tint(.white)
                        } else {
                            Image(systemName: "location.fill")
                        }
                        Text("Use my current location")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(chooser.isBusy)

                Button { showCitySearch = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Search for a city or ZIP")
                    }
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Capsule().stroke(Color(.separator), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(chooser.isBusy)
            }
            .padding(.top, 24)

            if let place = prefs.resolvedPlace {
                Label {
                    Text("Browsing **\(place.name)**")
                } icon: {
                    Image(systemName: place.isUserLocation ? "location.fill" : "mappin.and.ellipse")
                }
                .font(.subheadline)
                .padding(.top, 18)
            }

            if let failure = chooser.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }

            Spacer(minLength: 16)

            Text("Your coordinate is sent to Facebook once, to name the place. Searches after that use the place name, not your position.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)

            OnboardingButton(title: "Continue",
                             isEnabled: prefs.resolvedPlace != nil,
                             action: next)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .locationSettingsAlert(isPresented: $chooser.needsLocationSettings)
        .sheet(isPresented: $showCitySearch) {
            CitySearchSheet(chooser: chooser)
        }
    }
}

/// City autocomplete, and nothing else.
///
/// Deliberately not `LocationPickerSheet`, which is the settings version of
/// this: it also carries the distance ladder and a "Browsing" summary, both of
/// which are answers to questions nobody has yet on their first run.
private struct CitySearchSheet: View {
    @ObservedObject var chooser: PlaceChooser
    @StateObject private var cities = AppleMapsCitySearch()
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if cities.suggestions.isEmpty {
                    Text(emptyMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                ForEach(cities.suggestions) { suggestion in
                    Button {
                        Task {
                            if await chooser.use(suggestion, from: cities) { dismiss() }
                        }
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
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "City, town or ZIP")
            .onChange(of: query) { cities.search(query) }
            .navigationTitle("Pick a place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var emptyMessage: String {
        if cities.isSearching { return "Searching…" }
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Type a city, town or ZIP code."
            : "No places found."
    }
}

// MARK: - 3. What for

/// Three interests, and they go straight into long-term storage.
///
/// This is the screen that makes the home feed possible on day one. Discover
/// runs one search per seed and interleaves the results, so what is picked here
/// is literally what the first Discover is made of — which is also why the
/// minimum is three rather than one.
///
/// The count lives in the button rather than in a separate counter line. It is
/// the same fact — how many more are needed — and putting it where the user is
/// heading means the disabled state explains itself instead of just refusing.
private struct InterestsPage: View {
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences

    /// Counts only ids this build recognises, which is what the minimum has to
    /// mean — a stored id from a retired category would otherwise let someone
    /// through with two live interests and a ghost.
    private var remaining: Int {
        max(0, Interest.minimum - Interest.resolve(prefs.interests).count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you shop for?")
                    .font(.largeTitle.weight(.bold))
                Text("Pick at least \(Interest.minimum). They fill the home screen until you've searched for a few things of your own — after that, your searches take over.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            ScrollView {
                InterestPicker(selected: $prefs.interests)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)

            OnboardingButton(title: remaining == 0 ? "Start browsing" : "Pick \(remaining) more",
                             isEnabled: remaining == 0,
                             action: done)
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

// MARK: - Shared

/// One full-width action per screen, always in the same place.
private struct OnboardingButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(isEnabled ? Color.primary : Color(.tertiarySystemFill),
                            in: Capsule())
                .foregroundStyle(isEnabled ? Color(.systemBackground) : Color(.tertiaryLabel))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}
