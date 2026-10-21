import XCTest
import SwiftUI
@testable import OpenMarket

@MainActor
final class ListingAlertsTests: XCTestCase {
    func testServerAlertAllowanceAndOlderDeployments() throws {
        for (active, limit, available) in [(0, 1, true), (1, 1, false), (1, 2, true), (3, 1, false)] {
            let json = "{\"alerts\":[],\"allowance\":{\"active\":\(active),\"limit\":\(limit)}}"
            let list = try ListingAlertsService.decoder().decode(ListingAlertsService.AlertList.self, from: Data(json.utf8))
            let allowance = try XCTUnwrap(list.allowance)
            XCTAssertEqual(allowance.active, active)
            XCTAssertEqual(allowance.limit, limit)
            XCTAssertEqual(allowance.hasAvailableSlot, available)
        }
        let legacy = try ListingAlertsService.decoder().decode(ListingAlertsService.AlertList.self, from: Data(#"{"alerts":[]}"#.utf8))
        XCTAssertNil(legacy.allowance)
    }

    func testInboxKeepsListingAndNotificationIdentity() throws {
        let json = #"{"items":[{"notificationID":"batch","alertID":"alert","query":"Plants","listing":{"id":"123","title":"Anthurium","priceText":"CA$68","locationText":"Toronto","thumbnailURL":"","description":"","condition":""},"createdAt":"2026-10-17T12:34:56.123456Z","createdCursor":"2026-10-17T12:34:56.123456Z","viewedAt":null,"savedAt":"2026-10-17T13:00:00Z"}]}"#
        let item = try XCTUnwrap(ListingAlertsService.decoder().decode(ListingAlertsService.Inbox.self, from: Data(json.utf8)).items.first)
        XCTAssertEqual(item.id, "batch:123")
        XCTAssertEqual(item.saveContext.notificationID, "batch")
        XCTAssertEqual(item.saveContext.alertID, "alert")
        XCTAssertNil(item.viewedAt)
        XCTAssertNotNil(item.savedAt)
        XCTAssertEqual(item.displayedListing.capturedAt, item.createdAt)
        XCTAssertNil(item.displayedListing.thumbnailURL)
        let request = ListingAlertsService.Request(beforeID: item.listing.id, before: item.createdCursor,
            notificationID: item.notificationID, filter: "saved")
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(encoded["beforeID"] as? String, "123")
        XCTAssertEqual(encoded["notificationID"] as? String, "batch")
        XCTAssertEqual(encoded["filter"] as? String, "saved")
        XCTAssertEqual(encoded["before"] as? String, "2026-10-17T12:34:56.123456Z")
    }

    func testFlatInboxRendersInLightAndDarkMode() async throws {
        let now = Date()
        let samples = [("Variegated anthurium", "CA$68"), ("Anthurium ‘African Mask’ Pink variegated", "CA$200"),
            ("Nintendo Switch OLED", "CA$280"), ("Monstera albo variegata", "CA$150"), ("Sony A7 III", "CA$1,200")]
        let items = samples.enumerated().map { index, sample in
            AlertInboxItem(notificationID: "batch", alertID: "alert", query: "Plants",
                listing: AlertListing(id: String(index), title: sample.0, priceText: sample.1,
                    locationText: "Toronto, ON", thumbnailURL: "", description: "", condition: ""),
                createdAt: now.addingTimeInterval(-Double(index + 1) * 3600), createdCursor: "", viewedAt: index == 4 ? now : nil, savedAt: nil)
        }
        for scheme in [ColorScheme.light, .dark] {
            let content = NavigationStack {
                List {
                    AlertInboxFilters(selection: .constant(.all)).listRowSeparator(.hidden)
                    Section {
                        ForEach(items) { item in
                            AlertInboxRow(item: item, isSaved: item.listing.id == "2", open: {}, save: {})
                                .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 12))
                        }
                    } header: { Text("Today").textCase(nil) }
                    Section {
                        AlertInboxRow(item: items[0], isSaved: false, open: {}, save: {})
                    } header: { Text("Yesterday").textCase(nil) }
                }
                .listStyle(.plain).navigationTitle("Alerts")
                .toolbar { Image(systemName: "ellipsis.circle") }
            }.environment(\.colorScheme, scheme)
            let controller = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = controller; window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(250))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Flat alert inbox \(scheme)"; attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testOptionalPriceInputAndRequestEncoding() throws {
        for (minimum, maximum, min, max) in [
            ("", "", nil, nil), ("10", "", 10, nil), ("", "100", nil, 100),
            ("10", "100", 10, 100), ("", "0", nil, 0), ("50", "50", 50, 50),
            ("  ", " 100 ", nil, 100)
        ] as [(String, String, Int?, Int?)] {
            let input = AlertPriceInput(minimum: minimum, maximum: maximum)
            XCTAssertNil(input.validationMessage)
            XCTAssertEqual(input.minPrice, min)
            XCTAssertEqual(input.maxPrice, max)
            let request = ListingAlertsService.Request(query: "Switch", minPrice: input.minPrice, maxPrice: input.maxPrice)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
            XCTAssertEqual(json["minPrice"] as? Int, min)
            XCTAssertEqual(json["maxPrice"] as? Int, max)
            if min == nil { XCTAssertNil(json["minPrice"]) }
            if max == nil { XCTAssertNil(json["maxPrice"]) }
        }
        for (minimum, maximum) in [("-1", ""), ("", "-1"), ("10", "5"), ("1.5", ""), ("abc", ""), ("", "2147483648"), ("", "999999999999999999999999"), ("+10", "")] {
            XCTAssertNotNil(AlertPriceInput(minimum: minimum, maximum: maximum).validationMessage)
        }
    }

    func testSavedAlertDecodesOptionalPriceBounds() throws {
        let json = #"{"id":"alert","query":"Switch","location":{"citySlug":"toronto","name":"Toronto","radiusKM":16,"latitude":43,"longitude":-79},"createdAt":"2026-10-17T12:00:00Z","alertHour":12,"nextCheckAt":"2026-10-18T12:00:00Z","paused":false,"matchCount":0,"unreadCount":0}"#
        let legacy = try ListingAlertsService.decoder().decode(ListingAlert.self, from: Data(json.utf8))
        XCTAssertNil(legacy.minPrice)
        XCTAssertNil(legacy.maxPrice)
        let bounded = json.replacingOccurrences(of: #""query":"Switch""#, with: #""query":"Switch","minPrice":0,"maxPrice":100"#)
        let alert = try ListingAlertsService.decoder().decode(ListingAlert.self, from: Data(bounded.utf8))
        XCTAssertEqual(alert.minPrice, 0)
        XCTAssertEqual(alert.maxPrice, 100)
    }

    func testPriceFieldsRenderCollapsedAndExpanded() async throws {
        for expanded in [false, true] {
            let content = Form {
                AlertPriceFields(input: .constant(AlertPriceInput()), expanded: .constant(expanded))
            }.frame(width: 390, height: 480)
            let controller = UIHostingController(rootView: content)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 480))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            try await Task.sleep(for: .milliseconds(200))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: controller.view.bounds.size).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "Alert price fields \(expanded ? "expanded" : "collapsed")"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testNotificationNavigationKeepsNotificationID() {
        let coordinator = ListingAlertCoordinator.shared
        coordinator.open("alert", notificationID: "notification")
        XCTAssertEqual(coordinator.openAlertID, "alert")
        XCTAssertEqual(coordinator.openNotificationID, "notification")
        XCTAssertEqual(coordinator.selectedTab, 3)
        coordinator.open("legacy-alert")
        XCTAssertNil(coordinator.openNotificationID)
        coordinator.openAlertID = nil
    }

    func testNotificationFeedKeepsBatchIdentityAndCursor() throws {
        let json = #"{"groups":[{"id":"notification-a","alertID":"alert-a","query":"Anthurium","createdAt":"2026-10-17T12:34:56.123456Z","createdCursor":"2026-10-17T12:34:56.123456Z","matchCount":13,"unreadCount":12,"previews":[{"id":"123","title":"Anthurium","priceText":"$50","locationText":"Toronto","thumbnailURL":"","description":"","condition":""}]}]}"#
        let group = try ListingAlertsService.decoder().decode(ListingAlertsService.NotificationFeed.self, from: Data(json.utf8)).groups[0]
        XCTAssertEqual(group.id, "notification-a")
        XCTAssertEqual(group.matchCount, 13)
        XCTAssertEqual(group.unreadCount, 12)
        XCTAssertNil(group.seenAt)
        let seenJSON = json.replacingOccurrences(of: "\"unreadCount\":12", with: "\"unreadCount\":12,\"seenAt\":\"2026-10-17T12:35:00Z\"")
        let seen = try ListingAlertsService.decoder().decode(ListingAlertsService.NotificationFeed.self, from: Data(seenJSON.utf8)).groups[0]
        XCTAssertNotNil(seen.seenAt)
        XCTAssertEqual(seen.unreadCount, 12)
        XCTAssertEqual(group.previews.count, 1)
        let request = ListingAlertsService.Request(id: group.alertID, notificationID: group.id)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(body["id"] as? String, "alert-a")
        XCTAssertEqual(body["notificationID"] as? String, "notification-a")
        let cursor = ListingAlertsService.Request(beforeID: group.id, before: group.createdCursor)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cursor)) as? [String: Any])
        XCTAssertEqual(encoded["before"] as? String, "2026-10-17T12:34:56.123456Z")
        XCTAssertEqual(encoded["beforeID"] as? String, "notification-a")
    }

    func testWorkUsesSuggestedAvailableSearchAndSavedLocation() throws {
        let data = Data(#"{"work":[{"id":"check","alertID":"alert","query":"Switch OLED","location":{"citySlug":"sanfrancisco","name":"San Francisco","radiusKM":16,"latitude":37.77,"longitude":-122.42},"cursor":"next-page","actor":"123","pageNumber":2}]}"#.utf8)
        let work = try ListingAlertsService.decoder().decode(ListingAlertsService.WorkList.self, from: data).work[0]
        XCTAssertEqual(work.searchQuery.sort, .bestMatch)
        XCTAssertEqual(work.searchQuery.availability, .available)
        XCTAssertEqual(work.searchQuery.citySlug, "sanfrancisco")
        XCTAssertEqual(work.searchQuery.coordinate?.latitude, 37.77)
        XCTAssertEqual(work.cursor, "next-page")
        XCTAssertEqual(work.pageNumber, 2)
        let request = try AnonymousFeedClient.request(for: work.searchQuery, cursor: nil)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let variables = try XCTUnwrap(URLComponents(string: "?" + body)?.queryItems?.first(where: { $0.name == "variables" })?.value)
        XCTAssertFalse(variables.contains("commerce_search_sort_by"))
        XCTAssertTrue(variables.contains("commerce_search_and_rp_available"))
    }

    func testServerSearchOptionsReachFacebookRequest() async throws {
        let data = Data(#"{"id":"check","alertID":"alert","query":"anthurium","location":{"citySlug":"toronto","name":"Toronto","radiusKM":16,"latitude":43.65,"longitude":-79.38},"pageNumber":0,"fetchAttemptID":"fetch-123","searchOptions":{"sort":"price_ascend","delivery":"local_pick_up","daysSinceListed":1,"conditions":["used_good"],"minPrice":10,"maxPrice":100}}"#.utf8)
        let work = try ListingAlertsService.decoder().decode(AlertWork.self, from: data)
        let client = MorePagesClient()
        let upload = try await ListingAlertCoordinator.searchFirstPage(work, actor: "123", client: client)
        let query = try XCTUnwrap(client.query)
        XCTAssertEqual(query.sort, .priceLowest)
        XCTAssertEqual(query.availability, .available)
        XCTAssertEqual(query.delivery, .localPickup)
        XCTAssertEqual(query.age, .day)
        XCTAssertEqual(query.conditions, [.usedGood])
        XCTAssertEqual(query.minPrice, 10)
        XCTAssertEqual(query.maxPrice, 100)
        XCTAssertEqual(client.calls, 1)
        XCTAssertNil(client.requestedCursor)
        XCTAssertEqual(upload.complete, true)
        XCTAssertEqual(upload.fetchAttemptID, "fetch-123")
        let encodedUpload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(upload)) as? [String: Any]
        XCTAssertEqual(encodedUpload?["fetchAttemptID"] as? String, "fetch-123")
        let request = try AnonymousFeedClient.request(for: query, cursor: nil, now: Date(timeIntervalSince1970: 86_400 * 20_000))
        let form = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let variables = try XCTUnwrap(URLComponents(string: "?" + form)?.queryItems?.first(where: { $0.name == "variables" })?.value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(variables.utf8)) as? [String: Any])
        let params = try XCTUnwrap(json["params"] as? [String: Any])
        let browse = try XCTUnwrap(params["browse_request_params"] as? [String: Any])
        XCTAssertEqual(browse["commerce_search_sort_by"] as? String, "PRICE_ASCEND")
        XCTAssertEqual(browse["filter_price_lower_bound"] as? Int, 1000)
        XCTAssertEqual(browse["filter_price_upper_bound"] as? Int, 10000)
        XCTAssertEqual(browse["commerce_enable_shipping"] as? Bool, false)
        XCTAssertEqual(browse["commerce_search_and_rp_available"] as? Bool, true)
        XCTAssertEqual(browse["commerce_search_and_rp_condition"] as? String, "used_good")
        XCTAssertEqual(browse["commerce_search_and_rp_ctime_days"] as? String, "20000;19999")
    }

    func testSearchOptionsDefaultMissingFieldsAndRejectInvalidConstraints() throws {
        let options = try ListingAlertsService.decoder().decode(AlertSearchOptions.self, from: Data(#"{"maxPrice":50,"futureField":true}"#.utf8))
        XCTAssertEqual(options.sort, .bestMatch)
        XCTAssertEqual(options.maxPrice, 50)
        XCTAssertNil(options.minPrice)
        for json in [#"{"sort":"unsupported"}"#, #"{"daysSinceListed":2}"#, #"{"minPrice":-1}"#, #"{"maxPrice":2147483648}"#, #"{"minPrice":100,"maxPrice":50}"#] {
            XCTAssertThrowsError(try ListingAlertsService.decoder().decode(AlertSearchOptions.self, from: Data(json.utf8)))
        }
    }

    func testDailyCheckCompletesAfterFirstPageEvenWhenFacebookHasMore() async throws {
        let data = Data(#"{"id":"check","alertID":"alert","query":"anthurium","location":{"citySlug":"toronto","name":"Toronto","radiusKM":16,"latitude":43.65,"longitude":-79.38},"cursor":"stale-cursor","actor":"123","pageNumber":2}"#.utf8)
        let work = try ListingAlertsService.decoder().decode(AlertWork.self, from: data)
        let client = MorePagesClient()
        let request = try await ListingAlertCoordinator.searchFirstPage(work, actor: "123", client: client)
        XCTAssertEqual(client.calls, 1)
        XCTAssertNil(client.requestedCursor)
        XCTAssertEqual(client.query?.sort, .bestMatch)
        XCTAssertEqual(client.query?.availability, .available)
        XCTAssertEqual(request.checkID, "check")
        XCTAssertEqual(request.pageNumber, 2)
        XCTAssertEqual(request.complete, true)
        XCTAssertNil(request.cursor)
        XCTAssertEqual(request.listings?.count, 0)
    }

    func testMatchesKeepExactPaginationTimestampAndCanonicalListingID() throws {
        let data = Data(#"{"matches":[{"listing":{"id":"123456789","title":"Switch OLED","priceText":"$150","locationText":"San Francisco","thumbnailURL":"","description":"","condition":""},"matchedAt":"2026-10-01T12:34:56.123456Z","matchedCursor":"2026-10-01T12:34:56.123456Z","viewedAt":null}]}"#.utf8)
        let match = try ListingAlertsService.decoder().decode(ListingAlertsService.MatchList.self, from: data).matches[0]
        XCTAssertEqual(match.matchedCursor, "2026-10-01T12:34:56.123456Z")
        XCTAssertNil(match.viewedAt)
        XCTAssertEqual(match.listing.listing.itemURL?.absoluteString, "https://www.facebook.com/marketplace/item/123456789/")
        XCTAssertEqual(match.listing.listing.id, "fb:123456789")
        let request = ListingAlertsService.Request(id: "alert", beforeID: match.id, before: match.matchedCursor)
        let encoded = try JSONEncoder().encode(request)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("2026-10-01T12:34:56.123456Z"))
    }

    func testDailyTimeDefaultsAndSelectedTimeEncoding() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let formatter = ISO8601DateFormatter()
        for (input, expected) in [
            ("2026-10-17T23:29:59Z", "2026-10-17T23:00:00Z"),
            ("2026-10-17T23:30:00Z", "2026-10-18T00:00:00Z"),
            ("2026-10-18T03:45:00Z", "2026-10-18T04:00:00Z")
        ] {
            let now = try XCTUnwrap(formatter.date(from: input))
            XCTAssertEqual(formatter.string(from: AlertSchedule.defaultTime(now: now, calendar: calendar)), expected)
        }
        let selection = try XCTUnwrap(formatter.date(from: "2026-10-18T00:15:00Z"))
        let schedule = AlertSchedule(date: selection, calendar: calendar)
        let request = ListingAlertsService.Request(query: "Anthurium", alertHour: schedule.hour,
            alertMinute: schedule.minute, timeZone: schedule.timeZone)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(json["alertHour"] as? Int, 20)
        XCTAssertEqual(json["alertMinute"] as? Int, 15)
        XCTAssertEqual(json["timeZone"] as? String, "America/Toronto")
    }

    func testNotificationRouteSelectsAlertsAndSpecificAlert() {
        let coordinator = ListingAlertCoordinator.shared
        defer { coordinator.openAlertID = nil; coordinator.selectedTab = 0 }
        coordinator.open("test-alert")
        XCTAssertEqual(coordinator.selectedTab, 3)
        XCTAssertEqual(coordinator.openAlertID, "test-alert")
    }
}

@MainActor
private final class MorePagesClient: GraphQLFeedLoading {
    var calls = 0
    var requestedCursor: String?
    var query: SearchQuery?

    func page(for query: SearchQuery, cursor: String?) async throws -> GraphQLFeedPage {
        calls += 1
        requestedCursor = cursor
        self.query = query
        return GraphQLFeedPage(listings: [], endCursor: "next-page", hasNextPage: true)
    }
}
