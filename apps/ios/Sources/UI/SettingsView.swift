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
                // They decide what Discover shows before there is any search
                // history, and are optional: with none picked it uses a broad
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
                    Text("Search history fills the suggestions under the search field, and seeds Discover on the home screen. Turn it off to search without changing either — what's already saved stays until you clear it. Seller drafts never search into your history.")
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

    /// The signed-in number, formatted for reading. Falls back rather than
    /// showing an empty row: `state` can only be `.signedIn` here, but a
    /// crash-on-assumption in Settings would be a poor trade for one string.
    private var accountPhoneNumber: String {
        guard case .signedIn(let viewer) = account.state else { return "—" }
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
