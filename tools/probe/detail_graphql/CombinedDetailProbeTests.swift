import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class CombinedDetailProbeTests: XCTestCase {
    // Opt-in capability probes, excluded from routine tests. The same-document
    // control intentionally fails if the endpoint does not return both results.
    func testSameDocumentBatchControl() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("Use logged-out Openmarket Detail QA") }
        let query = SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco",
                               coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                               delivery: .localPickup)
        let page = try await AnonymousFeedClient().page(for:query,cursor:nil)
        let targets = Array(page.listings.prefix(2))
        guard targets.count == 2 else {
            throw XCTSkip("Same-document batch control requires two anonymous listings")
        }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        var queries: [String:Any] = [:]
        for (index,target) in targets.enumerated() {
            queries["o\(index)"] = ["doc_id":DetailGraphQLOperation.media.documentID,
                                    "query_params":try JSONSerialization.jsonObject(with:Data(DetailGraphQLOperation.media.variables(itemID:target.id).utf8))]
        }
        var request = try DetailGraphQLOperation.media.request(itemID:targets[0].id)
        request.url = URL(string:"https://www.facebook.com/api/graphqlbatch/")!
        let fields = ["__user":"0","av":"0","__a":"1","__comet_req":"15","fb_api_caller_class":"RelayModern",
                      "server_timestamps":"true","queries":String(decoding:try JSONSerialization.data(withJSONObject:queries),as:UTF8.self)]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
        request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters:allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters:allowed)!
        }.joined(separator:"&").utf8)
        guard await RequestPacer.shared.waitForSlot() else { return }
        let started = Date()
        let (data,response) = try await session.data(for:request)
        let elapsed = Int(Date().timeIntervalSince(started)*1000)
        let raw = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"for (;;);",with:"")
        let records = raw.split(whereSeparator:\.isNewline).compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
        var counts: [Int] = []
        for (index,target) in targets.enumerated() {
            if let payload = records.compactMap({$0["o\(index)"] as? [String:Any]}).first {
                let photos = try GraphQLDetailDecoder.photos(JSONSerialization.data(withJSONObject:payload),itemID:target.id)
                counts.append(photos.count)
            }
        }
        let summary: [String:Any] = ["status":(response as! HTTPURLResponse).statusCode,"ms":elapsed,"bytes":data.count,
            "record_keys":records.map {Array($0.keys).sorted()},"valid_targets":counts.count,"photo_counts":counts,
            "error_codes":records.compactMap {($0["error"] as? [String:Any])?["code"] ?? $0["error"]},
            "errors":records.compactMap {($0["error"] as? [String:Any])?["debug_info"]},
            "totals":records.filter {$0["successful_results"] != nil}]
        print("COMBINED_DETAIL_SAME_DOC \(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys),as:UTF8.self))")
        XCTAssertEqual(counts.count,2)
    }

    func testBatchRequests() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("Use logged-out Openmarket Detail QA") }
        let query = SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco",
                               coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                               delivery: .localPickup)
        let page = try await AnonymousFeedClient().page(for:query,cursor:nil)
        let target = try XCTUnwrap(page.listings.first)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        let baselineStart = Date()
        let baseline = try await DetailGraphQLClient().load(itemID:target.id,actor:nil)
        print("COMBINED_DETAIL_BASELINE ms=\(Int(Date().timeIntervalSince(baselineStart)*1000)) photos=\(baseline.photoURLs.count)")
        let operations: [String:Any] = try ["o0": ["doc_id":DetailGraphQLOperation.core.documentID,
                                                    "query_params":JSONSerialization.jsonObject(with:Data(DetailGraphQLOperation.core.variables(itemID:target.id).utf8))],
                                           "o1": ["doc_id":DetailGraphQLOperation.media.documentID,
                                                    "query_params":JSONSerialization.jsonObject(with:Data(DetailGraphQLOperation.media.variables(itemID:target.id).utf8))]]
        let queries = String(decoding:try JSONSerialization.data(withJSONObject:operations),as:UTF8.self)
        for path in ["/api/graphql/", "/api/graphqlbatch/"] {
            guard await RequestPacer.shared.waitForSlot() else { return }
            var request = try DetailGraphQLOperation.core.request(itemID:target.id)
            request.url = URL(string:"https://www.facebook.com"+path)!
            let fields = ["__user":"0","av":"0","__a":"1","__comet_req":"15",
                          "fb_api_caller_class":"RelayModern","server_timestamps":"true","queries":queries]
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn:"-._~"))
            request.httpBody = Data(fields.sorted { $0.key < $1.key }.map {
                $0.key.addingPercentEncoding(withAllowedCharacters:allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters:allowed)!
            }.joined(separator:"&").utf8)
            let started = Date()
            let (data,response) = try await session.data(for:request)
            let elapsed = Int(Date().timeIntervalSince(started)*1000)
            let http = response as! HTTPURLResponse
            let raw = String(decoding:data,as:UTF8.self).replacingOccurrences(of:"for (;;);",with:"")
            let records = raw.split(whereSeparator:\.isNewline).compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
            var summary: [String:Any] = ["path":path,"status":http.statusCode,"ms":elapsed,"bytes":data.count,
                                        "record_count":records.count,"record_keys":records.map { Array($0.keys).sorted() }]
            summary["errors"] = records.compactMap { record -> [String:Any]? in
                guard record["error"] != nil || record["errors"] != nil else { return nil }
                let error = record["error"] as? [String:Any]
                return ["code":error?["code"] ?? record["error"] ?? NSNull(),
                        "summary":record["errorSummary"] ?? NSNull(),
                        "description":error?["description"] ?? record["errorDescription"] ?? NSNull(),
                        "debug_info":error?["debug_info"] ?? NSNull(),
                        "codes":(record["errors"] as? [[String:Any]] ?? []).map { $0["code"] ?? NSNull() }]
            }
            summary["operation_shapes"] = records.flatMap { record in
                ["o0","o1"].compactMap { key -> [String:Any]? in
                    guard let value = record[key] as? [String:Any] else { return nil }
                    return ["key":key,"fields":Array(value.keys).sorted()]
                }
            }
            if let core = records.compactMap({ $0["o0"] as? [String:Any] }).first,
               let media = records.compactMap({ $0["o1"] as? [String:Any] }).first {
                do {
                    var combined = try GraphQLDetailDecoder.core(JSONSerialization.data(withJSONObject:core),itemID:target.id)
                    combined.photoURLs = try GraphQLDetailDecoder.photos(JSONSerialization.data(withJSONObject:media),itemID:target.id)
                    summary["valid_both"] = true
                    summary["photo_ids_equal"] = Set(combined.photoURLs.compactMap(Listing.photoFBID)) == Set(baseline.photoURLs.compactMap(Listing.photoFBID))
                    summary["description_equal"] = combined.description == baseline.description
                    summary["condition_equal"] = combined.conditionText == baseline.conditionText
                    summary["coordinates_equal"] = combined.latitude == baseline.latitude && combined.longitude == baseline.longitude
                    summary["availability_equal"] = combined.isSold == baseline.isSold && combined.isPending == baseline.isPending
                    summary["fulfillment_equal"] = combined.fulfillment == baseline.fulfillment
                    summary["seller_equal"] = combined.sellerName == baseline.sellerName && combined.sellerProfileID == baseline.sellerProfileID
                } catch { summary["decode_failed"] = String(describing:type(of:error)) }
            }
            print("COMBINED_DETAIL_BATCH \(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:.sortedKeys),as:UTF8.self))")
            let lower = raw.lowercased()
            if http.statusCode == 403 || http.statusCode == 429 || lower.contains("blocked") || lower.contains("too many requests") || lower.contains("rate limit") { break }
        }
    }

    func testCombinedDiscovery() async throws {
        guard !(await SessionState.isSignedIn()) else { throw XCTSkip("Use logged-out Openmarket Detail QA") }
        let query = SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco",
                               coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                               delivery: .localPickup)
        let page = try await AnonymousFeedClient().page(for: query, cursor: nil)
        let listing = try XCTUnwrap(page.listings.first).makeListing(cardIndex: 0)
        let engine = DetailEngine()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        host.view.addSubview(engine.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        _ = await engine.loadBrowserDetail(id:listing.id,url:listing.itemURL!)
        try await Task.sleep(for:.seconds(1))
        let result = try await engine.webView.evaluateJavaScript(Self.inspect)
        print("COMBINED_DETAIL_DISCOVERY \(result ?? "missing")")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        let session = URLSession(configuration:config)
        defer { session.invalidateAndCancel() }
        var dataByOperation: [String: Data] = [:]
        for operation in DetailGraphQLOperation.allCases {
            guard await RequestPacer.shared.waitForSlot() else { return }
            let (data,response) = try await session.data(for:operation.request(itemID:listing.itemURL!.marketplaceItemID!))
            XCTAssertEqual((response as! HTTPURLResponse).statusCode,200)
            dataByOperation[operation.name] = data
        }
        let overlap = try await engine.webView.callAsyncJavaScript(Self.overlap,
            arguments:["coreText":String(decoding:dataByOperation[DetailGraphQLOperation.core.name]!,as:UTF8.self),
                       "mediaText":String(decoding:dataByOperation[DetailGraphQLOperation.media.name]!,as:UTF8.self)],in:nil,contentWorld:.page)
        print("COMBINED_DETAIL_OVERLAP \(overlap ?? "missing")")
    }

    static let inspect = #"""
    (function() {
      const out = {preloadedQueries:[], loadedQueries:[]};
      const seen = new Set();
      function walk(x) {
        if (!x || typeof x !== 'object') return;
        if (x.queryName && /marketplace/i.test(x.queryName) && !seen.has(x.queryName)) {
          seen.add(x.queryName);
          out.preloadedQueries.push({name:x.queryName, id:x.queryID});
        }
        Object.values(x).forEach(walk);
      }
      for (const s of document.querySelectorAll('script[type="application/json"]')) {
        try { walk(JSON.parse(s.textContent)); } catch (_) {}
      }
      try {
        const modules = require('__debug').modulesMap;
        for (const name of Object.keys(modules).filter(n => /marketplace.*(pdp|detail).*graphql/i.test(n))) {
          try {
            const q = require(name);
            if(q.params?.operationKind === 'query') out.loadedQueries.push({name:q.params.name,id:q.params.id});
          } catch (_) {}
        }
      } catch (e) {out.debugError = e.message;}
      return JSON.stringify(out);
    })()
    """#

    static let overlap = #"""
    const core = JSON.parse(coreText.replace(/^for \(;;\);/,''));
    const media = JSON.parse(mediaText.replace(/^for \(;;\);/,''));
    const page = core.data?.viewer?.marketplace_product_details_page;
    const photos = media.data?.viewer?.marketplace_product_details_page?.target?.listing_photos || [];
    const photoIDs = new Set(photos.map(p => p.id));
    const matches = [], imagePaths=[];
    function walk(x,path) {
      if (!x || typeof x !== 'object') return;
      if (photoIDs.has(x.id)) matches.push(path);
      for (const [k,v] of Object.entries(x)) {
        if (k === 'uri' && typeof v === 'string' && /scontent/.test(v)) imagePaths.push(path+'.'+k);
        walk(v,path+'.'+k);
      }
    }
    walk(page,'page');
    return JSON.stringify({coreErrors:core.errors?.map(e => e.code),mediaErrors:media.errors?.map(e => e.code),
      galleryPhotos:photos.length, galleryIDsFoundInCore:matches, coreImagePaths:imagePaths,
      targetHasListingPhotos:!!page?.target?.listing_photos});
    """#

}
