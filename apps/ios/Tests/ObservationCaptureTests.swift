import Foundation
import OpenMarketProtos
import XCTest
@testable import OpenMarket

/// What the extractors read, as the server will receive it.
///
/// These assert the schema's own rules before a round trip does. A card the
/// server refuses at the door costs a request to find out about, and the rules
/// are cheap to check here: eight-digit ids, a present key, and no field
/// asserted that the surface did not carry.
final class ObservationCaptureTests: XCTestCase {

    private func payload(
        id: String = "1054280080442808",
        photoURL: String? = "https://scontent.example/v/t45/729964685_1105285382678938_1161471387555069882_n.jpg",
        isSold: Bool? = nil,
        isPending: Bool? = nil,
        isLive: Bool? = nil,
        priceAmount: String? = "40.00",
        strikethroughAmount: String? = nil
    ) -> PayloadListing {
        PayloadListing(
            id: id,
            title: "Solid oak six-drawer dresser",
            creationTime: 1_756_000_000,
            priceAmount: priceAmount,
            priceFormatted: "$40",
            strikethroughAmount: strikethroughAmount,
            strikethroughFormatted: strikethroughAmount == nil ? nil : "$60",
            photoURL: photoURL,
            photoID: "999",
            city: "San Francisco",
            state: "CA",
            cityPageID: "112604772073309",
            deliveryTypes: ["IN_PERSON", "SHIPPING_ONSITE"],
            isSold: isSold,
            isPending: isPending,
            isLive: isLive,
            categoryID: "807311116002614",
            createdWithSellerApp: nil
        )
    }

    func testPayloadCardCarriesBothAliases() throws {
        let observation = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: "USD"))
        let search = observation.search

        XCTAssertEqual(search.key.facebookListingID, "1054280080442808")
        // The fbcdn filename's middle group, which is what a mobile card has
        // before it is opened — and not `photoID`, which is a different number.
        XCTAssertEqual(search.key.coverPhotoFbid, "1105285382678938")
        XCTAssertEqual(search.title, "Solid oak six-drawer dresser")
        XCTAssertEqual(search.price.amountDecimal, "40.00")
        XCTAssertEqual(search.deliveryTypes, ["IN_PERSON", "SHIPPING_ONSITE"])
        XCTAssertEqual(search.listingLocation.city, "San Francisco")
        XCTAssertEqual(search.listingLocation.facebookPlaceID, "112604772073309")
        XCTAssertTrue(search.hasListedAt)
    }

    /// `listing_price` publishes no currency, so the code has to come from the
    /// page and be stamped on every card it produced. Without it the decimal is
    /// a string the server cannot scale.
    func testPageCurrencyIsStampedOnTheCard() throws {
        let observation = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: "CAD"))
        XCTAssertEqual(observation.search.price.currencyCode, "CAD")
        XCTAssertEqual(observation.search.price.amountDecimal, "40.00")
        XCTAssertEqual(observation.search.price.formattedAmount, "$40")

        let unpriced = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: nil))
        XCTAssertFalse(unpriced.search.price.hasCurrencyCode)
    }

    /// Normalised, and refused when it is not three letters. The schema takes
    /// exactly three, and failing the card at the server for a page-level value
    /// the card had no say in helps nobody.
    func testCurrencyCodeIsNormalisedAndShapeChecked() throws {
        let padded = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: "usd "))
        XCTAssertEqual(padded.search.price.currencyCode, "USD")

        for bad in ["US", "DOLLAR", "US1", ""] {
            let observation = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: bad))
            XCTAssertFalse(observation.search.price.hasCurrencyCode, "accepted \(bad)")
        }
    }

    /// The strikethrough carries a decimal of its own, so a previous price is a
    /// number rather than only a rendered string.
    func testStrikethroughDecimalIsSent() throws {
        let observation = try XCTUnwrap(
            ObservationCapture.observation(payload: payload(strikethroughAmount: "60.00"), currency: "USD")
        )
        XCTAssertEqual(observation.search.price.previousAmountDecimal, "60.00")
        XCTAssertEqual(observation.search.price.previousFormattedAmount, "$60")
    }

    /// Absent, true and false are three answers. A payload that said nothing
    /// about sold state must not arrive asserting anything about it.
    func testAvailabilityIsOnlySentWhenObserved() throws {
        let silent = try XCTUnwrap(ObservationCapture.observation(payload: payload(), currency: "USD"))
        XCTAssertFalse(silent.search.hasAvailability)

        let spoke = try XCTUnwrap(ObservationCapture.observation(payload: payload(isSold: false, isPending: false, isLive: true), currency: "USD"))
        XCTAssertTrue(spoke.search.hasAvailability)
        XCTAssertFalse(spoke.search.availability.sold)
        XCTAssertFalse(spoke.search.availability.pending)
        XCTAssertTrue(spoke.search.availability.live)
    }

    /// A card with neither alias is not an observation. The server refuses it,
    /// so sending it spends a round trip to be told what is knowable here.
    func testCardWithNoKeyIsNotAnObservation() {
        XCTAssertNil(ObservationCapture.observation(payload: payload(id: "12", photoURL: nil), currency: "USD"))
    }

    func testListingIDIsReadFromACanonicalItemURL() {
        XCTAssertEqual(
            ObservationCapture.facebookListingID(from: URL(string: "https://www.facebook.com/marketplace/item/1054280080442808/")),
            "1054280080442808"
        )
        XCTAssertNil(ObservationCapture.facebookListingID(from: URL(string: "https://www.facebook.com/marketplace/sanfrancisco/")))
        XCTAssertNil(ObservationCapture.facebookListingID(from: nil))
    }
}
