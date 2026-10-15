import Foundation
import Combine

@MainActor
final class SavedListings: ObservableObject {
    static let shared: SavedListings = {
        let store = SavedListings(service: SavedListingService())
        store.accountSubscription = AccountSession.shared.$state.sink { [weak store] state in
            guard state != .unknown else { return }
            store?.setAccount(state.viewer?.id)
        }
        return store
    }()

    private struct Account: Codable {
        var entries: [SavedListingEntry] = []
        var pending: [SavedListingMutation] = []
        var rejected: Set<String> = []
        var failedSaves: Set<String> = []
    }
    private struct Storage: Codable {
        var guest = Account()
        var accounts: [String: Account] = [:]
        var importedLegacy = false
    }
    @Published private(set) var entries: [SavedListingEntry] = []
    @Published private(set) var userID: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var syncFailed = false
    private let defaults: UserDefaults
    private let service: (any SavedListingSyncService)?
    private static let key = "savedListings.v2"
    private var storage: Storage
    private var pending: [SavedListingMutation] = []
    private var rejected: Set<String> = []
    private var failedSaves: Set<String> = []
    private var index: Set<String> = []
    private var accountSubscription: AnyCancellable?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var generation = UUID()

    var ids: [String] { entries.map { $0.listing.id } }
    var listings: [Listing] {
        entries.map {
            var listing = $0.listing
            // A persisted card has no position in the current browser DOM.
            listing.cardIndex = -1
            return listing
        }
    }
    var isEmpty: Bool { entries.isEmpty }
    var statusText: String? {
        if userID == nil { return "Sign in to OpenMarket to sync saved listings." }
        if !rejected.isEmpty { return "Some listings could not sync. Open them to refresh their details." }
        if entries.contains(where: { $0.listing.facebookListingID == nil }) { return "Some older saves are available only on this device." }
        if entries.contains(where: { !$0.listing.hasSaveMetadata }) { return "Open older saves to recover their details and sync them." }
        if syncFailed { return "Saved on this device. Sync will retry." }
        if isSyncing { return "Syncing saved listings…" }
        return nil
    }

    init(defaults: UserDefaults = .standard, service: (any SavedListingSyncService)? = nil,
         cachedListing: @MainActor (String) -> Listing? = { ListingCache.shared.profile(for: $0)?.listing }) {
        self.defaults = defaults; self.service = service
        storage = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(Storage.self, from: $0) } ?? Storage()
        if !storage.importedLegacy {
            let now = Date()
            var seen = Set<String>()
            for (offset, id) in (defaults.stringArray(forKey: "savedListingIDs") ?? []).enumerated() {
                let listing = (cachedListing(id) ?? Listing(id: id, cardIndex: 0, capturedAt: now)).canonicalized
                guard seen.insert(listing.id).inserted else { continue }
                storage.guest.entries.append(SavedListingEntry(listing: listing, savedAt: now.addingTimeInterval(-Double(offset) / 1000)))
            }
            storage.importedLegacy = true
        }
        entries = storage.guest.entries
        index = Set(ids)
        persist()
        defaults.removeObject(forKey: "savedListingIDs")
    }

    func contains(_ id: String) -> Bool { index.contains(id) }
    func contains(_ listing: Listing) -> Bool { contains(listing.canonicalized.id) || contains(listing.id) }

    func setAccount(_ id: String?) {
        guard id != userID else { return }
        persist()
        syncTask?.cancel(); retryTask?.cancel(); syncTask = nil; retryTask = nil
        generation = UUID(); userID = id; isSyncing = false; syncFailed = false
        let account = id.flatMap { storage.accounts[$0] } ?? (id == nil ? storage.guest : Account())
        entries = account.entries; pending = account.pending; rejected = account.rejected; failedSaves = account.failedSaves
        if id != nil {
            for entry in storage.guest.entries where !entries.contains(where: { $0.listing.id == entry.listing.id }) && !pending.contains(where: { $0.listingID == entry.listing.id }) {
                entries.append(entry)
                enqueue(entry.listing, saved: true, savedAt: entry.savedAt)
            }
            // Guest ownership and account data are committed in the same value.
            storage.guest = Account()
        }
        publish(); persist(); synchronize()
    }

    func toggle(_ listing: Listing) {
        let value = listing.canonicalized
        let saving = !contains(listing)
        guard !saving || value.hasSaveMetadata else { return }
        entries.removeAll { $0.listing.id == value.id || $0.listing.id == listing.id }
        let now = Date()
        if saving { entries.insert(SavedListingEntry(listing: value, savedAt: now), at: 0) }
        rejected.remove(value.id)
        failedSaves.remove(value.id)
        enqueue(value, saved: saving, savedAt: saving ? now : nil)
        publish(); persist(); synchronize()
    }

    /// Refreshes never recreate bookmarks removed on another device.
    func refresh(_ listing: Listing) {
        let value = listing.canonicalized
        guard let position = entries.firstIndex(where: { $0.listing.id == listing.id || $0.listing.id == value.id }) else { return }
        let old = entries[position]
        guard old.listing != value || failedSaves.contains(value.id) else { return }
        entries[position].listing = value
        let needsSave = !old.listing.hasSaveMetadata || failedSaves.contains(value.id)
        rejected.remove(value.id)
        failedSaves.remove(value.id)
        enqueue(value, saved: needsSave ? true : nil, savedAt: needsSave ? old.savedAt : nil)
        publish(); persist(); synchronize()
    }

    private func enqueue(_ listing: Listing, saved: Bool?, savedAt: Date?) {
        guard userID != nil, listing.facebookListingID != nil else { return }
        guard saved == false || listing.hasSaveMetadata else { return }
        if let change = try? SavedListingMutation(listing: listing, saved: saved, savedAt: savedAt) { pending.append(change) }
    }

    private func publish() {
        entries.sort { $0.savedAt == $1.savedAt ? $0.listing.id < $1.listing.id : $0.savedAt > $1.savedAt }
        var seen = Set<String>()
        entries = entries.filter { seen.insert($0.listing.id).inserted }
        index = seen
    }

    func synchronize() {
        guard syncTask == nil, let userID, let service else { return }
        retryTask?.cancel(); retryTask = nil
        let generation = generation
        isSyncing = true
        syncTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation { self.syncTask = nil; self.isSyncing = false } }
            do {
                repeat {
                    while !self.pending.isEmpty {
                        try Task.checkCancellation()
                        let batch = Array(self.pending.prefix(50))
                        let results = try await service.apply(batch, userID: userID)
                        guard self.generation == generation else { return }
                        for change in batch {
                            guard let error = results[change.id] else { throw APIError.network }
                            if !error.isEmpty {
                                self.rejected.insert(change.listingID)
                                if change.savesListing { self.failedSaves.insert(change.listingID) }
                            } else if change.changesSavedState || !self.failedSaves.contains(change.listingID) {
                                self.rejected.remove(change.listingID)
                                self.failedSaves.remove(change.listingID)
                            }
                            self.pending.removeAll { $0.id == change.id }
                        }
                        self.persist()
                    }
                    let remote = try await service.list(userID: userID)
                    guard self.generation == generation else { return }
                    let protectedIDs = Set(self.pending.map(\.listingID)).union(self.rejected)
                    let remoteIDs = Set(remote.map { $0.listing.id })
                    let local = self.entries.filter {
                        protectedIDs.contains($0.listing.id)
                            || (!$0.listing.hasSaveMetadata && !remoteIDs.contains($0.listing.id))
                    }
                    self.entries = remote.filter { !protectedIDs.contains($0.listing.id) } + local
                    self.publish(); self.syncFailed = false; self.persist()
                } while !self.pending.isEmpty
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

    func deleteAccount(_ id: String) {
        if userID == id { setAccount(nil) }
        storage.accounts.removeValue(forKey: id)
        persist()
    }

    private func persist() {
        let account = Account(entries: entries, pending: pending, rejected: rejected, failedSaves: failedSaves)
        if let userID { storage.accounts[userID] = account } else { storage.guest = account }
        if let data = try? JSONEncoder().encode(storage) { defaults.set(data, forKey: Self.key) }
    }
}
