import Foundation
import PostHog
import os

/// Product analytics. `Metrics` measures the scraping and stays on the device;
/// this measures what people do and leaves it.
///
/// `docs/analytics.md` is the tracking plan: every event, every property, what
/// is deliberately not sent, and why Debug and Release point at different
/// PostHog projects. Keep it in step when adding an event.
enum Analytics {
    private static let log = Logger(subsystem: "lol.frens.openmarket", category: "analytics")

    /// PostHog's public `phc_…` project key. Absent switches analytics off.
    private static let projectToken: String? = API.bundleString("POSTHOG_API_KEY")

    /// No scheme: xcconfig treats `//` as a comment. Region matters — a US key
    /// posted to the EU host is rejected.
    private static let hostname = API.bundleString("POSTHOG_HOSTNAME") ?? "us.i.posthog.com"

    /// Whether events are sent, separately from whether the SDK runs at all.
    ///
    /// Off in Debug. The SDK still starts, so feature flags and remote config
    /// work — this suppresses capture only, which is the difference between it
    /// and an empty key.
    ///
    /// Parsed from a string rather than read as a `Bool`: plist variable
    /// substitution produces `"NO"`, not `false`, so `bool(forInfoDictionaryKey:)`
    /// would see a non-empty string and call it true. Absent means yes, so a
    /// setting somebody deletes can't silently kill production analytics.
    static let capturesEvents: Bool = {
        guard let raw = API.bundleString("POSTHOG_CAPTURE_EVENTS")?.uppercased() else { return true }
        return !["NO", "FALSE", "0"].contains(raw)
    }()

    /// Whether the SDK is configured at all. Not the same question as
    /// `capturesEvents` — a build can run PostHog for flags and send nothing.
    static var isEnabled: Bool { projectToken != nil }

    // MARK: - Lifecycle

    /// Called once from the app delegate, before anything else.
    static func start() {
        guard let projectToken else {
            log.info("analytics off: no POSTHOG_API_KEY in this configuration")
            return
        }

        let config = PostHogConfig(projectToken: projectToken, host: "https://\(hostname)")
        // Every SwiftUI screen is some `UIHostingController<ModifiedContent<…>>`,
        // so the autocaptured names are unreadable and unstable. The events below
        // name what matters instead.
        config.captureScreenViews = false
        config.captureApplicationLifecycleEvents = true
        // The default, said out loud: no person profile until there is a person,
        // so installs that never sign up aren't billable profiles.
        config.personProfiles = .identifiedOnly

        // The SDK's own switch, rather than a guard of ours in `capture`. It
        // suppresses every capture path including PostHog's own lifecycle
        // events, and `PostHogRemoteConfig` does not consult it — so flags and
        // remote config still load, which is the whole point of having this
        // separately from an empty key.
        //
        // Set on the config and never through `optIn()`/`optOut()`: those
        // persist to storage and would then win over this on every later
        // launch, which is a setting that ignores the build it is in.
        //
        // One consequence worth knowing: `identify` is suppressed too, so flags
        // in a non-capturing build evaluate against the anonymous id rather
        // than the account.
        config.optOut = !capturesEvents

        #if DEBUG
        config.debug = true
        #endif

        PostHogSDK.shared.setup(config)
        log.info("analytics \(capturesEvents ? "on" : "flags only", privacy: .public) → \(hostname, privacy: .public)")
    }

    /// The server's user id, not the install id, so one person on two phones is
    /// one person. PostHog merges the anonymous history that came before.
    static func identify(userID: String, properties: [String: Any] = [:], setOnce: [String: Any] = [:]) {
        guard isEnabled, !userID.isEmpty else { return }
        PostHogSDK.shared.identify(userID, userProperties: properties, userPropertiesSetOnce: setOnce)
    }

    /// Starts a fresh anonymous id, so a shared phone doesn't file the next
    /// person's events under the last one's profile.
    static func reset() {
        guard isEnabled else { return }
        PostHogSDK.shared.reset()
    }

    /// Properties stamped onto every later event.
    static func register(_ properties: [String: Any]) {
        guard isEnabled else { return }
        PostHogSDK.shared.register(properties)
    }

    static func capture(_ event: Event, _ properties: [String: Any] = [:]) {
        guard isEnabled else { return }
        PostHogSDK.shared.capture(event.rawValue, properties: properties.isEmpty ? nil : properties)
    }

    /// Trimmed, capped at 200 characters, nil when empty — so an absent title
    /// reads as absent rather than as `""`, and one pasted essay can't mint a
    /// 50KB event. Every free-text property goes through here.
    static func text(_ value: String?, limit: Int = 200) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }

    /// Called on the way to the background: the queue flushes on a size and a
    /// timer, neither of which helps a process about to be killed.
    static func flush() {
        guard isEnabled else { return }
        PostHogSDK.shared.flush()
    }

    // MARK: - Events

    /// `object_action`, snake_case, past tense — PostHog groups on the prefix.
    /// An enum because a typo'd event name doesn't fail, it silently splits a
    /// funnel. `AnalyticsTests` enforces the casing.
    enum Event: String, CaseIterable {
        case accountCreated = "account_created"
        case accountSignedIn = "account_signed_in"
        case accountSignedOut = "account_signed_out"
        case accountDeleted = "account_deleted"
        case onboardingStepCompleted = "onboarding_step_completed"
        case onboardingCompleted = "onboarding_completed"
        /// The Facebook browsing session, which is not the app's own account.
        case facebookSessionConnected = "facebook_session_connected"
        case facebookConnectDeclined = "facebook_connect_declined"
        case notificationPermissionAnswered = "notification_permission_answered"

        case searchSubmitted = "search_submitted"
        case discoverLoaded = "discover_loaded"
        case listingOpened = "listing_opened"
        case listingSaved = "listing_saved"
        case listingUnsaved = "listing_unsaved"
        /// Every route out of a listing is a link, so this is the closest
        /// thing to a conversion the app can see.
        case listingOpenedOnFacebook = "listing_opened_on_facebook"
        case loginWallHit = "login_wall_hit"

        case filtersApplied = "filters_applied"
        case distanceChanged = "distance_changed"
        case locationChanged = "location_changed"

        case priceCheckStarted = "price_check_started"
        case priceCheckCompleted = "price_check_completed"
        case priceCheckFailed = "price_check_failed"
        /// Copying the number is what happens immediately before pasting it into
        /// Facebook's price box.
        case priceCheckPriceCopied = "price_check_price_copied"
        case priceCheckListingCopied = "price_check_listing_copied"
        case priceCheckFeedbackSubmitted = "price_check_feedback_submitted"
        case priceCheckEvidenceOpened = "price_check_evidence_opened"
        case priceCheckHistoryOpened = "price_check_history_opened"

        /// Asking what somebody else's listing is worth. Its own prefix rather
        /// than a `source` on the price-check funnel: that one ends in a price
        /// being copied into a listing, and this one has no such step.
        case marketCheckStarted = "market_check_started"
        case marketCheckCompleted = "market_check_completed"
        case marketCheckFailed = "market_check_failed"
        case marketCheckEvidenceOpened = "market_check_evidence_opened"
    }

    // MARK: - Shared property values

    /// Where something was tapped. An enum because "discover" and "Discover"
    /// would be two breakdown rows.
    enum Surface: String, CaseIterable {
        case discover
        case search
        case recentlyViewed = "recently_viewed"
        case saved
        case priceCheckEvidence = "price_check_evidence"
        case listingDetail = "listing_detail"
        case onboarding
        case settings
        case resultsFooter = "results_footer"
        case filterSheet = "filter_sheet"
        case resultsNotice = "results_notice"
        case priceCheckRun = "price_check_run"
        case priceCheckHistory = "price_check_history"
        case marketCheck = "market_check"
    }

    /// Where a search term came from. Inferred by matching the recents and
    /// interests, because a tapped completion and a typed word are the same
    /// string by the time `onSubmit` sees them.
    enum SearchSource: String {
        case typed
        case recent
        case interest
    }
}
