import SwiftUI
import CoreLocation

/// Everything between opening the app for the first time and using it.
///
/// Four steps, in the order the app needs the answers rather than the order
/// they're easiest to ask:
///
/// 1. **Phone** — required. The account is the app; there is no signed-out
///    version of a product whose listings belong to accounts. This used to be a
///    separate gate *outside* onboarding, which meant a first run was a login
///    screen followed by a flow that started over with "welcome". It is the
///    first step of one flow now.
/// 2. **Facebook** — skippable, and pressed anyway. Everything measured about a
///    signed-in session says it is the version worth having
///    (`docs/logged-in-findings.md`), and the reduced version is described
///    honestly next to the decline so nobody discovers it as a series of small
///    absences later.
/// 3. **Location** — required. Every search is centred on a place and distance
///    is applied on this device (`docs/filter-parameters.md` §3), so without one
///    the app measures from a hardcoded city and pretends that's the user's.
/// 4. **Notifications** — skippable, asked for price alerts specifically. A
///    permission prompt with no stated purpose is the one people decline by
///    reflex, and iOS only ever shows it once.
///
/// The welcome carousel that used to open this is gone. It was three screens of
/// explanation before a single question, and each step now carries its own
/// reason at the moment the question is asked, which is where an explanation is
/// worth reading.
///
/// **The sequence is fixed, and it is a cursor.** Once this view is on screen it
/// runs `phone → facebook → location → notifications` in that order, every time,
/// and each step advances it by being *completed* — not by some persisted flag
/// going true.
///
/// This replaced a derived order, which read the session, the saved flags and the
/// resolved place on every change and showed whichever step was still
/// outstanding. It was resumable and it was wrong three separate ways, all the
/// same shape: an answer that landed early moved the flow. A place resolving in
/// the background skipped the rest of the run; a second account inherited the
/// first one's answers and opened on the last screen; a returning account's
/// server-side `onboardingCompleted` dismissed the flow mid-step. Each was a real
/// bug, each was fixed by pinning one more thing down, and the pattern was the
/// argument: a flow whose position is computed from state has as many ways to
/// jump as it has inputs.
///
/// What it costs is resumability. Quitting halfway starts the four screens over
/// rather than resuming — two of which are one tap to pass — and that is the
/// trade being made deliberately.
struct OnboardingView: View {
    /// Called once every step has been answered or passed. Sets
    /// `hasCompletedOnboarding`, which is what dismisses this.
    let done: () -> Void

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var chooser: PlaceChooser
    @EnvironmentObject private var account: AccountSession

    /// Set the moment the last step is passed, so `finish`'s await doesn't leave
    /// a live screen behind the spinner.
    @State private var isFinishing = false

    /// Where the flow is. The only thing that decides which screen is showing.
    @State private var current: Step = .phone

    enum Step: Int, CaseIterable {
        case phone, facebook, location, notifications

        var next: Step { Step(rawValue: rawValue + 1) ?? .notifications }

        /// Snake_case for the analytics breakdown, spelled out rather than
        /// derived from the case name: a rename here is a rename of a property
        /// value, which splits a funnel in two without failing anything.
        var analyticsName: String {
            switch self {
            case .phone: return "phone"
            case .facebook: return "facebook"
            case .location: return "location"
            case .notifications: return "notifications"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                switch current {
                case .phone:
                    PhoneLoginView { _ in
                        // Whether this account has been onboarded is read off
                        // the viewer in `RootView`, not decided here. `isNewUser`
                        // is close but not the same fact — an account that was
                        // created and abandoned halfway is a returning user who
                        // has never finished.
                        Task { await account.reportFacebookConnection(await SessionState.isSignedIn()) }
                        advance()
                    }
                    .transition(.opacity)
                case .facebook:
                    FacebookPage { advance() }
                        .transition(.opacity)
                case .location:
                    LocationPage { advance() }
                        .transition(.opacity)
                case .notifications:
                    NotificationsPage(isFinishing: isFinishing) { finish() }
                        .transition(.opacity)
                }
            }
        }
        .background(Color(.systemBackground))
        .animation(.easeInOut(duration: 0.22), value: current)
        // The one concession to state, made once and never revisited: you cannot
        // ask somebody for their phone number when they already have a session,
        // so a flow that opened because the *place* went missing starts at the
        // step after it. Read here rather than in `current` so that signing in
        // later in this run can't retroactively move anything.
        .onAppear { if account.isSignedIn { current = .facebook } }
    }

    /// The only way forward, which is what makes it the only place a step has
    /// to be counted.
    ///
    /// The flow is not resumable — quitting halfway starts the four screens over
    /// — so a step that never fires is a step somebody quit on, and the drop-off
    /// between these four events is the whole reason to have them. The last step
    /// doesn't come through here: it finishes rather than advances, and
    /// `RootView` captures that one.
    private func advance() {
        Analytics.capture(.onboardingStepCompleted, [
            "step": current.analyticsName,
            "step_index": current.rawValue + 1
        ])
        current = current.next
    }

    /// A dot per step, and no back button.
    ///
    /// Back was removed with the welcome screen: three of these four steps are
    /// answered somewhere other than this flow — a verified phone number, a
    /// Facebook cookie jar, a system permission — so a chevron would offer to
    /// return to questions that are no longer askable. The two answers that
    /// *are* changeable from here (the place, and whether to connect Facebook)
    /// are both changeable again from Settings, which is where a second thought
    /// belongs.
    private var header: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { dot in
                Capsule()
                    .fill(dot == current ? Color.primary : Color(.tertiaryLabel))
                    .frame(width: dot == current ? 18 : 6, height: 6)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: current)
        .padding(.top, 14)
        .padding(.bottom, 4)
        .accessibilityLabel("Step \(current.rawValue + 1) of \(Step.allCases.count)")
    }

    /// The one place in the app that waits for a location to be agreed.
    ///
    /// Everything the location step does is optimistic, which is what keeps a
    /// first run moving — the ten-second round trip to name the place runs while
    /// the user reads the notifications screen. But a place that never landed
    /// must not reach the app: `Preferences.needsOnboarding` re-checks it on
    /// every launch, so letting it through would show onboarding again on the
    /// next start. So the last step settles first, and a failure sends the user
    /// back to the step that asks, where the error is already on screen.
    private func finish() {
        // Counted here rather than in `advance`, because the last step does not
        // advance — it finishes. The answer has been given either way, so the
        // step is complete even on the path below that sends the user back to
        // the location screen.
        Analytics.capture(.onboardingStepCompleted, [
            "step": Step.notifications.analyticsName,
            "step_index": Step.notifications.rawValue + 1
        ])
        Task {
            isFinishing = true
            await chooser.settle()
            isFinishing = false

            guard prefs.resolvedPlace != nil else {
                // The only backwards move in the flow, and it is an explicit
                // one: the required answer isn't there, so return to the screen
                // that asks for it — which is already showing the error.
                current = .location
                return
            }
            done()
        }
    }
}

// MARK: - 2. Facebook

/// Asked for properly, and the only step here that can be passed without an
/// answer the app stores.
///
/// Everything measured about a signed-in session says this is the version of the
/// app worth having (`docs/logged-in-findings.md`): a stable seller id, so a
/// listing can be attributed rather than shrugged at; results that keep loading
/// instead of stopping at the first batch; and ranking done against a real
/// account rather than against nobody. Handing off to message a seller lands in
/// an app that already knows who you are.
///
/// So the primary action is signing in and "not now" is a text button underneath
/// it. The three lines above the buttons are the whole argument — a caption
/// under the decline used to list what still works without an account, and it
/// was answering a question nobody had yet while making the cheaper option look
/// like the considered one. The reduced app is genuinely usable, which is why
/// this isn't a gate; Settings is where somebody who declines can change their
/// mind.
private struct FacebookPage: View {
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

    /// Benefits, stated as benefits.
    ///
    /// Every line here used to name the thing you lose without an account —
    /// "none of which a signed-out page carries", "a search stops after the
    /// first couple of dozen". Accurate, and the wrong shape for a screen
    /// asking somebody to say yes: half of each sentence described the option
    /// they were being talked out of, which is how a pitch ends up arguing with
    /// itself. The comparison also only lands for someone who already knows
    /// what the reduced version looks like, and nobody on their first run does.
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
            VStack(alignment: .leading, spacing: 8) {
                Text(isSignedIn ? "You're connected" : "Connect Facebook")
                    .font(.largeTitle.weight(.bold))
                Text(isSignedIn
                     ? "Seller details, unlimited scrolling and Facebook's own picks are all switched on."
                     : "Openmarket works best with your account. You'll sign in on Facebook's own page.")
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

            Spacer(minLength: 24)

            if isSignedIn {
                OnboardingButton(title: "Continue", isEnabled: true, action: done)
            } else {
                OnboardingButton(title: "Sign in with Facebook", isEnabled: true) {
                    showSignIn = true
                }

                Button(action: decline) {
                    Text("Not now — browse without it")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .task { isSignedIn = await SessionState.isSignedIn() }
        .sheet(isPresented: $showSignIn) {
            SignInView(surface: .onboarding) {
                Task {
                    isSignedIn = true
                    let connected = await SessionState.isSignedIn()
                    store.setSession(connected ? .authed : .unauthed)
                    // Signing in doesn't change the scene phase, so without this
                    // the server's picture of the connection would wait for the
                    // next foreground.
                    await account.reportFacebookConnection(connected)
                }
            }
        }
    }

    /// "Not now", which is a real answer rather than an absence of one.
    ///
    /// Worth its own event rather than being read as the gap between arriving
    /// at this step and leaving it: the share of people who decline here is the
    /// argument for or against ever making this a gate, and that number should
    /// not have to be inferred.
    private func decline() {
        Analytics.capture(.facebookConnectDeclined, ["surface": Analytics.Surface.onboarding.rawValue])
        done()
    }
}

// MARK: - 3. Location

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

            Text("Facebook names the place from your coordinate, and every search runs against that place — same as Marketplace itself.")
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

// MARK: - 4. Notifications

/// Skippable, and asked for one specific thing: price drops on saved listings.
///
/// The reason this is a screen of our own rather than the system prompt fired
/// straight at the user is that **iOS shows that prompt exactly once**. A "don't
/// allow" is close to permanent — recoverable only by a trip to Settings that
/// almost nobody makes — so a prompt with no stated purpose spends the single
/// ask on a reflex. Naming the payoff first is what turns it into a decision.
///
/// Price alerts specifically, and not "news and updates", because that is the
/// notification this app can actually send well: it already tracks saved
/// listings and it already parses price runs (`PriceRun`), so a drop is a fact
/// it can notice without asking anybody anything.
///
/// Declining still reports upward — see `AccountSession.registerPushToken`. An
/// install that said no is a different thing from one that was never asked.
private struct NotificationsPage: View {
    let isFinishing: Bool
    let done: () -> Void

    @StateObject private var push = PushRegistrar.shared
    @State private var isAsking = false

    private struct Reason {
        let symbol: String
        let title: String
        let body: String
    }

    private let reasons = [
        Reason(symbol: "arrow.down.right.circle",
               title: "Price drops on things you save",
               body: "Save a listing and we'll tell you if the seller cuts the price — the one thing on Marketplace that's worth knowing about immediately."),
        Reason(symbol: "clock.badge.checkmark",
               title: "Before someone else gets there",
               body: "Good listings go fast, and a price cut is when they go fastest. A notification is the difference between seeing it and seeing it sold."),
        Reason(symbol: "hand.raised",
               title: "Nothing else",
               body: "No daily digests, no marketing, no re-engagement nudges. If it isn't about a listing you saved, we don't send it.")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Get price alerts")
                    .font(.largeTitle.weight(.bold))
                Text("Turn on notifications and we'll let you know when something you saved drops in price.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 24)

            VStack(alignment: .leading, spacing: 22) {
                ForEach(reasons.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: reasons[index].symbol)
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(reasons[index].title)
                                .font(.headline)
                            Text(reasons[index].body)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.top, 32)

            Spacer(minLength: 24)

            // Once the system has an answer there is nothing left to ask —
            // requesting again returns the stored one without showing anything —
            // so the button stops offering and starts finishing.
            if push.status == .notDetermined {
                OnboardingButton(title: "Turn on notifications",
                                 isEnabled: !isAsking && !isFinishing,
                                 isBusy: isAsking || isFinishing,
                                 action: ask)

                Button(action: done) {
                    Text("Not now")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isAsking || isFinishing)

            } else {
                OnboardingButton(title: "Start browsing",
                                 isEnabled: !isFinishing,
                                 isBusy: isFinishing,
                                 action: done)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .task { await push.refreshStatus() }
    }

    /// Asks, then leaves. Both answers move on — this step is skippable, and a
    /// "don't allow" that stranded the user on the screen that caused it would
    /// be the worst possible reading of optional.
    private func ask() {
        Task {
            isAsking = true
            await push.requestAuthorization()
            isAsking = false
            done()
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
