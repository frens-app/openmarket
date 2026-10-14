import SwiftUI
import CoreLocation

struct OnboardingView: View {
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var chooser: PlaceChooser
    @EnvironmentObject private var account: AccountSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFinishing = false
    @State private var hasStarted = false
    @State private var current: Step = .account

    enum Step: Int, CaseIterable {
        case account, location, facebook

        var analyticsName: String {
            switch self {
            case .account: return "account"
            case .location: return "location"
            case .facebook: return "facebook"
            }
        }

        func next() -> Step? {
            switch self {
            case .account: return .location
            case .location: return .facebook
            case .facebook: return nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if current != .account { header }
            ZStack {
                switch current {
                case .account:
                    AccountLoginView(onSkip: { advance(from: .account) }) { _ in
                        guard current == .account else { return }
                        advance(from: .account)
                    }
                    .transition(.opacity)
                case .location:
                    LocationPage { advance(from: .location) }
                        .transition(.opacity)
                case .facebook:
                    FacebookPage(isFinishing: isFinishing) { advance(from: .facebook) }
                        .transition(.opacity)
                }
            }
        }
        .background(Color(.systemBackground))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: current)
        .task {
            guard !hasStarted else { return }
            hasStarted = true
            if account.isSignedIn { current = .location }
        }
    }

    private func advance(from step: Step) {
        guard current == step, !isFinishing else { return }
        Analytics.capture(.onboardingStepCompleted, [
            "step": step.analyticsName,
            "step_index": step.rawValue + 1
        ])
        isFinishing = true
        Task {
            guard !Task.isCancelled else { return }
            if let next = step.next() {
                current = next
                isFinishing = false
            } else {
                await finish()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { dot in
                Capsule()
                    .fill(dot == current ? Color.primary : Color(.tertiaryLabel))
                    .frame(width: dot == current ? 18 : 6, height: 6)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(Step.allCases.count)")
    }

    private func finish() async {
        await chooser.settle()
        isFinishing = false
        guard prefs.hasBrowseablePlace else {
            current = .location
            return
        }
        done()
    }
}

// MARK: - 2. Facebook

private struct FacebookPage: View {
    let isFinishing: Bool
    let done: () -> Void

    /// The session is the store's cache key, and signing in here happens while
    /// the app is already foregrounded — so the scene-phase re-check in
    /// `OpenMarketApp` won't fire before the first search runs.
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var account: AccountSession

    @State private var showSignIn = false
    @State private var isSignedIn = false

    private struct Perk {
        let symbol: String
        let title: String
        let body: String
    }

    /// Benefits stated as benefits, never as what you lose by declining — the
    /// comparison only lands for someone who already knows what the reduced
    /// version looks like, and nobody on their first run does.
    private let perks = [
        Perk(symbol: "person.text.rectangle",
             title: "Know who you're buying from",
             body: "Seller names, ratings, and how long they've been on Facebook."),
        Perk(symbol: "arrow.down.circle",
             title: "Results that keep going",
             body: "Listings keep loading for as long as you keep scrolling."),
        Perk(symbol: "sparkles",
             title: "Personalized results",
             body: "Marketplace ranks listings against your own account, so what comes back is picked for you.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isSignedIn ? "You're connected" : "Connect Facebook")
                            .font(.largeTitle.weight(.bold))
                        Text(isSignedIn
                             ? "Seller details, unlimited scrolling and Facebook's own picks are all switched on."
                             : "Connect for more listings and seller details. You'll sign in on Facebook's own page, or you can browse without connecting.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(perks.indices, id: \.self) { index in
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: perks[index].symbol)
                                    .font(.title2)
                                    .foregroundStyle(isSignedIn ? Color.green : Color.accentColor)
                                    .frame(width: 30)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(perks[index].title)
                                        .font(.headline)
                                    Text(perks[index].body)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            if isSignedIn {
                OnboardingButton(title: "Start browsing", isEnabled: !isFinishing,
                                 isBusy: isFinishing, action: done)
            } else {
                OnboardingButton(title: "Connect Facebook", isEnabled: !isFinishing) {
                    showSignIn = true
                }

                Button(action: decline) {
                    Text("Browse without Facebook")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isFinishing)
                if isFinishing { ProgressView("Preparing your marketplace…") }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .task { isSignedIn = await SessionState.isSignedIn() }
        .sheet(isPresented: $showSignIn) {
            SignInView(surface: .onboarding) {
                Task {
                    let connected = await SessionState.isSignedIn()
                    isSignedIn = connected
                    store.setSession(connected ? .authed : .unauthed)
                    // Signing in doesn't change the scene phase, so without this
                    // the server's picture of the connection would wait for the
                    // next foreground.
                    await account.reportFacebookConnection(connected)
                }
            }
        }
    }

    private func decline() {
        Analytics.capture(.facebookConnectDeclined, ["surface": Analytics.Surface.onboarding.rawValue])
        done()
    }
}

// MARK: - 1. Location

private struct LocationPage: View {
    let next: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var location: LocationProvider
    @EnvironmentObject private var chooser: PlaceChooser
    @State private var showCitySearch = false

    /// The place being switched to comes first, so the map moves the moment
    /// there is somewhere to move to rather than ten seconds later.
    private var centre: CLLocationCoordinate2D {
        chooser.switching?.coordinate
            ?? prefs.resolvedPlace?.coordinate
            ?? location.coordinate
            // The slug every search falls back to with nothing set, so with no
            // place and no fix this is honestly where searching would happen.
            ?? CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
    }

    /// What the card is naming: the pending choice, then the confirmed one.
    private var mapPlace: String? {
        chooser.switching?.name ?? prefs.resolvedPlace?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationMapCard(place: mapPlace ?? "no location",
                            coordinate: centre,
                            precision: mapPlace == nil ? .unset : .city,
                            userLocation: location.coordinate)
                .padding(.top, 8)

            Text("Where are you shopping?")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 24)

            // Neither button is disabled while a switch runs. The point of not
            // blocking is that the screen stays usable, and the most likely
            // reason to touch it again is having picked the wrong Berkeley —
            // a second choice supersedes the first (`PlaceChooser.resolve`).
            VStack(spacing: 10) {
                Button {
                    Task { await chooser.switchToDeviceLocation(via: location) }
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
            }
            .padding(.top, 24)

            if let change = chooser.switching {
                // "Setting up", not "Browsing". The wording shouldn't claim a
                // place Facebook hasn't agreed to.
                Label {
                    Text("Setting up **\(change.name)**")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.subheadline)
                .padding(.top, 18)
            } else if let place = prefs.resolvedPlace {
                Label {
                    Text("Browsing **\(place.name)**")
                } icon: {
                    Image(systemName: place.isUserLocation ? "location.fill" : "mappin.and.ellipse")
                }
                .font(.subheadline)
                .padding(.top, 18)
            }

            if let failure = chooser.failure {
                Label(failure.summary, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 14)
            }

            Spacer(minLength: 16)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .onChange(of: prefs.resolvedPlace) { _, _ in
            guard prefs.hasBrowseablePlace else { return }
            next()
        }
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
                        // Dismisses on the tap, unlike the settings picker,
                        // which stays open to show the change landing. There is
                        // nothing on this sheet but the list — the page behind
                        // is what has the map and the readout, so getting out
                        // of its way *is* showing the result.
                        chooser.switchTo(suggestion, from: cities)
                        dismiss()
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

// MARK: - Shared

/// One full-width action per screen, always in the same place.
private struct OnboardingButton: View {
    let title: String
    let isEnabled: Bool
    /// Waiting on something the tap started, with the label kept in place so
    /// the button doesn't change size or meaning underneath the thumb.
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Text(title).opacity(isBusy ? 0 : 1)
                if isBusy { ProgressView().controlSize(.small) }
            }
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
