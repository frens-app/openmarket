import XCTest
@testable import OpenMarket

@MainActor
final class FollowedSellersTests: XCTestCase {
    func testFollowSurvivesRelaunchAndUnfollowRemovesProfile() throws {
        let suite = "FollowedSellersTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = try XCTUnwrap(SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "Sam Seller",
            sellerPhotoURL: URL(string: "https://example.com/seller.jpg"),
            sellerJoined: "Joined Facebook in 2012", sellerRating: 4.8, sellerRatingCount: 12, sellerIsHighlyRated: true)))
        let store = FollowedSellers(defaults: defaults)
        store.toggle(profile)
        let restored = FollowedSellers(defaults: defaults)
        XCTAssertEqual(restored.profiles, [profile])
        restored.toggle(profile)
        XCTAssertTrue(FollowedSellers(defaults: defaults).profiles.isEmpty)
    }

    func testRefreshDoesNotFollowOrDuplicateAndClearsStaleRating() throws {
        let suite = "FollowedSellersTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = try XCTUnwrap(SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "Sam",
            sellerRating: 4.8, sellerRatingCount: 12)))
        var updated = original
        updated.name = "Sam Seller"
        updated.rating = nil
        updated.ratingCount = nil
        let store = FollowedSellers(defaults: defaults)
        store.refresh(original)
        XCTAssertTrue(store.profiles.isEmpty)
        store.toggle(original)
        store.refresh(updated)
        XCTAssertEqual(FollowedSellers(defaults: defaults).profiles, [updated])
    }

    func testNamesCannotBeUsedAsIdentity() {
        XCTAssertNil(SellerProfile(detail: ListingDetail(sellerName: "Same Name")))
        XCTAssertNil(SellerProfile(detail: ListingDetail(sellerProfileID: "../invalid", sellerName: "Seller")))
        XCTAssertNil(SellerProfile(detail: ListingDetail(sellerProfileID: "123456789", sellerName: "  ")))
    }

    func testOldProfilesLoadAndPhotoRefreshSurvivesMissingPhoto() throws {
        let suite = "FollowedSellersTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data(#"[{"id":"123456789","name":"Sam"}]"#.utf8), forKey: "followedSellerProfiles.v1")
        let store = FollowedSellers(defaults: defaults)
        var profile = try XCTUnwrap(store.profiles.first)
        XCTAssertNil(profile.photoURL)
        profile.photoURL = URL(string: "https://example.com/fresh.jpg")
        store.refresh(profile)
        var withoutPhoto = profile
        withoutPhoto.photoURL = nil
        store.refresh(withoutPhoto)
        XCTAssertEqual(FollowedSellers(defaults: defaults).profiles, [profile])
    }

    func testPhotoURLRejectsNonWebAndMalformedValues() {
        for value in ["", "/relative.jpg", "file:///private/photo.jpg", "http://example.com/photo.jpg", "https://user:secret@example.com/photo.jpg"] {
            XCTAssertNil(SellerProfile.validatedPhotoURL(value))
        }
        XCTAssertNotNil(SellerProfile.validatedPhotoURL("https://example.com/photo.jpg"))
    }
}
