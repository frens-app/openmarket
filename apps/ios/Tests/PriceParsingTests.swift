import XCTest
@testable import OpenMarket

final class PriceParsingTests: XCTestCase {
    private struct MarketFixture {
        let countryCode: String
        let prefix: String
        let shortLocation: String
        let fullLocation: String

        var current: String { "\(prefix)12.50" }
        var original: String { "\(prefix)12.99" }
        var joinedMarkdown: String { current + original }
    }

    private let markets = [
        MarketFixture(countryCode: "GB", prefix: "£",
                      shortLocation: "London, UK", fullLocation: "London, United Kingdom"),
        MarketFixture(countryCode: "IE", prefix: "€",
                      shortLocation: "Dublin, IE", fullLocation: "Dublin, Ireland"),
        MarketFixture(countryCode: "AU", prefix: "A$",
                      shortLocation: "Sydney, NSW", fullLocation: "Sydney, Australia"),
        MarketFixture(countryCode: "NZ", prefix: "NZ$",
                      shortLocation: "Auckland, NZ", fullLocation: "Auckland, New Zealand"),
    ]

    func testSignedOutFirstPageRoutesKeepDiscountedDecimalPrices() throws {
        for market in markets {
            let payloadListing = payload(for: market).makeListing(cardIndex: 0)
            assertPrice(payloadListing, market: market, route: "\(market.countryCode) payload")

            let raw = DesktopRawCard(
                id: "1000000000000001",
                label: "Vintage desk, \(market.current), reduced from \(market.original), \(market.fullLocation), listing 1000000000000001",
                imageURL: "",
                text: "",
                lines: []
            )
            let labelListing = try XCTUnwrap(
                DesktopCardParser.parseLabel(raw, cardIndex: 0),
                "\(market.countryCode) desktop label"
            )
            assertPrice(labelListing, market: market, route: "\(market.countryCode) desktop label")
            XCTAssertEqual(labelListing.title, "Vintage desk")
            XCTAssertEqual(labelListing.locationText, market.fullLocation)
        }
    }

    func testSignedInPaginationRoutesKeepDiscountedDecimalPrices() throws {
        for market in markets {
            let raw = DesktopRawCard(
                id: "1000000000000002",
                label: "",
                imageURL: "",
                text: market.joinedMarkdown,
                lines: ["Price drop", market.joinedMarkdown, "Vintage desk", market.shortLocation]
            )
            let listing = try XCTUnwrap(
                DesktopCardParser.parseLines(raw, cardIndex: 0),
                "\(market.countryCode) rendered lines"
            )
            assertPrice(listing, market: market, route: "\(market.countryCode) rendered lines")
            XCTAssertEqual(listing.title, "Vintage desk")
            XCTAssertEqual(listing.locationText, market.shortLocation)
        }
    }

    func testWebLiteAccessibilityLabelsParseEveryMarket() throws {
        for market in markets {
            let parsed = try XCTUnwrap(CardLabel.parse(
                "Vintage desk for sale - Used - Good - \(market.current) in \(market.fullLocation)"
            ), "\(market.countryCode) WebLite label")

            XCTAssertEqual(parsed.priceText, market.current)
            XCTAssertEqual(parsed.title, "Vintage desk")
            XCTAssertEqual(parsed.conditionText, "Used - Good")
            XCTAssertEqual(parsed.locationText, market.fullLocation)
        }
    }

    func testWebLiteRenderedRunsParseEveryMarket() throws {
        for (index, market) in markets.enumerated() {
            let raw = FeedEngine.RawCard(
                index: index,
                actionId: nil,
                imageURL: nil,
                label: nil,
                texts: [market.joinedMarkdown, "Vintage desk", market.shortLocation],
                fullText: market.joinedMarkdown
            )
            let listing = try XCTUnwrap(
                CardParser.parse(raw),
                "\(market.countryCode) WebLite runs"
            )

            assertPrice(listing, market: market, route: "\(market.countryCode) WebLite runs")
            XCTAssertEqual(listing.title, "Vintage desk")
            XCTAssertEqual(listing.locationText, market.shortLocation)
        }
    }

    func testEveryExtractionRouteKeepsFreeListings() throws {
        for market in markets {
            let payloadListing = payload(for: market, current: "Free", includeOriginal: false)
                .makeListing(cardIndex: 0)
            XCTAssertEqual(payloadListing.priceText, "Free", "\(market.countryCode) payload")

            let desktopLabel = DesktopRawCard(
                id: "1000000000000003",
                label: "Vintage desk, FREE, \(market.fullLocation), listing 1000000000000003",
                imageURL: "",
                text: "",
                lines: []
            )
            XCTAssertEqual(
                try XCTUnwrap(DesktopCardParser.parseLabel(desktopLabel, cardIndex: 0)).priceText,
                "FREE",
                "\(market.countryCode) desktop label"
            )

            let desktopLines = DesktopRawCard(
                id: "1000000000000004",
                label: "",
                imageURL: "",
                text: "Free\nVintage desk\n\(market.shortLocation)",
                lines: ["Free", "Vintage desk", market.shortLocation]
            )
            XCTAssertEqual(
                try XCTUnwrap(DesktopCardParser.parseLines(desktopLines, cardIndex: 0)).priceText,
                "Free",
                "\(market.countryCode) rendered lines"
            )

            let cardLabel = try XCTUnwrap(CardLabel.parse(
                "Free Vintage desk for sale - Used - Good in \(market.fullLocation)"
            ))
            XCTAssertEqual(cardLabel.priceText, "Free", "\(market.countryCode) WebLite label")

            let webLiteRuns = FeedEngine.RawCard(
                index: 0,
                actionId: nil,
                imageURL: nil,
                label: nil,
                texts: ["FREE", "Vintage desk", market.shortLocation],
                fullText: "FREE"
            )
            XCTAssertEqual(
                try XCTUnwrap(CardParser.parse(webLiteRuns)).priceText,
                "FREE",
                "\(market.countryCode) WebLite runs"
            )
        }
    }

    func testJoinedMarkdownComparesDecimalAmountsWithoutTruncating() throws {
        for market in markets {
            let prices = try XCTUnwrap(
                PriceRun.split(market.joinedMarkdown),
                market.countryCode
            )
            XCTAssertEqual(prices.current, market.current)
            XCTAssertEqual(prices.original, market.original)
        }
    }

    func testTorontoFormatsRemainSupported() throws {
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
        XCTAssertEqual(PriceRun.split("CA$50CA$60")?.current, "CA$50")
    }

    func testTorontoRenderedLinesRemainSupported() throws {
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

    func testCanadianWebLiteLabelRemainsSupported() throws {
        let parsed = try XCTUnwrap(CardLabel.parse(
            "Snowblower for sale - Used - Good - CA$52 in Toronto, ON"
        ))

        XCTAssertEqual(parsed.priceText, "CA$52")
        XCTAssertEqual(parsed.title, "Snowblower")
        XCTAssertEqual(parsed.locationText, "Toronto, ON")
    }

    func testNonPriceTextAndUnsupportedCurrenciesAreRejected() {
        XCTAssertFalse(PriceRun.isPrice("Desk1"))
        XCTAssertFalse(PriceRun.isPrice("¥25"))
        XCTAssertFalse(PriceRun.isPrice("₹25"))
        XCTAssertFalse(PriceRun.isPrice("₩25"))
    }

    private func payload(
        for market: MarketFixture,
        current: String? = nil,
        includeOriginal: Bool = true
    ) -> PayloadListing {
        PayloadListing(
            id: "1000000000000000",
            title: "Vintage desk",
            creationTime: nil,
            priceAmount: "12.50",
            priceFormatted: current ?? market.current,
            strikethroughFormatted: includeOriginal ? market.original : nil,
            photoURL: nil,
            photoID: nil,
            city: market.shortLocation.components(separatedBy: ", ").first,
            state: market.shortLocation.components(separatedBy: ", ").last,
            cityPageID: nil,
            deliveryTypes: ["IN_PERSON"],
            isSold: false,
            isLive: true,
            categoryID: nil,
            createdWithSellerApp: nil
        )
    }

    private func assertPrice(
        _ listing: Listing,
        market: MarketFixture,
        route: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(listing.priceText, market.current, route, file: file, line: line)
        XCTAssertEqual(listing.originalPriceText, market.original, route, file: file, line: line)
        XCTAssertEqual(
            PriceGuide.currencySymbol(in: listing.priceText),
            market.prefix,
            route,
            file: file,
            line: line
        )
        XCTAssertEqual(PriceGuide.parse(listing.priceText), 12, route, file: file, line: line)
    }
}
