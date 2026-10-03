import XCTest
@testable import OpenMarket

final class SellerPageTests: XCTestCase {
    private func edge(_ id: String, sold: Bool = false, pending: Bool = false) -> [String: Any] {
        ["node": ["canonical_listing": ["id": id, "marketplace_listing_title": "Desk",
            "listing_price": ["amount": "40", "formatted_amount": "$40"],
            "is_sold": sold, "is_pending": pending, "is_live": false]]]
    }
    private func data(_ records: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: records) }
    private func initial(_ edges: [[String: Any]], root: String = "profile", id: String = "seller") -> [String: Any] {
        ["data": [root: ["id": id, "marketplace_listing_sets": ["edges": edges]]]]
    }
    private func info(root: String = "profile", more: Bool = false, cursor: Any = NSNull()) -> [String: Any] {
        ["path": [root, "marketplace_listing_sets"], "data": ["page_info": ["has_next_page": more, "end_cursor": cursor]]]
    }

    func testDeferredPageInfoAndStreamedEdges() throws {
        let records = [initial([edge("1")]),
            ["path": ["profile", "marketplace_listing_sets", "edges", 1], "data": edge("2", pending: true)],
            info(more: true, cursor: "next")]
        let result = try SellerGraphQLDecoder.decode(data(records), rootKey: "profile")
        XCTAssertEqual(result.items.map(\.id), ["fb:1", "fb:2"])
        XCTAssertNil(result.items[0].badgeText, "is_live alone is not an availability status")
        XCTAssertEqual(result.items[1].badgeText, "Pending")
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.cursor, "next")
    }

    func testFilteredInventoryStatusAndDuplicateIDs() throws {
        let result = try SellerGraphQLDecoder.decode(data([initial([edge("1", sold: true), edge("1", sold: true), edge("2")], root: "node"), info(root: "node")]), rootKey: "node", expectedID: "seller", unavailableInventory: true)
        XCTAssertEqual(result.items.map(\.badgeText), ["Sold", "Out of stock"])
        XCTAssertFalse(result.hasMore)
    }

    func testWrongSellerAndUnrelatedPatchesAreRejected() throws {
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([initial([], root: "node"), info(root: "node")]), rootKey: "node", expectedID: "another"))
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([initial([]), info(), ["path": ["viewer", "recommendations"], "data": [:]]]), rootKey: "profile"))
    }

    func testIncompleteInventoryIsNotReportedAsEmptyOrExhausted() throws {
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([initial([])]), rootKey: "profile"))
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([initial([]), info(more: true)]), rootKey: "profile"))
        let empty = try SellerGraphQLDecoder.decode(data([initial([]), info()]), rootKey: "profile")
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertFalse(empty.hasMore)
    }

    func testLateErrorsAndAuthenticationAreNotPartialSuccess() throws {
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([initial([edge("1")]), info(), ["errors": [["code": 1675002, "message": "Unauthorized logged out query."]]]]), rootKey: "profile")) { error in
            guard case SellerInventoryError.signInRequired = error else { return XCTFail("Wrong error: \(error)") }
        }
        XCTAssertThrowsError(try SellerGraphQLDecoder.decode(data([["errors": [["message": "Too many requests"]]]]), rootKey: "node")) { error in
            XCTAssertEqual(error as? GraphQLFeedError, .blocked)
        }
    }
}
