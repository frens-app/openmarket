import SwiftUI

/// Settings has to carry real functionality, which also answers Apple's
/// minimum-functionality concern about thin webview wrappers.
struct SettingsView: View {
    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: ListingStore
    @EnvironmentObject private var viewed: ViewedListings
    @EnvironmentObject private var account: AccountSession
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var filterTotals = FilterTotals.shared
    @State private var showSignIn = false
    @State private var showAccountLogin = false
    @State private var confirmingDelete = false
    @State private var deleteError: String?

    private func totalHeadline(_ count: Int, title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(count, format: .number)
                .font(.largeTitle.bold())
                .monospacedDigit()
            Text(title)
                .font(.headline)
        }
        .padding(.vertical, 8)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    totalHeadline(filterTotals.nonLocalListings, title: "Non-local listings filtered out")
                    totalHeadline(filterTotals.ads, title: "Ads filtered out")
                } footer: {
                    Text("All time on this device · Search and Discover")
                }

                Section {
                    totalHeadline(filterTotals.discoverListings, title: "Listings shown in Discover")
                    totalHeadline(filterTotals.searchListings, title: "Listings shown in Search")
                } footer: {
                    Text("All time on this device · Each listing counts once per feed when it comes into view.")
                }

                Section("Your account") {
                    if account.isSignedIn {
                        LabeledContent("Sign-in", value: accountProvider)
                        Button("Sign out") { Task { await account.signOut() } }
                        Button("Delete account", role: .destructive) { confirmingDelete = true }
                    } else {
                        LabeledContent("Sign-in", value: "Not signed in")
                        Button("Sign In") { showAccountLogin = true }
                        Text("An account is required for Price Check and saves your past checks across devices.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Facebook account") {
                    LabeledContent("Status",
                                   value: store.session == .authed ? "Signed in" : "Not signed in")
                    Button(store.session == .authed ? "Manage account" : "Sign in") {
                        showSignIn = true
                    }
                    Text(store.session == .authed
                         ? "Seller names and ratings are visible, and the home screen uses Facebook's picks for your account."
                         : "You can browse and search without signing in. Connecting Facebook adds seller names and ratings and personalizes the home screen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // No "Search area" section: place and distance are chosen
                // together in the location sheet, because they read as one fact
                // ("San Francisco · 10 mi").

                Section("History") {
                    Toggle("Include searches in history", isOn: $prefs.recordSearchHistory)
                    Button("Clear search history") { prefs.recentSearches = [] }
                        .disabled(prefs.recentSearches.isEmpty)
                    Button("Clear viewing history") { viewed.clear() }
                        .disabled(viewed.isEmpty)
                    Text("Turning this off keeps existing history until you clear it. Searches from Tools are never saved.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Viewing history powers \"Only new listings\" and Recently viewed. It stays on this device.")
                        .font(.caption)
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

                    Button("Restart onboarding") {
                        prefs.resetOnboarding()
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
            .sheet(isPresented: $showAccountLogin) {
                NavigationStack {
                    AccountLoginView { _ in showAccountLogin = false }
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") { showAccountLogin = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showSignIn) {
                SignInView(surface: .settings) {
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

    private var accountProvider: String {
        guard let viewer = account.state.viewer else { return "Unavailable offline" }
        switch viewer.signInProvider {
        case "apple": return "Apple"
        case "google": return "Google"
        case "phone": return "Phone number"
        default: return viewer.phoneNumber.isEmpty ? "Unavailable" : "Phone number"
        }
    }
}
