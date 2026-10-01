import SwiftUI

struct AccountGateView: View {
    let done: () -> Void

    @EnvironmentObject private var account: AccountSession
    @EnvironmentObject private var store: ListingStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step?
    @State private var isActive = true
    @State private var isAdvancing = false
    @State private var showFacebookLogin = false
    @State private var cancelAfterFacebookDismisses = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Hashable {
        case phone, facebook, complete

        static func next(hasAccount: Bool, facebookConnected: Bool) -> Step {
            if !hasAccount { return .phone }
            if !facebookConnected { return .facebook }
            return .complete
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step == .phone || step == .facebook {
                    HStack(spacing: 6) {
                        ForEach([Step.phone, .facebook], id: \.self) { item in
                            Capsule()
                                .fill(item == step ? Color.primary : Color(.tertiaryLabel))
                                .frame(width: item == step ? 18 : 6, height: 6)
                        }
                    }
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .accessibilityLabel(step == .phone ? "Step 1 of 2" : "Step 2 of 2")
                }

                ZStack {
                    switch step {
                    case .phone:
                        PhoneLoginView(prompt: "Verify your number to save your price checks.") { _ in
                            Task { await advance() }
                        }
                        .transition(.opacity)
                    case .facebook:
                        facebookIntroduction
                            .transition(.opacity)
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(Color(.systemBackground))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: step)
            .navigationTitle("Price Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel", action: cancel)
                }
            }
        }
        .sheet(isPresented: $showFacebookLogin, onDismiss: {
            if cancelAfterFacebookDismisses {
                cancel()
            } else {
                // Resume only after Facebook's sheet is gone, so the caller
                // can safely dismiss this gate and open the price check.
                Task { await advance() }
            }
        }) {
            SignInView(surface: .accountGate, onCancel: {
                cancelAfterFacebookDismisses = true
                showFacebookLogin = false
            }) {
                showFacebookLogin = false
            }
        }
        .task { await advance(logOpen: true) }
        .onDisappear { isActive = false }
    }

    private var facebookIntroduction: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Connect Facebook")
                            .font(.largeTitle.weight(.bold))
                        Text("One more step to check your price.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)

                    VStack(alignment: .leading, spacing: 22) {
                        facebookBenefit("magnifyingglass", title: "Compare nearby listings",
                                        detail: "Use Marketplace listings to find a price for your item.")
                        facebookBenefit("lock.shield", title: "Sign in with Facebook",
                                        detail: "You'll sign in on Facebook's own page.")
                    }
                    .padding(.top, 32)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            Button {
                showFacebookLogin = true
            } label: {
                Text("Connect Facebook")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.primary, in: Capsule())
                    .foregroundStyle(Color(.systemBackground))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
    }

    private func facebookBenefit(_ symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func advance(logOpen: Bool = false) async {
        guard isActive, !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        let connected = await SessionState.isSignedIn()
        // A cookie check can finish after Cancel or an interactive dismissal.
        guard isActive, !Task.isCancelled else { return }
        store.setSession(connected ? .authed : .unauthed)

        if logOpen {
            Analytics.capture(.accountGateOpened, [
                "has_account": account.isSignedIn,
                "facebook_connected": connected
            ])
        }

        step = Step.next(hasAccount: account.isSignedIn, facebookConnected: connected)
        guard step == .complete else { return }

        isActive = false
        Analytics.capture(.accountGateSatisfied)
        Task { await account.reportFacebookConnection(connected) }
        // The caller resumes the check only after the sheet has dismissed.
        done()
        dismiss()
    }

    private func cancel() {
        isActive = false
        dismiss()
    }
}
