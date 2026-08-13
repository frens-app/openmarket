import SwiftUI

/// §5 — Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var viewed: ViewedListings
    @EnvironmentObject private var account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        NavigationStack {
            Form {
                // This app's own account, and the first section because it is
                // the one the app is gated on. The Facebook section below it is
                // a different thing entirely — a browsing session, not an
                // identity — and they were easy to confuse when there was only
                // one of them.
                Section("Your account") {
                    LabeledContent("Phone", value: accountPhoneNumber)
                    Button("Sign out") { Task { await account.signOut() } }
                    Button("Delete account", role: .destructive) { confirmingDelete = true }
                    Text("Deleting removes your account and releases your phone number, so you can sign up again with it later. It can't be undone.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Facebook account") {
                    LabeledContent("Status",
                                   value: store.session == .authed ? "Signed in" : "Not signed in")
                    Button(store.session == .authed ? "Manage account" : "Sign in") {
                        showSignIn = true
                    }
                    Text(store.session == .authed
                         ? "Seller names and ratings are visible, results keep loading past the first page, and the home screen uses Facebook's own picks."
                         : "This is the reduced version of the app. Signing in adds seller names and ratings, lets results load past the first ~15, and builds the home screen from Facebook's own picks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // "Search area" used to sit here — a default-radius picker and
                // a read-only location row. Both moved to the location sheet,
                // where the place and the distance are chosen together because
                // they read as one fact ("San Francisco · 10 mi"), and both are
                // one tap from the bar that displays them.
                //
                // The radius picker had also quietly become wrong: it offered
                // only the standard rungs, so a radius set by "Try 6 mi" on the
                // results screen couldn't be represented, and opening Settings
                // would show some other value as selected.

                // The only place these are set — onboarding no longer asks.
                // All they drive is the search field's suggestions, and they
                // are optional: with none picked it falls back to a broad
                // default set (`Preferences.chosenInterests`).
                Section("Interests") {
                    NavigationLink {
                        InterestSettingsView()
                    } label: {
                        LabeledContent("Interests", value: interestSummary)
                    }
                }

                Section("History") {
                    Toggle("Include searches in history", isOn: $prefs.recordSearchHistory)
                    Button("Clear search history") { prefs.recentSearches = [] }
                        .disabled(prefs.recentSearches.isEmpty)
                    Button("Clear viewing history") { viewed.clear() }
                        .disabled(viewed.isEmpty)
                    Text("Search history fills the suggestions under the search field. Turn it off to search without adding to it — what's already saved stays until you clear it. Searches the Tools tab runs never go into your history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Viewing history is what \"Only new listings\" filters against, and what fills Recently viewed. It stays on this device — Facebook is never told which listings you opened.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("Signing in happens on Facebook's own page — this app has no login form of its own. It's the version of the app worth having, and browsing without it still works. Messaging a seller opens the Facebook app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                #if DEBUG
                // Which backend this build is talking to, in the app.
                //
                // The home-screen name says it ("Openmarket Dev" vs "Open
                // Market") but that is invisible once you are inside, and the
                // two builds are otherwise identical on screen. The expensive
                // version of guessing wrong is reading a laptop's database while
                // believing it is production.
                //
                // DEBUG only because a Release build has exactly one answer,
                // and printing a server address to users buys nothing.
                Section("Build") {
                    LabeledContent("Backend", value: API.environmentSummary)
                    LabeledContent("Bundle", value: Bundle.main.bundleIdentifier ?? "—")

                    // Onboarding is four screens that a given install sees
                    // exactly once, which makes changing one of them tedious to
                    // check: the alternatives are deleting the account, or
                    // deleting the app and signing in again from scratch.
                    //
                    // Signing out is part of it rather than a separate step,
                    // because the phone screen *is* the first step — resetting
                    // the flags alone would reopen the flow on Facebook and skip
                    // the thing most likely to be under test.
                    Button("Restart onboarding") {
                        Task {
                            prefs.resetOnboarding()
                            await account.signOut()
                        }
                    }
                }
                #endif
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Delete your account?", isPresented: $confirmingDelete) {
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) {
                    Task {
                        do {
                            try await account.deleteAccount()
                            // The account that answered onboarding no longer
                            // exists, so neither should its answers. Deliberately
                            // not done on plain sign-out: signing back into the
                            // same account is routine, and throwing away that
                            // person's city to make them pick it again is not.
                            prefs.resetOnboarding()
                        } catch {
                            deleteError = (error as? LocalizedError)?.errorDescription
                                ?? "Couldn't delete your account."
                        }
                    }
                }
            } message: {
                Text("Your account and saved details are removed. This can't be undone.")
            }
            .alert("Couldn't delete account",
                   isPresented: .init(get: { deleteError != nil },
                                      set: { if !$0 { deleteError = nil } })) {
                Button("OK") { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    // The result set itself changes with the session, so drop
                    // anything cached under the old one and re-run.
                    Task {
                        let connected = await SessionState.isSignedIn()
                        store.setSession(connected ? .authed : .unauthed)
                        // Recorded against this install, not the account: the
                        // cookies just written live in this app container and
                        // will not be there on the user's next phone.
                        await account.reportFacebookConnection(connected)
                        await store.retry()
                    }
                }
            }
        }
    }

    /// The signed-in number, formatted for reading. A session from an older app
    /// version may not have a cached viewer yet, so an offline launch has no
    /// number to show even though the account remains signed in.
    private var accountPhoneNumber: String {
        guard let viewer = account.state.viewer else { return "Unavailable offline" }
        return viewer.phoneNumber
    }

    /// The first couple by name, then a count. Naming all eighteen would wrap
    /// to three lines in a row that is meant to be glanced at.
    private var interestSummary: String {
        let chosen = prefs.chosenInterests
        let named = chosen.prefix(2).map(\.label).joined(separator: ", ")
        let rest = chosen.count - min(2, chosen.count)
        return rest > 0 ? "\(named) +\(rest)" : named
    }
}
