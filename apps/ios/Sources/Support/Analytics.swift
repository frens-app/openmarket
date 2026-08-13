import Foundation
import PostHog
import os

/// Product analytics: what people do with the app, counted.
///
/// Deliberately a different thing from `Metrics`, which measures the *scraping*
/// — parse coverage, page latency, how often Facebook walls us — and stays on
/// the device because none of it is about a person. This asks the other
/// question, the one nothing in the app could answer before: does anybody search
/// twice, does the Price Check number get copied, which of the four routes into
/// a listing people actually take.
///
/// **Search terms and listing content do go up, and that is a decision rather
/// than a leak.** `Metrics` says "no listing content and no search terms ever
/// leave the device" (§8) and that still governs *that* file; it does not govern
/// this one. The rule was written when the only thing on the other end was an
/// unbuilt telemetry endpoint, and it costs more than it protects here: "which
/// searches come back empty" and "what do people click" are the two questions
/// this whole app turns on, and neither survives being reduced to a string
/// length. So a search carries its term, a listing carries its title, price and
/// place, and a price check carries what was typed and what the model made of
/// it.
///
/// **What still doesn't go up**, and this part is a rule:
///
/// * **Phone numbers.** The login identity, never shown to other users
///   (`docs/backend.md` §6), and no product question needs it in a third-party
///   tool — `distinct_id` answers all of them.
/// * **Tokens and cookies**, obviously, but worth writing down beside the rest.
/// * **Raw coordinates.** A city and a rounded distance are facts about a
///   *search*; a latitude and longitude to six places is a fact about where
///   somebody sleeps, and nothing here is improved by having it.
/// * **Photos.** Not a privacy line so much as an obvious one — they belong to
///   the price-check request, they are already stored against that row, and
///   they are megabytes.
///
/// Free text goes through `text(_:)`, which truncates. Nothing else about
/// content is filtered.
///
/// **Silent without a key.** `POSTHOG_API_KEY` comes from the xcconfig by way of
/// the Info.plist, same route as the API endpoint, and Debug ships it empty. A
/// build with no key never calls `setup`, so nothing is queued, nothing is
/// written to disk and nothing is sent — which is what keeps a simulator running
/// the onboarding flow for the ninth time out of the funnel everybody reads.
/// Pointing a dev build at a PostHog project is a line in
/// `Debug.local.xcconfig`.
enum Analytics {
    private static let log = Logger(subsystem: "lol.frens.openmarket", category: "analytics")

    /// The PostHog project API key — the `phc_…` one, which is a *public*
    /// client-side token and is meant to ship inside an app. Absent means off.
    private static let projectToken: String? = API.bundleString("POSTHOG_API_KEY")

    /// Host, without a scheme, for the reason `API_HOSTNAME` has none: xcconfig
    /// treats `//` as a comment, so `https://us.i.posthog.com` in one of those
    /// files silently becomes `https:`. Region matters — a US key posted to the
    /// EU host is rejected, not rerouted.
    private static let hostname = API.bundleString("POSTHOG_HOSTNAME") ?? "us.i.posthog.com"

    /// Whether anything will actually be sent. Read by the few call sites that
    /// would otherwise do work purely to build properties.
    static var isEnabled: Bool { projectToken != nil }

    // MARK: - Lifecycle

    /// Called once, from the app delegate, before anything else happens.
    static func start() {
        guard let projectToken else {
            log.info("analytics off: no POSTHOG_API_KEY in this configuration")
            return
        }

        let config = PostHogConfig(projectToken: projectToken, host: "https://\(hostname)")

        // Off, because the automatic version swizzles `viewDidAppear` and this
        // app is SwiftUI: every screen is some flavour of
        // `UIHostingController<ModifiedContent<…>>`, which produces a `$screen`
        // stream that is both unreadable and unstable across a refactor. The
        // events below name the things that matter instead.
        config.captureScreenViews = false

        // On, and it is the cheapest thing here: `$application_opened`,
        // `$application_installed` and `$application_updated` are what make
        // retention and version-adoption charts work at all, and none of them
        // require a call site.
        config.captureApplicationLifecycleEvents = true

        // `.identifiedOnly` is the default and the right one: everything before
        // the phone screen stays anonymous, and a person profile is created at
        // the moment there is a person to attach it to. Said out loud because
        // the alternative silently multiplies the billable profile count by
        // every install that never signs up.
        config.personProfiles = .identifiedOnly

        #if DEBUG
        config.debug = true
        #endif

        PostHogSDK.shared.setup(config)
        log.info("analytics on → \(hostname, privacy: .public)")
    }

    /// Attaches everything from here on to an account.
    ///
    /// The distinct id is the server's user id, so the same person on a second
    /// phone is the same person in PostHog — which is the entire reason this
    /// isn't keyed on `InstallIdentity`. PostHog merges the anonymous history
    /// that came before it, so the onboarding funnel survives the sign-in that
    /// completes it.
    static func identify(userID: String, properties: [String: Any] = [:], setOnce: [String: Any] = [:]) {
        guard isEnabled, !userID.isEmpty else { return }
        PostHogSDK.shared.identify(userID, userProperties: properties, userPropertiesSetOnce: setOnce)
    }

    /// Forgets the account and starts a fresh anonymous id.
    ///
    /// Signing out on a shared phone must not leave the next person's events
    /// filed under the last person's profile — which is exactly what happens
    /// without this, because the distinct id persists across launches.
    static func reset() {
        guard isEnabled else { return }
        PostHogSDK.shared.reset()
    }

    /// Properties stamped onto every subsequent event.
    ///
    /// Kept to facts that change rarely and that almost every question wants to
    /// break down by — whether Facebook is connected, which city, how wide the
    /// radius is. A super property is the difference between "search_completed
    /// returned nothing" and "search_completed returned nothing, signed out, at
    /// 1 mile", and the second one is an answer.
    static func register(_ properties: [String: Any]) {
        guard isEnabled else { return }
        PostHogSDK.shared.register(properties)
    }

    static func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties.isEmpty ? nil : properties)
    }

    /// Free text, trimmed and capped, on its way into a property.
    ///
    /// Every string property that came from a person or a listing goes through
    /// here. The cap is not a privacy measure — content is allowed now — it is a
    /// size one: a price-check description is a `3...8` line field with no limit
    /// on it, a Marketplace title is whatever the seller pasted, and one person
    /// dropping an essay into either would otherwise mint a single event tens of
    /// kilobytes wide, queued on disk and retried on every flush.
    ///
    /// 200 characters, because these are titles and sentences. It is well past
    /// the longest real Marketplace title and long enough that a truncated
    /// property is a curiosity rather than a lost answer — and empty comes back
    /// as nil so an absent title reads as absent rather than as `""`.
    static func text(_ value: String?, limit: Int = 200) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }

    /// Sends whatever is queued.
    ///
    /// Called when the app leaves the foreground, beside the cache write, and
    /// for the same reason: the queue flushes on a size and a timer, both of
    /// which are wrong for a process about to be killed. The last events of a
    /// session are disproportionately the interesting ones — they are the ones
    /// at the end of a funnel.
    static func flush() {
        guard isEnabled else { return }
        PostHogSDK.shared.flush()
    }

    // MARK: - Events

    /// Every event this app sends, in one list.
    ///
    /// `object_action`, snake_case, past tense — PostHog's own convention, and
    /// worth following exactly because their insight builder groups on the
    /// prefix: eight `price_check_*` events sort together and read as a funnel,
    /// where `checkedPrice` and `copyPriceTapped` do not.
    ///
    /// An enum rather than string literals at the call sites, because a typo in
    /// an event name does not fail — it quietly creates a second event that
    /// splits a funnel in half, and nobody notices for a month.
    /// `docs/analytics.md` is the plain-English version of this list, with the
    /// properties each one carries.
    /// `CaseIterable` so `AnalyticsTests` can walk the list and assert the
    /// convention holds. A naming rule nothing enforces is a naming rule that
    /// lasts until the next person is in a hurry.
    enum Event: String, CaseIterable {
        // MARK: Account

        /// This phone number had never been seen before. The signup number.
        case accountCreated = "account_created"
        case accountSignedIn = "account_signed_in"
        case accountSignedOut = "account_signed_out"
        case accountDeleted = "account_deleted"

        /// One per step of the four, as it is passed — which is what makes the
        /// drop-off between them readable. Onboarding is not resumable, so a
        /// step that never fires is a step somebody quit on.
        case onboardingStepCompleted = "onboarding_step_completed"
        case onboardingCompleted = "onboarding_completed"

        /// A Facebook cookie jar now exists on this install. Not the same fact
        /// as `account_signed_in` — different session, different thing — and
        /// the one that decides how much of the app works.
        case facebookSessionConnected = "facebook_session_connected"
        /// "Not now" on the onboarding step. Recorded because declining is a
        /// real answer, and the share of people who give it is the argument for
        /// or against making that step a gate.
        case facebookConnectDeclined = "facebook_connect_declined"

        case notificationPermissionAnswered = "notification_permission_answered"

        // MARK: Browsing

        case searchSubmitted = "search_submitted"
        /// The result of the search, once the engine has finished with it.
        /// Separate from the submission because the gap between the two is the
        /// feature working or not.
        case searchCompleted = "search_completed"
        case discoverLoaded = "discover_loaded"

        /// A listing was opened, from wherever it was tapped.
        case listingOpened = "listing_opened"
        case listingSaved = "listing_saved"
        case listingUnsaved = "listing_unsaved"
        /// Handed off to Facebook — the app's one real conversion, since every
        /// route out of a listing is a link (§4).
        case listingOpenedOnFacebook = "listing_opened_on_facebook"

        /// Facebook declined to serve results without an account. The most
        /// important failure this app has, because it is the one that stops it
        /// being a product.
        case loginWallHit = "login_wall_hit"

        // MARK: Filters

        case filtersApplied = "filters_applied"
        case filtersReset = "filters_reset"
        case distanceChanged = "distance_changed"
        case locationChanged = "location_changed"

        // MARK: Price Check

        case priceCheckStarted = "price_check_started"
        case priceCheckCompleted = "price_check_completed"
        case priceCheckFailed = "price_check_failed"
        /// The number was copied, which is what somebody does immediately
        /// before pasting it into Facebook's price box. The closest thing this
        /// feature has to a conversion, and it carries both the price we
        /// recommended and the one they settled on.
        case priceCheckPriceCopied = "price_check_price_copied"
        case priceCheckListingCopied = "price_check_listing_copied"
        case priceCheckFeedbackSubmitted = "price_check_feedback_submitted"
        case priceCheckEvidenceOpened = "price_check_evidence_opened"
        case priceCheckHistoryOpened = "price_check_history_opened"
    }

    // MARK: - Shared property values

    /// Where a listing was tapped.
    ///
    /// The question the home screen was built to answer: two personal rails and
    /// a feed compete for the same thumb, and until now nothing said which one
    /// wins. Also the reason this is an enum — "discover" and "Discover" are two
    /// breakdown rows, and by the time you notice, the chart covers a month.
    enum Surface: String, CaseIterable {
        case discover
        case search
        case recentlyViewed = "recently_viewed"
        case saved
        /// The comparables under a price check, which are listings too.
        case priceCheckEvidence = "price_check_evidence"
        /// The listing screen itself — where saving happens.
        case listingDetail = "listing_detail"
        case onboarding
        case settings
        /// The sign-in offered at the bottom of a walled result set.
        case resultsFooter = "results_footer"
        case filterSheet = "filter_sheet"
        /// The "Show viewed" undo under a search that a filter emptied.
        case resultsNotice = "results_notice"
        case priceCheckRun = "price_check_run"
        case priceCheckHistory = "price_check_history"
    }

    /// Why a search ran, which is not the same question as who asked for one.
    ///
    /// **`search_completed` and `search_submitted` do not pair one-to-one, and
    /// this is what says so.** `ListingStore.run` is reached from seven places
    /// and only the first below is a person searching: adjusting three filters
    /// after one search produces one submission and four completions, so a
    /// funnel between the two events would report a conversion above 100% and
    /// look like a bug in PostHog rather than a property of the app.
    ///
    /// Filter on `new_search` to get the population that matches a submission.
    /// The rest are worth having on their own — a `refresh` rate is somebody
    /// distrusting the results, and a `retry` rate is the login wall.
    enum SearchTrigger: String {
        /// A term the user submitted. The only one paired with
        /// `search_submitted`.
        case newSearch = "new_search"
        /// The filter sheet closed on a change that needs different listings.
        case filters
        /// The city changed underneath the results.
        case location
        /// Pull to refresh.
        case refresh
        /// The "search here" control on the pinned filter bar.
        case rerun
        /// After a failure or a wall — the user asking again for the same thing.
        case retry
        /// A Facebook session appeared, and the result set genuinely differs by
        /// authentication rather than merely being longer.
        case signIn = "sign_in"
    }

    /// Where a search term came from.
    ///
    /// Inferred rather than plumbed through, and honestly so: a completion tap
    /// and typing the same word by hand are the same submission by the time it
    /// reaches `onSubmit`. The inference is worth having anyway — it answers
    /// whether the suggestion list earns its place — and it errs towards
    /// crediting the suggestions, which is the direction to know about.
    enum SearchSource: String {
        case typed
        case recent
        case interest
    }
}
