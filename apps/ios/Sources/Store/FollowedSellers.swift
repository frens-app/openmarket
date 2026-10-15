import Foundation
import Combine

@MainActor
final class FollowedSellers: ObservableObject {
    static let shared: FollowedSellers = {
        let store = FollowedSellers(service: SellerService())
        store.accountSubscription = AccountSession.shared.$state.sink { [weak store] state in
            guard state != .unknown else { return }
            store?.setAccount(state.viewer?.id)
        }
        return store
    }()

    @Published private(set) var profiles: [SellerProfile]
    @Published private(set) var userID: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFailed = false
    private let defaults: UserDefaults
    private let service: (any SellerSyncService)?
    private static let guestKey = "followedSellerProfiles.v1"
    private var accountSubscription: AnyCancellable?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = UUID()
    private var pending: [String: FollowChange] = [:]
    private var observations: [String: SellerProfile] = [:]
    private var uploaded: [String: SellerProfile] = [:]

    private struct FollowChange: Codable, Equatable {
        var profile: SellerProfile
        var following: Bool
        var revision = UUID()
    }
    private struct Cache: Codable {
        var profiles: [SellerProfile]
        var pending: [String: FollowChange]
        var observations: [String: SellerProfile]
    }

    var statusText: String? {
        if userID == nil { return "Sign in to OpenMarket to sync followed sellers." }
        if syncFailed { return "Saved on this device. Sync will retry." }
        if isSyncing { return "Syncing followed sellers…" }
        return nil
    }

    init(defaults: UserDefaults = .standard, service: (any SellerSyncService)? = nil) {
        self.defaults = defaults
        self.service = service
        profiles = defaults.data(forKey: Self.guestKey)
            .flatMap { try? JSONDecoder().decode([SellerProfile].self, from: $0) } ?? []
    }

    private func cacheKey(_ id: String) -> String { "followedSellerProfiles.v2.\(id)" }

    func setAccount(_ id: String?) {
        guard userID != id else { return }
        persist()
        syncTask?.cancel()
        retryTask?.cancel()
        syncTask = nil
        retryTask = nil
        generation = UUID()
        userID = id
        isSyncing = false
        syncFailed = false
        pending = [:]
        observations = [:]
        uploaded = [:]
        if let id {
            let cache = defaults.data(forKey: cacheKey(id))
                .flatMap { try? JSONDecoder().decode(Cache.self, from: $0) }
            profiles = cache?.profiles ?? []
            pending = cache?.pending ?? [:]
            observations = cache?.observations ?? [:]
            // Claim legacy/guest follows once. They must not be imported again
            // into every account that later signs in on the same device.
            let guests = defaults.data(forKey: Self.guestKey)
                .flatMap { try? JSONDecoder().decode([SellerProfile].self, from: $0) } ?? []
            for profile in guests where !contains(profile.id) && pending[profile.id] == nil {
                profiles.append(profile)
                pending[profile.id] = FollowChange(profile: profile, following: true)
            }
            persist()
            defaults.removeObject(forKey: Self.guestKey)
            synchronize()
        } else {
            profiles = defaults.data(forKey: Self.guestKey)
                .flatMap { try? JSONDecoder().decode([SellerProfile].self, from: $0) } ?? []
        }
    }

    func contains(_ id: String) -> Bool { profiles.contains { $0.id == id } }

    func toggle(_ profile: SellerProfile, surface: Analytics.Surface? = nil) {
        let following = !contains(profile.id)
        if following { profiles.insert(profile, at: 0) }
        else { profiles.removeAll { $0.id == profile.id } }
        if userID != nil { pending[profile.id] = FollowChange(profile: profile, following: following) }
        persist()
        var properties: [String: Any] = ["seller_id": profile.id]
        properties["surface"] = surface?.rawValue
        Analytics.capture(following ? .sellerFollowed : .sellerUnfollowed, properties)
        synchronize()
    }

    func refresh(_ profile: SellerProfile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile.preservingMissingFields(from: profiles[index])
        }
        if userID != nil {
            let merged = profile.preservingMissingFields(from: observations[profile.id] ?? uploaded[profile.id])
            if uploaded[profile.id] != merged { observations[profile.id] = merged }
            if var change = pending[profile.id], change.following {
                change.profile = profile.preservingMissingFields(from: change.profile)
                change.revision = UUID()
                pending[profile.id] = change
            }
            // Bound the offline observation queue; follow changes are never evicted.
            if observations.count > 200, let id = observations.keys.sorted().first(where: { $0 != profile.id }) {
                observations.removeValue(forKey: id)
            }
        }
        persist()
        synchronize()
    }

    /// One writer per account. Pending changes are durable and overlay server
    /// reads, including changes made while a request is in flight.
    func synchronize() {
        guard syncTask == nil, let userID, let service else { return }
        retryTask?.cancel()
        retryTask = nil
        let generation = generation
        isSyncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == generation {
                    self.syncTask = nil
                    self.isSyncing = false
                }
            }
            do {
                repeat {
                    while let (id, change) = self.pending.first {
                        try Task.checkCancellation()
                        try await service.setFollow(change.profile, following: change.following, userID: userID)
                        guard self.generation == generation else { return }
                        if self.pending[id] == change { self.pending.removeValue(forKey: id) }
                        self.persist()
                    }
                    while let (id, profile) = self.observations.first {
                        try Task.checkCancellation()
                        try await service.upsert(profile, userID: userID)
                        guard self.generation == generation else { return }
                        self.uploaded[id] = profile
                        if self.observations[id] == profile { self.observations.removeValue(forKey: id) }
                        self.persist()
                    }
                    let remote = try await service.listFollows(userID: userID)
                    guard self.generation == generation else { return }
                    var merged = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                    for (id, change) in self.pending {
                        if change.following { merged[id] = change.profile }
                        else { merged.removeValue(forKey: id) }
                    }
                    // Keep the user's current order stable across background refreshes.
                    let existingIDs = Set(self.profiles.map(\.id))
                    self.profiles = self.profiles.compactMap { merged[$0.id] }
                        + merged.values.filter { !existingIDs.contains($0.id) }.sorted { $0.id < $1.id }
                    self.syncFailed = false
                    self.persist()
                } while !self.pending.isEmpty || !self.observations.isEmpty
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                self.syncFailed = true
                self.retryTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == generation else { return }
                    self.synchronize()
                }
            }
        }
    }

    private func persist() {
        if let userID {
            let cache = Cache(profiles: profiles, pending: pending, observations: observations)
            if let data = try? JSONEncoder().encode(cache) { defaults.set(data, forKey: cacheKey(userID)) }
        } else if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Self.guestKey)
        }
    }
}

extension SellerProfile {
    func preservingMissingFields(from previous: SellerProfile?) -> SellerProfile {
        guard let previous else { return self }
        var merged = self
        merged.photoURL = photoURL ?? previous.photoURL
        merged.joinedText = joinedText ?? previous.joinedText
        merged.rating = rating ?? previous.rating
        merged.ratingCount = ratingCount ?? previous.ratingCount
        merged.isHighlyRated = isHighlyRated ?? previous.isHighlyRated
        return merged
    }
}
