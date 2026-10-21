import XCTest
import SwiftUI
@testable import OpenMarket

@MainActor
final class SearchAlertsTests: XCTestCase {
    func testSearchUsesPricesWhileHistoryUsesTheTerm() {
        let store = SearchAlerts(load: { [] })
        store.setAccount("buyer")
        let alert = SearchAlert(id: "chair", query: "  Accent   Chair ", minPrice: 0, maxPrice: 400)
        store.created(alert, for: "buyer")
        XCTAssertEqual(store.matching(query: "accent chair", minPrice: 0, maxPrice: 400, for: "buyer"), alert)
        XCTAssertNil(store.matching(query: "accent chair", minPrice: nil, maxPrice: 400, for: "buyer"))
        XCTAssertNil(store.matching(query: "accent chair", minPrice: 0, maxPrice: 500, for: "buyer"))
        XCTAssertNil(store.matchingHistory("accent", for: "buyer"))
        XCTAssertNil(store.matchingHistory(" ", for: "buyer"))
        XCTAssertEqual(store.matchingHistory("ACCENT CHAIR", for: "buyer"), alert)
    }

    func testHistoryPrefersAnActiveAlertAndTracksPauseAndDeletion() {
        let store = SearchAlerts(load: { [] })
        store.setAccount("buyer")
        store.created(SearchAlert(id: "active", query: "chair", minPrice: nil, maxPrice: 400), for: "buyer")
        store.created(SearchAlert(id: "paused", query: "chair", minPrice: nil, maxPrice: 200, paused: true), for: "buyer")
        XCTAssertEqual(store.matchingHistory("chair", for: "buyer")?.id, "active")
        store.setPaused(true, id: "active", for: "buyer")
        XCTAssertEqual(store.matchingHistory("chair", for: "buyer")?.paused, true)
        store.setPaused(false, id: "active", for: "buyer")
        XCTAssertEqual(store.matchingHistory("chair", for: "buyer")?.id, "active")
        store.remove(id: "active", for: "buyer")
        store.remove(id: "paused", for: "buyer")
        XCTAssertNil(store.matchingHistory("chair", for: "buyer"))
    }

    func testAccountSwitchClearsBadgesAndRejectsOldMutations() {
        let store = SearchAlerts(load: { [] })
        let alert = SearchAlert(id: "chair", query: "chair", minPrice: nil, maxPrice: nil)
        store.setAccount("first")
        store.created(alert, for: "first")
        XCTAssertNil(store.matchingHistory("chair", for: "second"))
        store.setAccount("second")
        store.created(alert, for: "first")
        XCTAssertTrue(store.alerts.isEmpty)
        store.created(alert, for: "second")
        store.setAccount(nil)
        XCTAssertTrue(store.alerts.isEmpty)
        XCTAssertNil(store.matchingHistory("chair", for: nil))
    }

    func testLateRefreshCannotUndoCreationOrAccountSwitch() async {
        var resume: CheckedContinuation<[SearchAlert], Error>?
        let store = SearchAlerts(load: { try await withCheckedThrowingContinuation { resume = $0 } })
        store.setAccount("first")
        let load = Task { await store.refresh(for: "first") }
        while resume == nil { await Task.yield() }
        let alert = SearchAlert(id: "new", query: "chair", minPrice: nil, maxPrice: nil)
        store.created(alert, for: "first")
        resume?.resume(returning: [])
        await load.value
        XCTAssertEqual(store.alerts, [alert])

        resume = nil
        let oldAccountLoad = Task { await store.refresh(for: "first") }
        while resume == nil { await Task.yield() }
        store.setAccount("second")
        resume?.resume(returning: [alert])
        await oldAccountLoad.value
        XCTAssertTrue(store.alerts.isEmpty)
    }

    func testOtherScreensCannotPublishAListFetchedBeforeAMutation() {
        let store = SearchAlerts(load: { [] })
        store.setAccount("buyer")
        let requestRevision = store.revision
        let alert = SearchAlert(id: "new", query: "chair", minPrice: nil, maxPrice: nil)
        store.created(alert, for: "buyer")
        store.replace([], for: "buyer", since: requestRevision)
        XCTAssertEqual(store.alerts, [alert])
        store.replace([], for: "buyer", since: store.revision)
        XCTAssertTrue(store.alerts.isEmpty)
    }

    func testFilterBarAndHistoryRenderAtNarrowWidths() async throws {
        let suite = "SearchAlertsTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.locationName = "Toronto"
        prefs.radiusKM = 25
        prefs.maxPrice = 400
        let chooser = PlaceChooser(prefs: prefs)
        let active = SearchAlert(id: "chair", query: "Accent chair", minPrice: nil, maxPrice: 400)
        let paused = SearchAlert(id: "desk", query: "Standing desk", minPrice: nil, maxPrice: nil, paused: true)
        for width in [320.0, 390.0] {
            for scheme in [ColorScheme.light, .dark] {
                let content = NavigationStack {
                    VStack(spacing: 8) {
                        ForEach(0..<3) { state in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(["Get alerts", "Alerts on", "Alerts paused"][state])
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 8) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                                        Text("Accent chair").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                            .frame(width: 44, height: 44)
                                    }
                                    .padding(.leading, 12)
                                    .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                    SearchAlertButton(alert: [nil, active, paused][state], iconOnly: true, action: {})
                                    Image(systemName: "line.3.horizontal.decrease")
                                        .frame(width: 44, height: 44)
                                        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12))
                                }
                            }.padding(.horizontal, 12)
                        }
                        ActiveFilterBar(onLocation: {}, onRerun: {})
                        List {
                            Section("Recent") {
                                SearchHistoryRow(term: "Accent chair", alert: active, onSelect: {}, onAlert: { _ in })
                                SearchHistoryRow(term: "Standing desk", alert: paused, onSelect: {}, onAlert: { _ in })
                                SearchHistoryRow(term: "Nintendo Switch", alert: nil, onSelect: {}, onAlert: { _ in })
                            }
                        }.listStyle(.plain)
                    }.navigationTitle("Search")
                }
                .environmentObject(prefs).environmentObject(chooser).environment(\.colorScheme, scheme)
                let controller = UIHostingController(rootView: content)
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 720))
                window.rootViewController = controller
                window.makeKeyAndVisible()
                try await Task.sleep(for: .milliseconds(250))
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                    controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "Search alerts \(Int(width)) \(scheme)"
                attachment.lifetime = .keepAlways
                add(attachment)
                window.isHidden = true
            }
        }
    }
}
