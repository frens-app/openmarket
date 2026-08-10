import SwiftUI

/// §5 — Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var viewed: ViewedListings
    @Environment(\.dismiss) private var dismiss
    @State private var showSignIn = false

    var body: some View {
        NavigationStack {
            Form {
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

                // Picked once during onboarding, and editable ever after:
                // freezing a standing statement about what someone shops for at
                // whatever they tapped in their first thirty seconds would be a
                // strange thing to do with it, even now that all it drives is
                // the search field's suggestions.
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
                    Text("Search history fills the suggestions under the search field. Turn it off to search without adding to it — what's already saved stays until you clear it. Seller drafts never search into your history.")
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
            .sheet(isPresented: $showSignIn) {
                SignInView {
                    // The result set itself changes with the session, so drop
                    // anything cached under the old one and re-run.
                    Task {
                        store.setSession(await SessionState.isSignedIn() ? .authed : .unauthed)
                        await store.retry()
                    }
                }
            }
        }
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
