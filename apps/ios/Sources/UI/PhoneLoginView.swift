import SwiftUI

/// Signing in to *this app's* account, with a code sent by text.
///
/// Not to be confused with `SignInView`, which hands the user Facebook's own
/// login page so the browsing engines get a session. They are unrelated: this
/// one is our server and our account, and it is the gate the app opens behind.
struct PhoneLoginView: View {
    @StateObject private var model = PhoneLoginModel()
    @FocusState private var focused: Field?

    private enum Field { case phone, code }

    /// Called once a session exists. `isNewUser` decides whether onboarding
    /// runs — asked of the server rather than inferred from an empty profile,
    /// so a reinstall doesn't repeat it.
    var onSignedIn: (_ isNewUser: Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                Text(model.step == .phone ? "What's your number?" : "Check your messages")
                    .font(.largeTitle.bold())
                Text(model.step == .phone
                     ? "We'll text you a code. It's how you get back into your account on a new phone."
                     : "We sent a \(model.codeLength)-digit code to \(model.formattedPhoneNumber).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if model.step == .phone {
                phoneField
            } else {
                codeField
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            primaryButton

            if model.step == .code {
                secondaryControls
            }

            #if DEBUG
            devSkip
            #endif

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy, value: model.step)
        .onAppear { focused = .phone }
        .onChange(of: model.step) { _, step in
            focused = step == .phone ? .phone : .code
        }
        .onChange(of: model.signedInIsNewUser) { _, isNewUser in
            guard let isNewUser else { return }
            onSignedIn(isNewUser)
        }
    }

    private var phoneField: some View {
        HStack(spacing: 10) {
            // Fixed rather than a country picker, and it matches the server:
            // ALLOWED_COUNTRY_CODES gates which codes will be sent to at all,
            // and it ships as "1". A picker here without the matching server
            // config would offer countries whose sends get rejected.
            Text("+1")
                .font(.title2.monospacedDigit())
                .foregroundStyle(.secondary)

            TextField("(415) 555-0123", text: $model.nationalNumber)
                .font(.title2.monospacedDigit())
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .focused($focused, equals: .phone)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
    }

    private var codeField: some View {
        TextField("000000", text: $model.code)
            .font(.system(.largeTitle, design: .monospaced))
            .kerning(8)
            .multilineTextAlignment(.center)
            .keyboardType(.numberPad)
            // The whole reason the code field is one text field and not six
            // boxes: iOS offers the code from the SMS above the keyboard, and
            // that only works on a single field marked as a one-time code.
            .textContentType(.oneTimeCode)
            .focused($focused, equals: .code)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .onChange(of: model.code) { _, _ in
                Task { await model.submitIfComplete() }
            }
    }

    private var primaryButton: some View {
        Button {
            Task { await model.advance() }
        } label: {
            HStack {
                if model.isBusy {
                    ProgressView().tint(.white)
                } else {
                    Text(model.step == .phone ? "Send code" : "Continue")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canAdvance || model.isBusy)
    }

    private var secondaryControls: some View {
        HStack {
            Button("Change number") { model.backToPhone() }
                .font(.footnote)

            Spacer()

            Button(model.resendCountdown > 0
                   ? "Resend in \(model.resendCountdown)s"
                   : "Resend code") {
                Task { await model.resend() }
            }
            .font(.footnote)
            // The countdown mirrors the server's own cooldown, so the button is
            // only offered when a send would actually be accepted.
            .disabled(model.resendCountdown > 0 || model.isBusy)
        }
        .padding(.top, 4)
    }

    #if DEBUG
    /// Skips the *text message*, once per step, and nothing else.
    ///
    /// Compiled out of release builds entirely — the `#if DEBUG` is the first of
    /// two independent gates, the second being that the server only bypasses
    /// numbers on `DEV_BYPASS_PHONE_NUMBERS`, which it refuses to populate in
    /// production.
    ///
    /// **It appears on both steps rather than doing both at once.** One button
    /// that filled in a number and a code and landed you signed in meant the
    /// code screen was the one screen in the app nobody ever looked at — you
    /// could only reach it by waiting for a real SMS, which is the thing the
    /// button exists to avoid. Now it advances one step at a time, through the
    /// ordinary StartPhoneVerification/VerifyPhone pair, so the send ceiling,
    /// user creation, device upsert and session issue all still execute.
    private var devSkip: some View {
        VStack(spacing: 6) {
            Divider().padding(.vertical, 4)
            Button {
                Task { await model.devAdvance() }
            } label: {
                Label("Skip verification (dev)", systemImage: "hammer.fill")
                    .font(.footnote)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    // Without this the tappable area is the glyphs themselves,
                    // which at footnote size is a target you have to aim at.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .disabled(model.isBusy)
            Text(model.step == .phone
                 ? "Debug builds only. Any number, no text sent — empty uses \(PhoneLoginModel.testNumberDisplay)."
                 : "Debug builds only. Fills the dev code (\(PhoneLoginModel.testCode)).")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
    #endif
}

@MainActor
final class PhoneLoginModel: ObservableObject {
    enum Step { case phone, code }

    @Published var step: Step = .phone
    @Published var nationalNumber = ""
    @Published var code = ""
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var codeLength = 6
    @Published private(set) var resendCountdown = 0

    /// Set once the server confirms a session, so the view can hand the answer
    /// up without the model knowing about navigation.
    @Published private(set) var signedInIsNewUser: Bool?

    private let session = AccountSession.shared
    private var countdownTask: Task<Void, Never>?

    #if DEBUG
    /// The fallback number, used only when the field is empty.
    ///
    /// +1 500 555 xxxx is a reserved test range, so it can never reach a person
    /// even if this somehow ran against a real provider — which is why it is the
    /// default rather than something that looks like a real number.
    static let testNumber = "5005550100"
    /// Must match the server's `DEV_VERIFICATION_CODE`.
    static let testCode = "123456"
    static var testNumberDisplay: String { format(testNumber) }

    /// Takes one ordinary step with the tedious part filled in.
    ///
    /// Deliberately not a shortcut around the two RPCs: the phone step still
    /// calls StartPhoneVerification and the code step still calls VerifyPhone,
    /// so everything that hangs off them runs. What the server does with the
    /// number is the server's business — the code is only accepted without a
    /// send for numbers on `DEV_BYPASS_PHONE_NUMBERS`, and typing a number that
    /// isn't covered gets you a real text, which is a useful thing to be able to
    /// do on purpose.
    func devAdvance() async {
        switch step {
        case .phone:
            if digits.count != 10 { nationalNumber = Self.testNumber }
            await sendCode()
        case .code:
            code = Self.testCode
            await submit()
        }
    }
    #endif

    private var digits: String { nationalNumber.filter(\.isNumber) }

    /// E.164 for the server. The "+1" the UI shows is not part of the text
    /// field, so it is added here rather than parsed back out.
    var e164: String { "+1" + digits }

    var formattedPhoneNumber: String { Self.format(digits) }

    var canAdvance: Bool {
        switch step {
        case .phone: return digits.count == 10
        case .code: return code.count >= 4
        }
    }

    func advance() async {
        switch step {
        case .phone: await sendCode()
        case .code: await submit()
        }
    }

    /// Submits as soon as the code is the length the server said to expect, so
    /// an autofilled code doesn't also need a tap.
    func submitIfComplete() async {
        code = String(code.filter(\.isNumber).prefix(codeLength))
        guard code.count == codeLength, !isBusy else { return }
        await submit()
    }

    func backToPhone() {
        countdownTask?.cancel()
        resendCountdown = 0
        code = ""
        errorMessage = nil
        step = .phone
    }

    func resend() async {
        code = ""
        await sendCode(advancing: false)
    }

    private func sendCode(advancing: Bool = true) async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            let result = try await session.startVerification(phoneNumber: e164)
            codeLength = result.codeLength
            startCountdown(from: result.resendAfter)
            if advancing { step = .code }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't send a code."
        }
    }

    private func submit() async {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        do {
            signedInIsNewUser = try await session.verify(phoneNumber: e164, code: code)
        } catch {
            code = ""
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "That code isn't right."
        }
    }

    private func startCountdown(from seconds: Int) {
        countdownTask?.cancel()
        resendCountdown = max(0, seconds)
        guard resendCountdown > 0 else { return }
        countdownTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.resendCountdown > 0 else { return }
                self.resendCountdown -= 1
            }
        }
    }

    /// Display-only NANP grouping. Deliberately not a parser — the digits are
    /// what gets sent, and the server does the real validation.
    private static func format(_ digits: String) -> String {
        guard digits.count == 10 else { return "+1 " + digits }
        let area = digits.prefix(3)
        let exchange = digits.dropFirst(3).prefix(3)
        let line = digits.suffix(4)
        return "+1 (\(area)) \(exchange)-\(line)"
    }

    deinit { countdownTask?.cancel() }
}
