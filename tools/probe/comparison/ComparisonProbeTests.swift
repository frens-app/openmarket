import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

/// Opt-in only: copy into Tests and select this class explicitly. Never run as
/// part of the normal suite. See README for the bounded request budget.
@MainActor
final class ComparisonProbeTests: XCTestCase {
    func testComparisonTimings() async throws {
        let signedIn = await SessionState.isSignedIn()
        print("COMPARISON_PROBE facebook_signed_in=\(signedIn)")
        let pacer = RequestPacer(nextGap: { 0.4 })
        let engines = (0..<2).map { _ in DesktopFeedEngine(pacer: pacer) }
        let graphPacer = RequestPacer()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        for engine in engines { host.view.addSubview(engine.webView) }
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let coordinate = CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433)
        // Browser metadata reported 8 km; match it to avoid comparing different markets.
        func query(_ sold: Bool) -> SearchQuery {
            SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco", coordinate: coordinate,
                        delivery: .localPickup, age: sold ? .month : .any, availability: sold ? .unavailable : .any)
        }
        for fast in [false, true] {
            let start = ContinuousClock.now
            for sold in [false, true] {
                let rows = await engines[0].load(query(sold), locationTimeout: fast ? .zero : .milliseconds(2500),
                                                 markupGrace: fast ? .milliseconds(600) : nil)
                guard !rows.isEmpty else { return XCTFail("Browser probe empty or blocked; stop") }
                if sold {
                    let metadata = try await engines[0].webView.evaluateJavaScript(#"""
                    JSON.stringify(Array.from(document.scripts).flatMap(s => Array.from(s.textContent.matchAll(/commerce_search_and_rp_ctime_days.{0,350}/g), m => m[0])).slice(0,1))
                    """#)
                    print("COMPARISON_PROBE date_metadata=\(String(describing: metadata)) utc_day=\(Int(Date().timeIntervalSince1970 / 86400))")
                }
            }
            print("COMPARISON_PROBE browser_serial fast=\(fast) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
        }
        let start = ContinuousClock.now
        async let active = engines[0].load(query(false), locationTimeout: .zero, markupGrace: .milliseconds(600))
        async let sold = engines[1].load(query(true), locationTimeout: .zero, markupGrace: .milliseconds(600))
        let rows = await (active, sold)
        guard !rows.0.isEmpty, !rows.1.isEmpty else { return XCTFail("Parallel browser probe empty or blocked; stop") }
        print("COMPARISON_PROBE browser_parallel_400ms ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")

        let clients = (0..<2).map { _ in AnonymousFeedClient(pacer: graphPacer) }
        // Direct clients make any schema/network failure visible rather than
        // quietly timing a browser fallback as though it were GraphQL.
        for warm in [false, true, true] {
            let start = ContinuousClock.now
            async let activePage = clients[0].page(for: query(false), cursor: nil)
            async let soldPage = clients[1].page(for: query(true), cursor: nil)
            let pages = try await (activePage, soldPage)
            let soldRows = pages.1.listings.filter { $0.isSold == true }
            XCTAssertFalse(pages.0.listings.isEmpty)
            XCTAssertFalse(soldRows.isEmpty)
            let oldest = soldRows.compactMap(\.postedAt).min()
            let age = oldest.map { Int(Date().timeIntervalSince($0) / 86400) } ?? -1
            XCTAssertLessThanOrEqual(age, 31)
            print("COMPARISON_PROBE anonymous_parallel warm=\(warm) ms=\(Int(start.duration(to: .now) / .milliseconds(1))) active=\(pages.0.listings.count) sold=\(soldRows.count) oldest_days=\(age)")
        }
    }

    func testProductionPairAndDetail() async throws {
        let pool = MarketCheckPool()
        let detail = DetailEngine()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        for webView in pool.webViews + [detail.webView] { host.view.addSubview(webView) }
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var target: MarketComp?
        for warm in [false, true] {
            let start = ContinuousClock.now
            let pair = await pool.comparables(to: "desk", citySlug: "sanfrancisco", radiusKM: 8,
                coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433))
            let active = try pair.active.result.get()
            let sold = try pair.sold.result.get()
            target = active.first
            XCTAssertFalse(active.isEmpty)
            XCTAssertFalse(sold.isEmpty)
            XCTAssertTrue(sold.allSatisfy(\.isSold))
            print("COMPARISON_PROBE production warm=\(warm) ms=\(Int(start.duration(to: .now) / .milliseconds(1))) stages=\(pair.timings)")
        }
        let listing = try XCTUnwrap(target?.listing)
        let url = try XCTUnwrap(listing.itemURL)
        let start = ContinuousClock.now
        var galleryMS: Int?
        var stageCount = 0
        var firstStageHadPhotos = false
        let result = await detail.loadDetail(id: listing.id, url: url) { partial in
            stageCount += 1
            if stageCount == 1 { firstStageHadPhotos = !partial.photoURLs.isEmpty }
            if !partial.photoURLs.isEmpty, galleryMS == nil {
                galleryMS = Int(start.duration(to: .now) / .milliseconds(1))
            }
        }
        XCTAssertNotNil(result)
        let finalMS = Int(start.duration(to: .now) / .milliseconds(1))
        print("COMPARISON_PROBE detail gallery_ms=\(galleryMS ?? -1) final_ms=\(finalMS) first_stage_had_photos=\(firstStageHadPhotos) gallery_lead_ms=\(galleryMS.map { finalMS - $0 } ?? -1)")
    }

    func testPacingOnly() async {
        for old in [true, false] {
            let pacer = old ? RequestPacer(nextGap: { 0.4 }) : RequestPacer()
            let start = ContinuousClock.now
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<6 { group.addTask { _ = await pacer.waitForSlot() } }
            }
            print("COMPARISON_PROBE six_slots old=\(old) ms=\(Int(start.duration(to: .now) / .milliseconds(1)))")
        }
    }
}
