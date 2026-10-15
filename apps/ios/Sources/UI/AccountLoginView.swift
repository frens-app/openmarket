import AuthenticationServices
import GoogleSignIn
import OpenMarketProtos
import SwiftUI

struct AccountLoginView: View {
    @StateObject private var model = AccountLoginModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize = 40
    var isLinking = false
    var onSkip: (() -> Void)?
    var onSignedIn: (_ isNewUser: Bool) -> Void = { _ in }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    Text(isLinking ? "Link your account" : "Openmarket")
                        .font(.system(size: titleSize, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, 48)

                    if isLinking {
                        Text("We now use Apple and Google for sign-in. Link one to keep your existing account, saved listings, follows, and history.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 16)
                    }

                    Spacer(minLength: 48)

                    VStack(spacing: 8) {
                        if let error = model.errorMessage {
                            Label(error, systemImage: "exclamationmark.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        providerButton(.google, title: isLinking ? "Link with Google" : "Continue with Google", image: "GoogleSignInLogo")
                        providerButton(.apple, title: isLinking ? "Link with Apple" : "Continue with Apple", image: "AppleSignInLogo")

                        if let onSkip {
                            Button("Not now, browse without an account", action: onSkip)
                                .font(.system(.subheadline, design: .rounded).weight(.medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .padding(.top, 4)
                                .disabled(model.isBusy)
                        }
                    }
                    .frame(maxWidth: 400)
                    .padding(.bottom, 20)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize)
        }
        .interactiveDismissDisabled(isLinking && model.isBusy)
        .toolbar {
            if isLinking {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .disabled(model.isBusy)
                }
            }
        }
        .onChange(of: model.signedInIsNewUser) { _, value in
            if let value { onSignedIn(value) }
        }
    }

    private func providerButton(_ provider: SignInProvider, title: String, image: String) -> some View {
        Button {
            Task { await model.signIn(provider: provider, linking: isLinking) }
        } label: {
            HStack(spacing: 12) {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 20, height: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(colorScheme == .dark ? Color.white : Color(white: 0.2))
            .padding(.horizontal, 44)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(colorScheme == .dark ? Color.white.opacity(0.05) : Color(white: 0.973), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.2), lineWidth: 0.5)
            }
            .overlay(alignment: .trailing) {
                if model.activeProvider == provider {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 20)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(AccountProviderButtonStyle())
        .disabled(model.isBusy)
        .accessibilityValue(model.activeProvider == provider ? "In progress" : "")
    }
}

private struct AccountProviderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

@MainActor
final class AccountLoginModel: ObservableObject {
    @Published private(set) var activeProvider: SignInProvider?
    var isBusy: Bool { activeProvider != nil }
    @Published private(set) var errorMessage: String?
    @Published private(set) var signedInIsNewUser: Bool?
    private let apple = AppleAccountAuthorization()

    func signIn(provider: SignInProvider, linking: Bool = false) async {
        guard !isBusy else { return }
        activeProvider = provider
        errorMessage = nil
        defer { activeProvider = nil }
        do {
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })?
                .windows.first(where: \.isKeyWindow),
                  var presenter = window.rootViewController else {
                throw APIError.message("Couldn't open sign-in. Please try again.")
            }
            while let presented = presenter.presentedViewController { presenter = presented }
            if provider == .google {
                guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
                      let serverID = Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String,
                      clientID.hasSuffix(".apps.googleusercontent.com"),
                      serverID.hasSuffix(".apps.googleusercontent.com") else {
                    throw APIError.message("Google sign-in isn't configured in this build yet.")
                }
                let expectedScheme = clientID.components(separatedBy: ".").reversed().joined(separator: ".")
                let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
                let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
                guard schemes.contains(expectedScheme) else {
                    throw APIError.message("Google sign-in isn't configured in this build yet.")
                }
                GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID, serverClientID: serverID)
            }
            let expectedUserID = AccountSession.shared.state.viewer?.id
            if linking && expectedUserID == nil {
                throw APIError.message("Please reopen the app to restore your account before linking.")
            }
            let nonce = try await (linking
                ? AccountSession.shared.beginLinkSignIn(provider: provider)
                : AccountSession.shared.beginSignIn(provider: provider))
            let token: String
            var appleUserID: String?
            var names = AccountNames()
            switch provider {
            case .apple:
                let credential = try await apple.signIn(nonce: nonce, window: window, requestName: true)
                token = credential.identityToken
                appleUserID = credential.userID
                names = credential.names
            case .google:
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenter, hint: nil, additionalScopes: nil, nonce: nonce
                )
                guard let identityToken = result.user.idToken?.tokenString else {
                    throw APIError.message("Google didn't return a sign-in token. Please try again.")
                }
                token = identityToken
                names = AccountNames(firstName: result.user.profile?.givenName,
                                     lastName: result.user.profile?.familyName,
                                     displayName: result.user.profile?.name)
            default: return
            }
            if linking, let expectedUserID {
                try await AccountSession.shared.linkSignIn(
                    provider: provider, identityToken: token, nonce: nonce,
                    expectedUserID: expectedUserID, appleUserID: appleUserID, names: names
                )
                signedInIsNewUser = false
            } else {
                signedInIsNewUser = try await AccountSession.shared.signIn(
                    provider: provider, identityToken: token, nonce: nonce, appleUserID: appleUserID, names: names
                )
            }
        } catch {
            let nsError = error as NSError
            if (nsError.domain == ASAuthorizationError.errorDomain && nsError.code == ASAuthorizationError.canceled.rawValue)
                || (nsError.domain == kGIDSignInErrorDomain && nsError.code == GIDSignInError.canceled.rawValue) {
                return
            }
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't sign in. Please try again."
        }
    }
}

@MainActor
final class AppleAccountAuthorization: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Credential {
        let identityToken: String
        let authorizationCode: String
        let userID: String
        let names: AccountNames
    }
    private var continuation: CheckedContinuation<Credential, Error>?
    private var window: UIWindow?
    private var controller: ASAuthorizationController?
    private var requestName = false

    func signIn(nonce: String, window: UIWindow, requestName: Bool = false) async throws -> Credential {
        self.requestName = requestName
        self.window = window
        defer { self.window = nil; controller = nil }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.nonce = nonce
            if requestName { request.requestedScopes = [.fullName, .email] }
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            self.controller = controller
            controller.performRequests()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        window!
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let data = credential.identityToken,
              let token = String(data: data, encoding: .utf8) else {
            finish(.failure(APIError.message("Apple didn't return a sign-in token. Please try again.")))
            return
        }
        guard let codeData = credential.authorizationCode,
              let code = String(data: codeData, encoding: .utf8) else {
            finish(.failure(APIError.message("Apple didn't return an authorization code. Please try again.")))
            return
        }
        let names = requestName
            ? AppleSignInNames.saveAndLoad(AccountNames(appleFullName: credential.fullName), userID: credential.user)
            : AccountNames()
        finish(.success(Credential(identityToken: token, authorizationCode: code, userID: credential.user, names: names)))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<Credential, Error>) {
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}

struct PhoneAccountLinkBanner: View {
    var onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("We’re changing sign-in", systemImage: "person.crop.circle.badge.exclamationmark")
                .font(.headline)
            Text("Link Apple or Google to keep your existing account and everything you’ve saved.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Link your account", action: onLink)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
    }
}
