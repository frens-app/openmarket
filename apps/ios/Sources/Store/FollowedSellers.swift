import Foundation
import Combine

@MainActor
final class FollowedSellers: ObservableObject {
    static let shared = FollowedSellers()
    @Published private(set) var profiles: [SellerProfile]
    private let defaults: UserDefaults
    private static let key = "followedSellerProfiles.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        profiles = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([SellerProfile].self, from: $0) } ?? []
    }

    func contains(_ id: String) -> Bool { profiles.contains { $0.id == id } }

    func toggle(_ profile: SellerProfile) {
        if contains(profile.id) { profiles.removeAll { $0.id == profile.id } }
        else { profiles.insert(profile, at: 0) }
        persist()
    }

    func refresh(_ profile: SellerProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var refreshed = profile
        refreshed.photoURL = profile.photoURL ?? profiles[index].photoURL
        guard profiles[index] != refreshed else { return }
        profiles[index] = refreshed
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
