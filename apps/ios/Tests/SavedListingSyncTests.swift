import Foundation
import OpenMarketProtos
import XCTest
@testable import OpenMarket

@MainActor
final class SavedListingSyncTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let name = "SavedListingSyncTests.\(UUID())"
        let value = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { value.removePersistentDomain(forName: name) }
        return value
    }
    private func listing(_ id: String = "123") -> Listing {
        Listing(id: "fb:\(id)", title: "Desk", priceText: "Free", cardIndex: 0, capturedAt: Date())
    }
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Saved listing sync did not settle")
    }
    private func settled(_ store: SavedListings) async throws { try await waitUntil { !store.isSyncing } }

    func testAlertSaveAttributionPersistsLocallyAndRetriesWithTheSave() async throws {
        let service = FakeSavedListingService(), defaults = try defaults()
        let store = SavedListings(defaults: defaults, service: service)
        store.setAccount("A"); try await settled(store)
        service.loseResponse = true
        let context = AlertSaveContext(alertID: UUID().uuidString, notificationID: UUID().uuidString, source: "notification")
        store.toggle(listing(), alertContext: context)
        XCTAssertTrue(store.contains(listing()))
        try await settled(store)
        XCTAssertTrue(store.syncFailed)
        let first = try XCTUnwrap(service.calls.first)
        store.setAccount(nil)
        let restored = SavedListings(defaults: defaults, service: service, cachedListing: { _ in nil })
        restored.setAccount("A")
        XCTAssertTrue(restored.contains(listing()))
        try await settled(restored)
        XCTAssertEqual(service.calls.count, 2)
        XCTAssertEqual(service.calls[1], first)
        let wire = try SavedListingChange(serializedBytes: first.data)
        XCTAssertEqual(wire.alertSource.alertID, context.alertID)
        XCTAssertEqual(wire.alertSource.notificationID, context.notificationID)
        XCTAssertEqual(wire.alertSource.source, "notification")
        XCTAssertTrue(wire.saved)
        XCTAssertEqual(restored.entries.first?.listing.title, "Desk")
        restored.toggle(listing(), alertContext: context)
        try await settled(restored)
        let removed = try SavedListingChange(serializedBytes: XCTUnwrap(service.calls.last).data)
        XCTAssertFalse(removed.saved)
        XCTAssertFalse(removed.hasAlertSource)
        restored.setAccount(nil)
    }

    func testStructuredPricesSurviveWireStorageAndShoppingRoundTrips() throws {
        for currency in MarketCurrency.all {
            var item = listing()
            item.priceText = currency.sourcePrice(Decimal(string: "1234.56")!)
            item.originalPriceText = currency.sourcePrice(Decimal(string: "1500.99")!)
            item.priceAmountDecimal = "1234.56"
            item.priceCurrencyCode = currency.code
            item.originalPriceAmountDecimal = "1500.99"
            let local = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(item))
            let mutation = try SavedListingMutation(listing: local, saved: true, savedAt: Date())
            let wire = try SavedListingChange(serializedBytes: mutation.data)
            let json = try wire.snapshot.jsonUTF8Data()
            let restored = try SavedListingSnapshot(jsonUTF8Data: json).listing
            XCTAssertEqual(restored.exactPriceAmount, "1234.56", currency.code)
            XCTAssertEqual(restored.currencyCode, currency.code)
            XCTAssertEqual(restored.exactOriginalPriceAmount, "1500.99")
            XCTAssertEqual(restored.priceText, item.priceText)
            XCTAssertEqual(ShoppingListing(restored, source: "test").parsed.currencyCode, currency.code)
            XCTAssertEqual(ShoppingListing(restored, source: "test").parsed.exactPriceAmount, "1234.56")
        }
    }

    func testLegacyAndAmbiguousPricesDoNotInventCurrencyOrExactRangeAmounts() throws {
        for (text, amount, code) in [("CA$1,234.56", "1234.56", "CAD"),
                                      ("1.234,56 €", "1234.56", "EUR"),
                                      ("$10.50", "10.5", nil), ("Free", "0", nil),
                                      ("$10 - $20", nil, nil), ("unknown", nil, nil)] {
            var item = listing()
            item.priceText = text
            let snapshot = item.savedSnapshot
            XCTAssertEqual(snapshot.hasPriceAmountDecimal ? snapshot.priceAmountDecimal : nil, amount)
            XCTAssertEqual(snapshot.hasPriceCurrencyCode ? snapshot.priceCurrencyCode : nil, code)
        }
        let old = try SavedListingSnapshot(jsonString: #"{"facebookListingId":"123","priceText":"$10.50"}"#).listing
        XCTAssertNil(old.currencyCode)
        XCTAssertEqual(old.exactPriceAmount, "10.5")
    }

    func testSourceUpdatesInvalidateStructuredAmounts() {
        var item = listing()
        item.priceText = "$10"
        item.priceAmountDecimal = "10.00"
        item.priceCurrencyCode = "CAD"
        item.priceText = "$12"
        XCTAssertNil(item.priceAmountDecimal)
        XCTAssertNil(item.priceCurrencyCode)
        XCTAssertEqual(item.savedSnapshot.priceAmountDecimal, "12")
        XCTAssertFalse(item.savedSnapshot.hasPriceCurrencyCode)
        XCTAssertNil(MarketplacePrice.canonicalAmount("12\n"))
        item.priceCurrencyCode = "CAD\n"
        XCTAssertNil(item.currencyCode)
    }

    func testLegacyImportResolvesURLsDeduplicatesAndClaimsOnce() async throws {
        let defaults = try defaults()
        defaults.set(["p:photo", "fb:123", "p:unresolved"], forKey: "savedListingIDs")
        var old = listing(); old.id = "p:photo"
        old.itemURL = URL(string: "https://www.facebook.com/marketplace/item/123/")
        let service = FakeSavedListingService()
        let store = SavedListings(defaults: defaults, service: service, cachedListing: { $0 == "p:photo" ? old : nil })
        XCTAssertEqual(store.ids, ["fb:123", "p:unresolved"])
        XCTAssertTrue(store.listings.allSatisfy { $0.cardIndex == -1 })
        store.setAccount("A")
        try await settled(store)
        XCTAssertEqual(service.remote["A"]?.count, 1)
        XCTAssertEqual(store.ids, ["fb:123", "p:unresolved"])
        store.setAccount("B")
        try await settled(store)
        XCTAssertTrue(store.isEmpty)
        store.setAccount(nil)
        let restored = SavedListings(defaults: defaults, service: service)
        restored.setAccount("A")
        try await settled(restored)
        XCTAssertEqual(restored.ids, ["fb:123", "p:unresolved"])
        restored.setAccount(nil)
    }

    func testOfflineRemovalSurvivesRelaunch() async throws {
        let defaults = try defaults(), service = FakeSavedListingService()
        let item = listing()
        service.remote["A"] = [item.id: SavedListingEntry(listing: item, savedAt: Date())]
        let store = SavedListings(defaults: defaults, service: service)
        store.setAccount("A"); try await settled(store)
        service.fail = true
        store.toggle(item); try await settled(store)
        XCTAssertTrue(store.isEmpty); XCTAssertTrue(store.syncFailed)
        store.setAccount(nil)
        let restored = SavedListings(defaults: defaults, service: service)
        restored.setAccount("A"); try await settled(restored)
        XCTAssertTrue(restored.isEmpty)
        service.fail = false
        restored.synchronize(); try await settled(restored)
        XCTAssertTrue(service.remote["A", default: [:]].isEmpty)
        restored.setAccount(nil)
    }

    func testLegacySaveWithMissingCacheWaitsForRealMetadata() async throws {
        let defaults = try defaults(), service = FakeSavedListingService()
        defaults.set(["fb:123"], forKey: "savedListingIDs")
        let store = SavedListings(defaults: defaults, service: service, cachedListing: { _ in nil })
        store.setAccount("A"); try await settled(store)
        XCTAssertEqual(store.ids, ["fb:123"])
        XCTAssertTrue(service.calls.isEmpty)
        XCTAssertNil(store.listings.first?.title)
        store.refresh(listing()); try await settled(store)
        XCTAssertEqual(service.remote["A"]?["fb:123"]?.listing.title, "Desk")
        XCTAssertEqual(service.calls.count, 1)
        XCTAssertTrue(service.calls[0].savesListing)
        store.setAccount(nil)
    }

    func testLostAcknowledgementDoesNotResurrectRemoteRemoval() async throws {
        let service = FakeSavedListingService(), defaults = try defaults()
        let store = SavedListings(defaults: defaults, service: service)
        store.setAccount("A"); try await settled(store)
        service.loseResponse = true
        store.toggle(listing()); try await settled(store)
        XCTAssertTrue(store.syncFailed)
        service.remote["A"] = [:] // A different device removes it after commit.
        store.setAccount(nil)
        let restored = SavedListings(defaults: defaults, service: service)
        restored.setAccount("A"); try await settled(restored)
        XCTAssertTrue(restored.isEmpty)
        XCTAssertEqual(service.calls[0].id, service.calls[1].id)
        restored.setAccount(nil)
    }

    func testRapidToggleAndReadRacingSaveKeepLocalIntent() async throws {
        let service = FakeSavedListingService()
        let store = SavedListings(defaults: try defaults(), service: service)
        store.setAccount("A"); try await settled(store)
        service.pauseNextApply = true
        store.toggle(listing())
        try await waitUntil { service.applyContinuation != nil }
        store.toggle(listing())
        service.applyContinuation?.resume(); service.applyContinuation = nil
        try await settled(store)
        XCTAssertTrue(store.isEmpty)
        XCTAssertTrue(service.remote["A", default: [:]].isEmpty)
        service.pauseNextList = true
        store.synchronize()
        try await waitUntil { service.listContinuation != nil }
        store.toggle(listing("456"))
        service.listContinuation?.resume(); service.listContinuation = nil
        try await settled(store)
        XCTAssertEqual(store.ids, ["fb:456"])
        store.setAccount(nil)
    }

    func testAccountSwitchIgnoresOldResponseAndRestoresWithoutCache() async throws {
        let service = FakeSavedListingService()
        service.remote["A"] = ["fb:123": SavedListingEntry(listing: listing(), savedAt: Date())]
        service.remote["B"] = ["fb:456": SavedListingEntry(listing: listing("456"), savedAt: Date())]
        service.pauseNextList = true
        let store = SavedListings(defaults: try defaults(), service: service, cachedListing: { _ in nil })
        store.setAccount("A")
        try await waitUntil { service.listContinuation != nil }
        store.setAccount("B"); try await settled(store)
        service.listContinuation?.resume(); service.listContinuation = nil
        await Task.yield()
        XCTAssertEqual(store.ids, ["fb:456"])
        XCTAssertEqual(store.listings.first?.title, "Desk")
        XCTAssertEqual(store.listings.first?.priceText, "Free")
        store.deleteAccount("B")
        XCTAssertTrue(store.isEmpty)
    }

    func testMetadataRefreshDoesNotRecreateBookmarkAndBadEntryDoesNotBlockOthers() async throws {
        let service = FakeSavedListingService()
        let store = SavedListings(defaults: try defaults(), service: service)
        store.toggle(listing("999")); store.toggle(listing())
        store.setAccount("A"); try await settled(store)
        XCTAssertTrue(store.contains("fb:999"))
        XCTAssertTrue(store.statusText?.contains("could not sync") == true)
        XCTAssertEqual(service.remote["A"]?.count, 1)
        service.remote["A"] = [:]
        var updated = listing(); updated.title = "New title"
        store.refresh(updated); try await settled(store)
        XCTAssertFalse(store.contains("fb:123"))
        XCTAssertTrue(service.remote["A", default: [:]].isEmpty)
        store.setAccount(nil)
    }

    func testListingIdentityAndSnapshotPreserveUnknownAndFalse() throws {
        let raw = Data(#"{"data":{"marketplace_search":{"feed_units":{"edges":[{"node":{"listing":{"id":"123","marketplace_listing_title":"Desk","primary_listing_photo":{"id":"555","image":{"uri":"https://example.com/1_9999999999999_3.jpg"}},"is_sold":false}}}],"page_info":{"has_next_page":false}}}}}"#.utf8)
        let payload = try XCTUnwrap(GraphQLFeedDecoder.decode(raw, kind: .search("desk")).listings.first)
        let card = payload.makeListing(cardIndex: 0)
        XCTAssertEqual(card.id, "fb:123")
        let snapshot = card.savedSnapshot
        XCTAssertTrue(snapshot.hasSold)
        XCTAssertFalse(snapshot.sold)
        XCTAssertFalse(snapshot.hasPending)
        XCTAssertEqual(snapshot.coverPhotoFbid, "9999999999999")
        XCTAssertEqual(snapshot.listing.id, "fb:123")
        XCTAssertTrue(snapshot.listing.savedSnapshot.hasSold)
        XCTAssertFalse(snapshot.listing.savedSnapshot.sold)
        XCTAssertNil(Listing.facebookListingID(from: URL(string: "https://evil.com/marketplace/item/123/")!))
    }

    func testLegacyCacheRemainsReadableByBothKeysWithoutLosingDetail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        var card = listing(); card.id = "p:photo"
        let url = URL(string: "https://www.facebook.com/marketplace/item/123/")!
        let profile = CachedProfile(card: card, detail: ListingDetail(description: "Solid oak"),
                                    itemURL: url, fetchedAt: Date(), usedAt: Date())
        try JSONEncoder().encode([card.id: profile]).write(to: directory.appendingPathComponent("profiles.json"))
        let cache = ListingCache(directory: directory, isSaved: { _ in false })
        XCTAssertEqual(cache.profile(for: "fb:123")?.listing?.id, "fb:123")
        XCTAssertEqual(cache.profile(for: "p:photo")?.listing?.id, "fb:123")
        cache.store(listing())
        XCTAssertEqual(cache.profileCount, 1)
        XCTAssertEqual(cache.profile(for: "fb:123")?.listing?.detail?.description, "Solid oak")
    }

    func testSnapshotIncludesDetailOnlyFieldsWithoutInventingFreshness() {
        var card = listing()
        let observed = card.capturedAt.addingTimeInterval(-3600)
        card.detailObservedAt = observed
        card.detail = ListingDetail(description: "Oak", conditionText: "Used - Good", locationText: "Toronto")
        card.detail?.fulfillment = Fulfillment(tokens: ["IN_PERSON"])
        let snapshot = card.savedSnapshot
        XCTAssertEqual(snapshot.conditionText, "Used - Good")
        XCTAssertEqual(snapshot.locationText, "Toronto")
        XCTAssertTrue(snapshot.inPerson)
        XCTAssertEqual(snapshot.cardObservedAt.date.timeIntervalSince1970, observed.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(snapshot.listing.detail?.description, "Oak")
    }
}

@MainActor
private final class FakeSavedListingService: SavedListingSyncService {
    var remote: [String: [String: SavedListingEntry]] = [:]
    var receipts = Set<String>()
    var calls: [SavedListingMutation] = []
    var fail = false
    var loseResponse = false
    var pauseNextApply = false
    var pauseNextList = false
    var applyContinuation: CheckedContinuation<Void, Never>?
    var listContinuation: CheckedContinuation<Void, Never>?

    func apply(_ changes: [SavedListingMutation], userID: String) async throws -> [String: String] {
        if fail { throw URLError(.notConnectedToInternet) }
        calls += changes
        if pauseNextApply { pauseNextApply = false; await withCheckedContinuation { applyContinuation = $0 } }
        var results: [String: String] = [:]
        for change in changes {
            let wire = try SavedListingChange(serializedBytes: change.data)
            results[change.id] = ""
            if wire.facebookListingID == "999" { results[change.id] = "Invalid snapshot"; continue }
            guard receipts.insert(userID + change.id).inserted else { continue }
            if wire.hasSaved {
                if wire.saved { remote[userID, default: [:]][change.listingID] = SavedListingEntry(listing: wire.snapshot.listing, savedAt: wire.savedAt.date) }
                else { remote[userID, default: [:]].removeValue(forKey: change.listingID) }
            } else if var old = remote[userID]?[change.listingID] {
                old.listing = wire.snapshot.listing
                remote[userID]?[change.listingID] = old
            }
        }
        if loseResponse { loseResponse = false; throw URLError(.networkConnectionLost) }
        return results
    }
    func list(userID: String) async throws -> [SavedListingEntry] {
        if fail { throw URLError(.notConnectedToInternet) }
        let snapshot = Array(remote[userID, default: [:]].values)
        if pauseNextList { pauseNextList = false; await withCheckedContinuation { listContinuation = $0 } }
        return snapshot
    }
}
