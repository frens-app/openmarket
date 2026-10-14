import Foundation
import OpenMarketProtos
import XCTest
@testable import OpenMarket

@MainActor
final class SellerSyncTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "SellerSyncTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
    private func seller(_ id: String = "123") -> SellerProfile {
        SellerProfile(detail: ListingDetail(sellerProfileID: id, sellerName: "Sam"))!
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Seller sync did not reach expected state")
    }

    func testLegacyFollowsMigrateOnceAndAccountsStaySeparate() async throws {
        let defaults = try defaults()
        let guest = FollowedSellers(defaults: defaults)
        guest.toggle(seller())
        let service = FakeSellerSyncService()
        let store = FollowedSellers(defaults: defaults, service: service)
        store.setAccount("A")
        try await waitUntil { !store.isSyncing }
        XCTAssertEqual(service.remote["A"]?["123"], seller())
        XCTAssertNil(defaults.data(forKey: "followedSellerProfiles.v1"))
        store.setAccount("B")
        XCTAssertTrue(store.profiles.isEmpty)
        try await waitUntil { !store.isSyncing }
        XCTAssertTrue(service.remote["B", default: [:]].isEmpty)
        store.setAccount("A")
        XCTAssertEqual(store.profiles, [seller()])
        try await waitUntil { !store.isSyncing }
        store.setAccount(nil)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testOfflineUnfollowSurvivesRelaunchAndRetries() async throws {
        let defaults = try defaults()
        let service = FakeSellerSyncService()
        service.remote["A"] = ["123": seller()]
        let store = FollowedSellers(defaults: defaults, service: service)
        store.setAccount("A")
        try await waitUntil { !store.isSyncing }
        service.fail = true
        store.toggle(seller())
        XCTAssertTrue(store.profiles.isEmpty)
        try await waitUntil { store.syncFailed && !store.isSyncing }
        store.setAccount(nil)
        let restored = FollowedSellers(defaults: defaults, service: service)
        restored.setAccount("A")
        XCTAssertTrue(restored.profiles.isEmpty)
        try await waitUntil { restored.syncFailed && !restored.isSyncing }
        service.fail = false
        restored.synchronize()
        try await waitUntil { !restored.isSyncing }
        XCTAssertFalse(restored.syncFailed)
        XCTAssertTrue(service.remote["A", default: [:]].isEmpty)
        XCTAssertTrue(restored.profiles.isEmpty)
        restored.setAccount(nil)
    }

    func testRapidToggleDuringFollowRequestKeepsFinalIntent() async throws {
        let service = FakeSellerSyncService()
        let store = FollowedSellers(defaults: try defaults(), service: service)
        store.setAccount("A")
        try await waitUntil { !store.isSyncing }
        service.pauseNextFollow = true
        store.toggle(seller())
        XCTAssertTrue(store.contains("123"))
        try await waitUntil { service.followContinuation != nil }
        store.toggle(seller())
        XCTAssertFalse(store.contains("123"))
        service.releaseFollow()
        try await waitUntil { !store.isSyncing }
        XCTAssertEqual(service.followCalls.map(\.following), [true, false])
        XCTAssertTrue(service.remote["A", default: [:]].isEmpty)
        XCTAssertFalse(store.contains("123"))
        store.setAccount(nil)
    }

    func testInFlightReadCannotOverwriteNewLocalFollow() async throws {
        let service = FakeSellerSyncService()
        service.pauseNextList = true
        let store = FollowedSellers(defaults: try defaults(), service: service)
        store.setAccount("A")
        try await waitUntil { service.listContinuation != nil }
        store.toggle(seller())
        service.releaseList()
        try await waitUntil { !store.isSyncing }
        XCTAssertEqual(store.profiles, [seller()])
        XCTAssertEqual(service.remote["A"]?["123"], seller())
        store.setAccount(nil)
    }

    func testOldAccountResponseCannotPolluteNewAccount() async throws {
        let service = FakeSellerSyncService()
        service.remote["A"] = ["123": seller()]
        service.remote["B"] = ["456": seller("456")]
        service.pauseNextList = true
        let store = FollowedSellers(defaults: try defaults(), service: service)
        store.setAccount("A")
        try await waitUntil { service.listContinuation != nil }
        store.setAccount("B")
        try await waitUntil { !store.isSyncing }
        service.releaseList()
        await Task.yield()
        XCTAssertEqual(store.profiles, [seller("456")])
        XCTAssertTrue(service.followCalls.isEmpty)
        store.setAccount(nil)
    }

    func testObservedSellerUploadsWithoutFollowingAndPreservesOptionalValues() async throws {
        let service = FakeSellerSyncService()
        let store = FollowedSellers(defaults: try defaults(), service: service)
        store.setAccount("A")
        try await waitUntil { !store.isSyncing }
        var profile = seller()
        profile.rating = 4.8
        profile.ratingCount = 0
        profile.isHighlyRated = false
        store.refresh(profile)
        try await waitUntil { !store.isSyncing }
        store.refresh(seller())
        try await waitUntil { !store.isSyncing }
        XCTAssertEqual(service.uploads, [profile])
        XCTAssertTrue(store.profiles.isEmpty)
        let wire = profile.serverProfile
        XCTAssertTrue(wire.hasRatingCount)
        XCTAssertTrue(wire.hasIsHighlyRated)
        XCTAssertEqual(SellerProfile(serverProfile: wire), profile)
        let partial = seller().serverProfile
        XCTAssertFalse(partial.hasRating)
        XCTAssertFalse(partial.hasRatingCount)
        store.setAccount(nil)
    }
}

@MainActor
private final class FakeSellerSyncService: SellerSyncService {
    struct FollowCall { let userID: String; let following: Bool }
    var remote: [String: [String: SellerProfile]] = [:]
    var followCalls: [FollowCall] = []
    var uploads: [SellerProfile] = []
    var fail = false
    var pauseNextFollow = false
    var pauseNextList = false
    var followContinuation: CheckedContinuation<Void, Never>?
    var listContinuation: CheckedContinuation<Void, Never>?
    func releaseFollow() { followContinuation?.resume(); followContinuation = nil }
    func releaseList() { listContinuation?.resume(); listContinuation = nil }
    func upsert(_ profile: SellerProfile, userID: String) async throws {
        if fail { throw URLError(.notConnectedToInternet) }
        uploads.append(profile)
    }
    func setFollow(_ profile: SellerProfile, following: Bool, userID: String) async throws {
        if fail { throw URLError(.notConnectedToInternet) }
        followCalls.append(FollowCall(userID: userID, following: following))
        if pauseNextFollow {
            pauseNextFollow = false
            await withCheckedContinuation { followContinuation = $0 }
        }
        if following { remote[userID, default: [:]][profile.id] = profile }
        else { remote[userID, default: [:]].removeValue(forKey: profile.id) }
    }
    func listFollows(userID: String) async throws -> [SellerProfile] {
        if fail { throw URLError(.notConnectedToInternet) }
        let snapshot = Array(remote[userID, default: [:]].values)
        if pauseNextList {
            pauseNextList = false
            await withCheckedContinuation { listContinuation = $0 }
        }
        return snapshot
    }
}
