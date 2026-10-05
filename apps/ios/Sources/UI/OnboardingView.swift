import SwiftUI
import CoreLocation

struct OnboardingView: View {
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var chooser: PlaceChooser
    @EnvironmentObject private var account: AccountSession
    @StateObject private var push = PushRegistrar.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFinishing = false
    @State private var hasStarted = false
    @State private var current: Step = .phone

    enum Step: Int, CaseIterable {
        case phone, location, facebook, notifications

        var analyticsName: String {
            switch self {
            case .phone: return "phone"
            case .location: return "location"
            case .facebook: return "facebook"
            case .notifications: return "notifications"
            }
        }

        func next(hasAccount: Bool, needsNotificationPermission: Bool) -> Step? {
            switch self {
            case .phone: return .location
            case .location: return .facebook
            case .facebook:
                return hasAccount && needsNotificationPermission ? .notifications : nil
            case .notifications: return nil
            }
        }
    }

    private var visibleSteps: [Step] {
        Step.allCases.filter {
            $0 != .notifications || (account.isSignedIn && push.status == .notDetermined)
                || current == .notifications
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch current {
                case .phone:
                    VStack(spacing: 0) {
                        PhoneLoginView(prompt: "Create an account to save your price checks. You can also browse without one.") { _ in
                            guard current == .phone else { return }
                            Task { await account.reportFacebookConnection(await SessionState.isSignedIn()) }
                            advance(from: .phone)
                        }
                        Button("Not now — browse without an account") { advance(from: .phone) }
                            .font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .padding(.horizontal, 24)
                    }
                    .transition(.opacity)
                case .location:
                    LocationPage { advance(from: .location) }
                        .transition(.opacity)
                case .facebook:
                    FacebookPage(isFinishing: isFinishing,
                                 continueTitle: account.isSignedIn && push.status == .notDetermined
                                     ? "Continue" : "Start browsing") { advance(from: .facebook) }
                        .transition(.opacity)
                case .notifications:
                    NotificationsPage(isFinishing: isFinishing) { advance(from: .notifications) }
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
            await push.refreshStatus()
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
            if step == .facebook {
                await push.refreshStatus()
                if account.isSignedIn { push.registerIfAuthorized() }
            }
            guard !Task.isCancelled else { return }
            if let next = step.next(hasAccount: account.isSignedIn,
                                    needsNotificationPermission: push.status == .notDetermined) {
                current = next
                isFinishing = false
            } else {
                await finish()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(visibleSteps, id: \.rawValue) { dot in
                Capsule()
                    .fill(dot == current ? Color.primary : Color(.tertiaryLabel))
                    .frame(width: dot == current ? 18 : 6, height: 6)
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityLabel("Step \((visibleSteps.firstIndex(of: current) ?? 0) + 1) of \(visibleSteps.count)")
    }

    private func finish() async {
        // A place can still be resolving while the optional steps are visible.
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
    let continueTitle: String
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
                OnboardingButton(title: continueTitle, isEnabled: !isFinishing,
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

/// Required, and required for a reason worth stating on the screen: distance is
/// the app's organising idea, and it is applied on this device
/// (`docs/filter-parameters.md` §3). Without a place there is nothing to measure
/// from, and the app would quietly measure from a hardcoded city.
///
/// Two routes, both ending in the same place — Apple answers "where is that",
/// Facebook answers "what do you call it" (`PlaceChooser`). The device fix is
/// the primary action because it is one tap and exact; searching a city is a
/// full alternative rather than a fallback, since plenty of people want to
/// browse somewhere they aren't.
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

    /// Continue opens on the *choice*, not on the confirmation — the round trip
    /// finishes while the user reads the next screen.
    private var canContinue: Bool {
        prefs.hasBrowseablePlace || chooser.switching != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationMapCard(place: mapPlace ?? "no location",
                            coordinate: centre,
                            precision: mapPlace == nil ? .unset : .searchCenter,
                            userLocation: location.coordinate)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 8) {
                Text("Where are you shopping?")
                    .font(.largeTitle.weight(.bold))
                Text("Listings are sorted and filtered by how far away they are, so the app needs somewhere to measure from. You can change it any time.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

            Text("Your selected location is sent to Facebook to find nearby listings. It stays fixed until you choose another location.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)

            OnboardingButton(title: "Continue", isEnabled: canContinue, action: next)
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

private struct NotificationsPage: View {
    let isFinishing: Bool
    let done: () -> Void

    @StateObject private var push = PushRegistrar.shared
    @State private var isAsking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                        .padding(.bottom, 12)
                    Text("Enable notifications")
                        .font(.largeTitle.weight(.bold))
                    Text("Allow notifications from Openmarket. You can change this anytime in Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 32)
            }
            .scrollBounceBehavior(.basedOnSize)

            OnboardingButton(title: "Turn on notifications", isEnabled: !isAsking && !isFinishing,
                             isBusy: isAsking || isFinishing) {
                isAsking = true
                Task {
                    await push.requestAuthorization()
                    isAsking = false
                    done()
                }
            }
            Button("Not now", action: done)
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .disabled(isAsking || isFinishing)
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
