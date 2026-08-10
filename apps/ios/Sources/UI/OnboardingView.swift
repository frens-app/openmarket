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
/// So two of the four screens ask for something, and **both are required**:
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
///
/// The fourth screen asks for a Facebook account, and that one *is* skippable —
/// it is the only thing here the app can do a reduced version of without. It is
/// asked for anyway, and asked for first-class, because the app is measurably
/// better with it: seller identity, results that keep loading past the first
/// page, and Facebook's own feed instead of three canned searches
/// (`docs/logged-in-findings.md`). Logged out is the fallback, not the pitch.
struct OnboardingView: View {
    /// Called once, from the last step. Sets `hasCompletedOnboarding`, which is
    /// what actually dismisses this — see `Preferences.needsOnboarding`.
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var chooser: PlaceChooser

    @State private var step: Step = .welcome

    private enum Step: Int, CaseIterable {
        case welcome, place, interests, account
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
                    InterestsPage { go(to: .account) }
                        .transition(.opacity)
                case .account:
                    AccountPage(done: finish)
                        .transition(.opacity)
                }
            }
        }
        .background(Color(.systemBackground))
    }

    /// A back chevron and a dot per screen.
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

    /// The one place in the app that waits for a location to be agreed.
    ///
    /// Everything the place step does is optimistic, which is what keeps a
    /// first run moving — but the screen on the other side of this button is a
    /// home feed, and there is no version of it that works without a place
    /// Facebook recognises. So this is where the two meet: by now the user has
    /// spent the resolution's ten seconds choosing interests and deciding about
    /// an account, so `settle` almost always returns immediately, and the rare
    /// wait replaces a guaranteed one.
    ///
    /// A place that never landed sends them back to the step that asks for it,
    /// where the failure is already on screen — rather than through to a home
    /// screen that would bounce them here anyway (`Preferences.needsOnboarding`
    /// re-checks the place on every launch, so letting this through would show
    /// onboarding again on the next start).
    private func finish() async {
        await chooser.settle()
        guard prefs.resolvedPlace != nil else {
            go(to: .place)
            return
        }
        done()
    }
}

// MARK: - 1. What this is

/// The old first run, compressed into one screen.
///
/// It was three swipeable cards, which is three taps to read three sentences
/// that fit on one page together. What survives the edit is what the app is for
/// and how it connects to Facebook — including, plainly, that it works best
/// with the user's own account, which the fourth screen then asks for.
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
        Promise(symbol: "person.crop.circle.badge.checkmark",
                title: "Best with your Facebook account",
                body: "Sign in and you get seller names and ratings, results that keep loading past the first page, and a home screen built from Facebook's own picks."),
        Promise(symbol: "arrow.up.forward.app",
                title: "Messaging opens Facebook",
                body: "When you want to message a seller or make an offer, we hand you to the Facebook app to finish up — already signed in, if you are.")
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

    /// Continue opens on the *choice*, not on the confirmation.
    ///
    /// This is the whole of "onboarding isn't blocking": the ten-second round
    /// trip runs while the user reads the next screen and picks interests,
    /// instead of holding them on a spinner here. The guarantee that nobody
    /// reaches a home screen without a real place moves to the last step
    /// (`OnboardingView.finish`), where it costs nothing in the normal case.
    private var canContinue: Bool {
        prefs.resolvedPlace != nil || chooser.switching != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LocationMapCard(place: mapPlace ?? "no location",
                            coordinate: centre,
                            precision: mapPlace == nil ? .unset : .city,
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
                // "Setting up", not "Browsing". On a first run the distinction
                // is quieter than it is later — there are no results on screen
                // to be wrong about — but the wording still shouldn't claim a
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

            Text("Facebook names the place from your coordinate, and every search runs against that place — same as Marketplace itself.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)

            OnboardingButton(title: "Continue",
                             isEnabled: canContinue,
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
    let next: () -> Void

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

            OnboardingButton(title: remaining == 0 ? "Continue" : "Pick \(remaining) more",
                             isEnabled: remaining == 0,
                             action: next)
                .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }
}

// MARK: - 4. Who

/// The account step: asked for properly, and the only step that can be passed.
///
/// Everything measured about a signed-in session says this is the version of
/// the app worth having (`docs/logged-in-findings.md`): a stable seller id, so
/// a listing can be attributed rather than shrugged at; results that keep
/// loading instead of stopping at the first batch; and a Discover made of
/// Facebook's own picks rather than three searches derived from the previous
/// screen. Handing off to message a seller lands in an app that already knows
/// who you are.
///
/// So the primary action here is signing in, and "not now" is a text button
/// underneath it — with the reduced version described honestly next to it,
/// because someone declining should know what they are getting rather than
/// discovering it as a series of small absences later. The reduced version is
/// genuinely usable, which is the reason this step isn't a gate like the other
/// two: nothing on the home screen is broken without an account, it is just
/// thinner. Both routes run `done`, and the app can be signed into afterwards
/// from Settings or from any of the prompts that point at what's missing.
private struct AccountPage: View {
    /// Async for the same reason the interests step used to be: the place
    /// chosen two screens ago may still be resolving — see
    /// `OnboardingView.finish`.
    let done: () async -> Void

    /// The session is the store's cache key, and signing in here happens while
    /// the app is already foregrounded — so the scene-phase re-check in
    /// `OpenMarketApp` won't fire before the first search runs.
    @EnvironmentObject private var store: ListingStore

    @State private var showSignIn = false
    @State private var isSignedIn = false
    @State private var isFinishing = false

    private struct Perk {
        let symbol: String
        let title: String
        let body: String
    }

    private let perks = [
        Perk(symbol: "person.text.rectangle",
             title: "Know who you're buying from",
             body: "Seller name, rating and how long they've been on Facebook — none of which a signed-out page carries."),
        Perk(symbol: "arrow.down.circle",
             title: "Results that keep going",
             body: "Signed out, a search stops after the first couple of dozen listings. Signed in, it keeps loading as you scroll."),
        Perk(symbol: "sparkles",
             title: "A home screen from Facebook",
             body: "Discover shows Marketplace's own picks for your area instead of standing in with your interests.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(isSignedIn ? "You're signed in" : "Sign in to Facebook")
                    .font(.largeTitle.weight(.bold))
                Text(isSignedIn
                     ? "Seller details, unlimited scrolling and Facebook's own picks are all switched on."
                     : "Open Market works best with your account. You'll sign in on Facebook's own page — this app has no login form of its own.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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

            Spacer(minLength: 24)

            if isSignedIn {
                OnboardingButton(title: "Start browsing",
                                 isEnabled: !isFinishing,
                                 isBusy: isFinishing,
                                 action: finish)
            } else {
                OnboardingButton(title: "Sign in with Facebook",
                                 isEnabled: !isFinishing) { showSignIn = true }

                Button(action: finish) {
                    Text("Not now — browse without an account")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .disabled(isFinishing)

                // The honest shape of the logged-out app, said once and here
                // rather than left to be inferred from what doesn't appear.
                Text("Searching, distances, filters and saved listings all work without signing in. You can sign in later from Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .task { isSignedIn = await SessionState.isSignedIn() }
        .sheet(isPresented: $showSignIn) {
            SignInView {
                Task {
                    isSignedIn = true
                    store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                }
            }
        }
    }

    private func finish() {
        Task {
            isFinishing = true
            await done()
            isFinishing = false
        }
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
