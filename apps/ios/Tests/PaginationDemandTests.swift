import XCTest
@testable import OpenMarket

final class PaginationDemandTests: XCTestCase {
    func testBottomRequestsAutomaticallyWithoutDragOrCardCallbacks() {
        var demand = PaginationDemand()
        XCTAssertTrue(demand.shouldLoad(state()))
        XCTAssertFalse(demand.shouldLoad(state()))
    }

    func testWaitsForVisibleBottomAndAvailableIdleFeed() {
        var demand = PaginationDemand()
        XCTAssertFalse(demand.shouldLoad(state(near: false)))
        XCTAssertFalse(demand.shouldLoad(state(available: false)))
        XCTAssertFalse(demand.shouldLoad(state(loading: true)))
        XCTAssertTrue(demand.shouldLoad(state()))
    }

    func testNewVisibleCardsCanFillViewportButEmptyBatchesDoNotLoop() {
        var demand = PaginationDemand()
        XCTAssertTrue(demand.shouldLoad(state()))
        XCTAssertFalse(demand.shouldLoad(state(loading: true)))
        XCTAssertFalse(demand.shouldLoad(state()))
        XCTAssertFalse(demand.shouldLoad(state(count: 8, loading: true)))
        XCTAssertTrue(demand.shouldLoad(state(count: 8)))
        XCTAssertFalse(demand.shouldLoad(state(count: 8)))
    }

    func testReturningToBottomOrStartingNewSearchCanRequestAgain() {
        var demand = PaginationDemand()
        XCTAssertTrue(demand.shouldLoad(state()))
        XCTAssertFalse(demand.shouldLoad(state(near: false)))
        XCTAssertTrue(demand.shouldLoad(state()))
        XCTAssertTrue(demand.shouldLoad(state(generation: 2)))
    }

    private func state(generation: Int = 1, count: Int = 6, near: Bool = true,
                       available: Bool = true, loading: Bool = false) -> PaginationDemand.State {
        .init(position: .init(generation: generation, visibleCount: count, lastVisibleID: "last-\(count)"),
              isNearBottom: near, canLoadMore: available, isLoading: loading)
    }
}
