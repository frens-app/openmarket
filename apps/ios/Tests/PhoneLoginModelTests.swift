import XCTest
@testable import OpenMarket

@MainActor
final class PhoneLoginModelTests: XCTestCase {
    private func model(_ country: PhoneCountry, _ typed: String) -> PhoneLoginModel {
        let model = PhoneLoginModel()
        model.country = country
        model.nationalNumber = typed
        return model
    }

    private func country(_ regionCode: String) -> PhoneCountry {
        PhoneCountry.all.first { $0.regionCode == regionCode }!
    }

    func testNationalEntryBecomesE164() {
        XCTAssertEqual(model(.unitedStates, "(415) 555-0123").e164, "+14155550123")
        XCTAssertEqual(model(country("GB"), "07911 123456").e164, "+447911123456")
        XCTAssertEqual(model(country("AU"), "0412 345 678").e164, "+61412345678")
    }

    func testContactAutoFillDropsTheCountryCodeItIncludes() {
        XCTAssertEqual(model(.unitedStates, "+1 (415) 555-0123").e164, "+14155550123")
        XCTAssertEqual(model(.unitedStates, "14155550123").e164, "+14155550123")
        XCTAssertEqual(model(country("GB"), "+44 7911 123456").e164, "+447911123456")
    }

    func testDigitsThatOnlyLookLikeACountryCodeSurvive() {
        // A ten-digit NANP number starting with 1 is a complete national
        // number, not +1 followed by nine digits.
        XCTAssertEqual(model(.unitedStates, "1415550123").e164, "+11415550123")
    }

    func testLeadingZeroIsDroppedWhereItIsATrunkPrefix() {
        XCTAssertEqual(model(country("NZ"), "021 123 4567").e164, "+64211234567")
        // Italy's is part of the number.
        XCTAssertEqual(model(country("IT"), "06 1234 5678").e164, "+390612345678")
    }

    func testSendIsOfferedOnlyForALengthTheCountryHas() {
        XCTAssertFalse(model(.unitedStates, "415555").canAdvance)
        XCTAssertTrue(model(.unitedStates, "4155550123").canAdvance)
        XCTAssertFalse(model(country("AU"), "412 345 6789").canAdvance)
        XCTAssertTrue(model(country("AU"), "412 345 678").canAdvance)
    }

    func testUnknownCountryFallsBackToWhatE164Guarantees() {
        // What a served calling code with no table entry gets: the picker still
        // offers it, and entry is bounded by E.164 alone.
        let unknown = PhoneCountry.served(callingCodes: ["7"]).first!
        XCTAssertEqual(unknown.digitRange, 4...14)
        XCTAssertEqual(model(unknown, "9123456789").e164, "+79123456789")
    }

    func testServedCountriesAreEveryCountryOnAServedCode() {
        let served = PhoneCountry.served(callingCodes: ["1", "44"])
        XCTAssertEqual(Set(served.map(\.regionCode)), ["US", "CA", "GB"])
    }
}
