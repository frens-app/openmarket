import Foundation
import Combine

@MainActor
final class SellerAccess: ObservableObject {
    @Published var destination: SellerProfile?
    @Published var showSignIn = false
    private var pending: SellerProfile?
    private var generation = UUID()
    private let isSignedIn: () async -> Bool

    init(isSignedIn: @escaping () async -> Bool = { await SessionState.isSignedIn() }) {
        self.isSignedIn = isSignedIn
    }

    func open(_ profile: SellerProfile) async {
        generation = UUID()
        let request = generation
        let connected = await isSignedIn()
        guard request == generation else { return }
        if connected {
            pending = nil
            destination = profile
        } else {
            destination = nil
            pending = profile
            showSignIn = true
        }
    }

    func finishSignIn() async -> Bool {
        let request = generation
        guard await isSignedIn(), request == generation else { return false }
        let profile = pending
        pending = nil
        showSignIn = false
        destination = profile
        return true
    }

    func cancelSignIn() {
        generation = UUID()
        pending = nil
        showSignIn = false
    }
}
