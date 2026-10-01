import Foundation
import OpenMarketProtos
import XCTest
@testable import OpenMarket

final class ObservationBatchTests: XCTestCase {

    func testShapeFingerprintSeparatesDifferentKeySets() {
        let a = ObservationBatch.shapeFingerprint(["is_sold", "listing_price"])
        let b = ObservationBatch.shapeFingerprint(["is_sold", "listing_price"])
        let c = ObservationBatch.shapeFingerprint(["is_sold", "is_pending", "listing_price"])

        XCTAssertEqual(a, b, "the same page shape must produce the same digest")
        XCTAssertNotEqual(a, c, "a new key is the change this exists to notice")
        XCTAssertNil(ObservationBatch.shapeFingerprint([]), "no payload is not a shape")
    }

    /// Joining without a separator would let ["ab", "c"] and ["a", "bc"] hash
    /// the same, which is a Facebook change the alarm would sleep through.
    func testShapeFingerprintCannotBeConfusedByConcatenation() {
        XCTAssertNotEqual(
            ObservationBatch.shapeFingerprint(["ab", "c"]),
            ObservationBatch.shapeFingerprint(["a", "bc"])
        )
    }
}

extension ObservationBatchTests {

    private func payloadCard(id: String, photoFBID: String) -> PayloadListing {
        PayloadListing(
            id: id, title: "Wooden dresser", creationTime: 1_756_000_000,
            priceAmount: "150.00", priceFormatted: "$150",
            strikethroughAmount: nil, strikethroughFormatted: nil,
            photoURL: "https://scontent.example/v/t39/764800597_\(photoFBID)_5159691677258832564_n.jpg",
            photoID: nil, city: "San Francisco", state: "CA", cityPageID: nil,
            deliveryTypes: [], isSold: nil, isPending: nil, isLive: nil,
            categoryID: nil, createdWithSellerApp: nil
        )
    }

    private func domCard(id: String, photoFBID: String) -> Listing {
        Listing(
            id: "p:\(photoFBID)", title: "Wooden dresser", priceText: "$150",
            originalPriceText: nil, locationText: "San Francisco, CA", conditionText: nil,
            fulfillment: nil,
            thumbnailURL: URL(string: "https://scontent.example/v/t39/764800597_\(photoFBID)_5159691677258832564_n.jpg"),
            itemURL: URL(string: "https://www.facebook.com/marketplace/item/\(id)/"),
            badgeText: nil, cardIndex: 0, detail: nil, capturedAt: Date()
        )
    }

    /// The rendered cards include the ones the payload already covered, so a
    /// naive batch sends each of those listings twice. Two cards claiming one
    /// listing is the signature of an extractor reading a neighbour's fields,
    /// and the server refuses both — which turns a working search into a batch
    /// that merges nothing.
    func testPayloadAndDOMCopiesOfOneListingAreSentOnce() throws {
        let request = try XCTUnwrap(ObservationBatch.feed(
            payload: [payloadCard(id: "1550206205946897", photoFBID: "1095213896513326")],
            cards: [
                domCard(id: "1550206205946897", photoFBID: "1095213896513326"),
                domCard(id: "1550206205946898", photoFBID: "1095213896513327"),
            ],
            route: .search,
            session: .authed,
            currency: "USD",
            cardsSeen: 2,
            dropReasons: [],
            shapeKeys: []
        ))

        XCTAssertEqual(request.observations.count, 2, "the duplicate must be dropped, the new card kept")

        // The payload's copy is the one kept: it carries an exact listed_at that
        // the rendered card has no way to know.
        let first = request.observations[0].search
        XCTAssertEqual(first.key.facebookListingID, "1550206205946897")
        XCTAssertTrue(first.hasListedAt)

        // Both sources contributed, so the batch is honestly labelled as both.
        XCTAssertEqual(request.context.extractionMethod, .hybrid)
    }

    /// A batch built only from rendered cards must not claim the payload's
    /// capabilities: the server ranks EMBEDDED_GRAPHQL above RENDERED_DOM for
    /// timestamps and availability, and a wrong label is a wrong merge.
    func testMethodDescribesWhatTheBatchActuallyContains() throws {
        let domOnly = try XCTUnwrap(ObservationBatch.feed(
            payload: [], cards: [domCard(id: "1550206205946898", photoFBID: "1095213896513327")],
            route: .search, session: .authed,
            currency: "USD", cardsSeen: 1, dropReasons: [], shapeKeys: []
        ))
        XCTAssertEqual(domOnly.context.extractionMethod, .renderedDom)

        let payloadOnly = try XCTUnwrap(ObservationBatch.feed(
            payload: [payloadCard(id: "1550206205946897", photoFBID: "1095213896513326")],
            cards: [], route: .search, session: .authed,
            currency: "USD", cardsSeen: 1, dropReasons: [], shapeKeys: []
        ))
        XCTAssertEqual(payloadOnly.context.extractionMethod, .embeddedGraphql)
    }

    func testAllDroppedPageStillProducesAHealthBatch() throws {
        let request = try XCTUnwrap(ObservationBatch.feed(
            payload: [], cards: [], route: .search, session: .authed,
            currency: "USD", cardsSeen: 15,
            dropReasons: ["card_unparseable"], shapeKeys: []
        ))

        XCTAssertTrue(request.observations.isEmpty)
        XCTAssertEqual(request.counts.cardsSeen, 15)
        XCTAssertEqual(request.counts.dropReasons, ["card_unparseable"])
    }

    func testDiscoverWindowUsesCoarseDOMContextOnly() throws {
        let request = try XCTUnwrap(ObservationBatch.feed(
            payload: [],
            cards: [domCard(id: "1550206205946898", photoFBID: "1095213896513327")],
            route: .discover,
            session: .authed,
            currency: nil,
            cardsSeen: 1,
            dropReasons: [],
            shapeKeys: []
        ))

        XCTAssertEqual(request.context.browserVariant, .desktop)
        XCTAssertEqual(request.context.pageRoute, .discover)
        XCTAssertEqual(request.context.extractionMethod, .renderedDom)
        XCTAssertEqual(request.context.facebookAuthenticationState, .signedIn)
        XCTAssertTrue(request.shapeFingerprint.isEmpty)

        let price = try XCTUnwrap(request.observations.first?.search.price)
        XCTAssertEqual(price.formattedAmount, "$150")
        XCTAssertTrue(price.amountDecimal.isEmpty)
        XCTAssertTrue(price.currencyCode.isEmpty)
    }

    func testAllDroppedDiscoverWindowStillProducesAHealthBatch() throws {
        let request = try XCTUnwrap(ObservationBatch.feed(
            payload: [], cards: [], route: .discover, session: .unauthed,
            currency: nil, cardsSeen: 3,
            dropReasons: ["card_unparseable"], shapeKeys: []
        ))

        XCTAssertTrue(request.observations.isEmpty)
        XCTAssertEqual(request.context.pageRoute, .discover)
        XCTAssertEqual(request.context.extractionMethod, .renderedDom)
        XCTAssertEqual(request.counts.cardsSeen, 3)
        XCTAssertEqual(request.counts.dropReasons, ["card_unparseable"])
    }

    func testPayloadAndRenderedPriceDisagreementDropsBothCopies() throws {
        var rendered = domCard(id: "1550206205946897", photoFBID: "1095213896513326")
        rendered.priceText = "$15"

        let request = try XCTUnwrap(ObservationBatch.feed(
            payload: [payloadCard(id: "1550206205946897", photoFBID: "1095213896513326")],
            cards: [rendered], route: .search, session: .authed,
            currency: "USD", cardsSeen: 1, dropReasons: [], shapeKeys: []
        ))

        XCTAssertTrue(request.observations.isEmpty)
        XCTAssertEqual(request.counts.dropReasons, ["price_disagreement"])
    }
}
