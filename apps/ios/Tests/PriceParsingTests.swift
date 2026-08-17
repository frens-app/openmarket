import XCTest
@testable import OpenMarket

final class PriceParsingTests: XCTestCase {
    func testTorontoDiscoverLabelKeepsCanadianPriceOutOfTitle() throws {
        let raw = DesktopRawCard(
            id: "2481576969000428",
            label: "Snowblower, CA$52, Toronto, ON, listing 2481576969000428",
            imageURL: "",
            text: "CA$52\nSnowblower\nToronto, ON",
            lines: ["CA$52", "Snowblower", "Toronto, ON"]
        )

        let listing = try XCTUnwrap(DesktopCardParser.parse(raw, cardIndex: 0))

        XCTAssertEqual(listing.priceText, "CA$52")
        XCTAssertEqual(listing.title, "Snowblower")
        XCTAssertEqual(listing.locationText, "Toronto, ON")
    }

    func testTorontoRenderedLinesRecognizeCanadianPrice() throws {
        let raw = DesktopRawCard(
            id: "1070101229289302",
            label: "",
            imageURL: "",
            text: "CA$6,700\n2014 Dodge Ram big horn\nMississauga, ON",
            lines: ["CA$6,700", "2014 Dodge Ram big horn", "Mississauga, ON"]
        )

        let listing = try XCTUnwrap(DesktopCardParser.parse(raw, cardIndex: 0))

        XCTAssertEqual(listing.priceText, "CA$6,700")
        XCTAssertEqual(listing.title, "2014 Dodge Ram big horn")
        XCTAssertEqual(listing.locationText, "Mississauga, ON")
    }

    func testCanadianWebLiteLabelParsesPrice() throws {
        let parsed = try XCTUnwrap(CardLabel.parse(
            "Snowblower for sale - Used - Good - CA$52 in Toronto, ON"
        ))

        XCTAssertEqual(parsed.priceText, "CA$52")
        XCTAssertEqual(parsed.title, "Snowblower")
        XCTAssertEqual(parsed.locationText, "Toronto, ON")
    }

    func testJoinedCanadianMarkdownPricesAreSeparated() throws {
        let prices = try XCTUnwrap(PriceRun.split("CA$50CA$60"))

        XCTAssertEqual(prices.current, "CA$50")
        XCTAssertEqual(prices.original, "CA$60")
    }

    func testShortTitleEndingInDigitIsNotAPrice() {
        XCTAssertFalse(PriceRun.isPrice("Desk1"))
    }

    func testOtherDefaultPhoneMarketsUseTheirDeclaredPriceFormats() {
        XCTAssertTrue(PriceRun.isPrice("£40"))
        XCTAssertTrue(PriceRun.isPrice("€15"))
        XCTAssertTrue(PriceRun.isPrice("A$80"))
        XCTAssertTrue(PriceRun.isPrice("AU$80"))
        XCTAssertTrue(PriceRun.isPrice("NZ$90"))
    }
}
