import SwiftUI
import XCTest
@testable import OpenMarket

@MainActor
final class ListingVisibilityTests: XCTestCase {
    func testOnlyVisibleCardsInTheActiveFeedAreRecorded() async throws {
        let fixture = VisibilityFixture()
        let controller = UIHostingController(rootView: VisibilityTestFeed(fixture: fixture))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(fixture.visibleIDs.isEmpty, "A mounted but inactive feed must not count cards")

        let initialCards = expectation(description: "Visible cards counted when the feed becomes active")
        fixture.onVisible = {
            if fixture.visibleIDs == [0, 1] {
                fixture.onVisible = nil
                initialCards.fulfill()
            }
        }
        fixture.isEnabled = true
        await fulfillment(of: [initialCards], timeout: 3)
        XCTAssertEqual(fixture.visibleIDs, [0, 1], "Offscreen cards must not count")

        fixture.onVisible = nil
        fixture.isEnabled = false
        try await Task.sleep(for: .milliseconds(100))
        fixture.scrollTarget = 4
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(fixture.visibleIDs, [0, 1], "Scrolling the hidden feed must not count cards")

        let scrolledCards = expectation(description: "Current viewport counted when returning to the feed")
        fixture.onVisible = {
            if fixture.visibleIDs == [0, 1, 4, 5] {
                fixture.onVisible = nil
                scrolledCards.fulfill()
            }
        }
        fixture.isEnabled = true
        await fulfillment(of: [scrolledCards], timeout: 3)
        XCTAssertEqual(fixture.visibleIDs, [0, 1, 4, 5])
    }
}

@MainActor
private final class VisibilityFixture: ObservableObject {
    @Published var isEnabled = false
    @Published var scrollTarget: Int?
    var visibleIDs: Set<Int> = []
    var onVisible: (() -> Void)?
}

private struct VisibilityTestFeed: View {
    @ObservedObject var fixture: VisibilityFixture

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<12) { id in
                        Color.blue
                            .frame(height: 100)
                            .modifier(ListingVisibilityTracker(isEnabled: fixture.isEnabled) {
                                fixture.visibleIDs.insert(id)
                                fixture.onVisible?()
                            })
                            .id(id)
                    }
                }
            }
            .frame(width: 300, height: 200)
            .onChange(of: fixture.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target, anchor: .top) }
            }
        }
    }
}
