import Foundation
import XCTest
@testable import OpenMarket

final class AccountNamesTests: XCTestCase {
    func testAppleNameComponentsAreKeptSeparate() {
        var fullName = PersonNameComponents()
        fullName.givenName = " María José "
        fullName.familyName = " García López "
        let names = AccountNames(appleFullName: fullName)
        XCTAssertEqual(names.firstName, "María José")
        XCTAssertEqual(names.lastName, "García López")
        XCTAssertFalse(names.displayName?.isEmpty ?? true)
    }

    func testMissingAndBlankNamesRemainOptional() {
        XCTAssertEqual(AccountNames(appleFullName: nil), AccountNames())
        XCTAssertEqual(AccountNames(firstName: "  ", lastName: "\n", displayName: ""), AccountNames())
        let names = AccountNames(firstName: "Cher", displayName: "Cher")
        XCTAssertNil(names.lastName)
        XCTAssertEqual(names.displayName, "Cher")
    }

    func testAppleNamesSurviveRetryUntilServerAcknowledges() {
        let userID = UUID().uuidString
        defer { AppleSignInNames.clear(userID: userID) }
        let names = AccountNames(firstName: "Sam", lastName: "Lee", displayName: "Sam Lee")
        XCTAssertEqual(AppleSignInNames.saveAndLoad(names, userID: userID), names)
        XCTAssertEqual(AppleSignInNames.saveAndLoad(AccountNames(), userID: userID), names)
        AppleSignInNames.clear(userID: userID)
        XCTAssertEqual(AppleSignInNames.saveAndLoad(AccountNames(), userID: userID), AccountNames())
    }

    func testAppleNamesNeverCarryOverToAnotherAccount() {
        let firstUser = UUID().uuidString, secondUser = UUID().uuidString
        defer { AppleSignInNames.clear(userID: firstUser); AppleSignInNames.clear(userID: secondUser) }
        _ = AppleSignInNames.saveAndLoad(AccountNames(firstName: "Sam"), userID: firstUser)
        XCTAssertEqual(AppleSignInNames.saveAndLoad(AccountNames(), userID: secondUser), AccountNames())
    }
}
