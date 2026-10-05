import CoreLocation
import XCTest
@testable import OpenMarket

@MainActor
final class PlaceChooserTests: XCTestCase {
    private let point = CLLocationCoordinate2D(latitude: 43.6503, longitude: -79.3596)

    func testSuccessfulURLLookupDoesNotOpenPicker() async throws {
        let result = await PlaceChooser.resolveLocation(point, name: "Distillery District", origin: .searchedCity,
            direct: { coordinate, name, origin in
                .success(ResolvedPlace(name: name, segment: "toronto", coordinate: coordinate,
                                       origin: origin, verifiedAt: Date()))
            }, picker: { _, _, _ in
                XCTFail("Direct success must not depend on Facebook's dialog")
                return .failure(.noArrow)
            })
        let place = try result.get()
        XCTAssertEqual(place.name, "Distillery District")
        XCTAssertEqual(place.segment, "toronto")
        XCTAssertEqual(place.latitude, point.latitude)
        XCTAssertEqual(place.longitude, point.longitude)
        XCTAssertTrue(place.isVerified)
    }

    func testBackoffAndSupersededDoNotFallback() async {
        for failure in [MarketplacePlaceResolver.Failure.paced, .superseded] {
            let result = await PlaceChooser.resolveLocation(point, name: "Toronto", origin: .searchedCity,
                direct: { _, _, _ in .failure(failure) },
                picker: { _, _, _ in
                    XCTFail("Must not retry a paced or superseded request")
                    return .failure(.noArrow)
                })
            guard case .failure(let actual) = result else { return XCTFail("Expected failure") }
            XCTAssertEqual(actual, failure)
        }
    }

    func testFallbackRetainsNeighborhoodNameAndPoint() async throws {
        var pickerCalls = 0
        let result = await PlaceChooser.resolveLocation(point, name: "Distillery District", origin: .searchedCity,
            direct: { _, _, _ in .failure(.unresolved) },
            picker: { coordinate, _, origin in
                pickerCalls += 1
                return .success(ResolvedPlace(name: "Toronto", segment: "toronto", coordinate: coordinate,
                                              origin: origin, verifiedAt: Date()))
            })
        let place = try result.get()
        XCTAssertEqual(pickerCalls, 1)
        XCTAssertEqual(place.name, "Distillery District")
        XCTAssertEqual(place.latitude, point.latitude)
        XCTAssertEqual(place.longitude, point.longitude)
    }

    func testCancellationDuringLookupDoesNotStartPicker() async {
        let task = Task {
            await PlaceChooser.resolveLocation(point, name: "Toronto", origin: .searchedCity,
                direct: { _, _, _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .failure(.unresolved)
                }, picker: { _, _, _ in
                    XCTFail("Cancelled lookup must not start a picker")
                    return .failure(.noArrow)
                })
        }
        guard case .failure(.superseded) = await task.value else { return XCTFail("Expected cancellation") }
    }
}
