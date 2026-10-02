import CoreLocation
import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class DetailGraphQLProbeTests: XCTestCase {
    func testDetailDiscovery() async throws {
        let signedIn = await SessionState.isSignedIn()
        print("DETAIL_PROBE signed_in=\(signedIn)")
        guard signedIn else { throw XCTSkip("Sign into Facebook in Openmarket Dev to compare authenticated detail") }
        let query = SearchQuery(kind: .search("desk"), radiusKM: 8, citySlug: "sanfrancisco",
                                coordinate: CLLocationCoordinate2D(latitude: 37.779379, longitude: -122.418433),
                                delivery: .localPickup)
        let page = try await AnonymousFeedClient().page(for: query, cursor: nil)
        let listing = try XCTUnwrap(page.listings.first).makeListing(cardIndex: 0)
        let url = try XCTUnwrap(listing.itemURL)
        let engine = DetailEngine()
        let host = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1280, height: 900))
        window.rootViewController = host
        host.view.addSubview(engine.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let start = Date()
        let detail = await engine.loadBrowserDetail(id: listing.id, url: url) { partial in
            print("DETAIL_PROBE stage_ms=\(Int(Date().timeIntervalSince(start)*1000)) description=\(partial.description != nil) photos=\(partial.photoURLs.count) seller=\(partial.sellerName != nil)")
        }
        print("DETAIL_PROBE complete_ms=\(Int(Date().timeIntervalSince(start)*1000)) detail=\(detail != nil)")
        try await Task.sleep(for: .seconds(2))
        let summary = try await engine.webView.evaluateJavaScript(Self.discovery)
        print("DETAIL_PROBE discovery=\(summary)")
        let firstPairStarted = Date()
        for operation in ["MarketplacePDPContainerQuery", "MarketplacePDPC2CMediaViewerWithImagesQuery"] {
            guard await RequestPacer.shared.waitForSlot() else { return }
            let result = try await engine.webView.callAsyncJavaScript(Self.fetch,
                arguments: ["operationName": operation, "targetID": url.marketplaceItemID!], in: nil, contentWorld: .page)
            print("DETAIL_PROBE authenticated=\(result ?? "missing")")
            try validate(result)
        }
        print("DETAIL_PROBE initial direct_pair_ms=\(Int(Date().timeIntervalSince(firstPairStarted)*1000))")
        try await compare(detail, webView: engine.webView, label: "initial")
        var soldQuery = query
        soldQuery.availability = .unavailable
        let soldPage = try await AnonymousFeedClient().page(for: soldQuery, cursor: nil)
        var targets = Array(page.listings.dropFirst().prefix(1))
        if let sold = soldPage.listings.first(where: { $0.isSold == true }) { targets.append(sold) }
        let baselineEngine = DetailEngine()
        host.view.addSubview(baselineEngine.webView)
        for (index, payload) in targets.enumerated() {
            let card = payload.makeListing(cardIndex: 0)
            let pairStarted = Date()
            for operation in ["MarketplacePDPContainerQuery", "MarketplacePDPC2CMediaViewerWithImagesQuery"] {
                guard await RequestPacer.shared.waitForSlot() else { return }
                let result = try await engine.webView.callAsyncJavaScript(Self.fetch,
                    arguments: ["operationName": operation, "targetID": payload.id], in:nil,contentWorld:.page)
                print("DETAIL_PROBE target=\(index) sold=\(payload.isSold == true) authenticated=\(result ?? "missing")")
                try validate(result)
            }
            print("DETAIL_PROBE target=\(index) direct_pair_ms=\(Int(Date().timeIntervalSince(pairStarted)*1000))")
            let started = Date()
            let baseline = await baselineEngine.loadBrowserDetail(id:card.id,url:card.itemURL!)
            print("DETAIL_PROBE target=\(index) browser_complete_ms=\(Int(Date().timeIntervalSince(started)*1000))")
            try await compare(baseline, webView:engine.webView,label:"target\(index)")
        }
        let templates = try await engine.webView.evaluateJavaScript("JSON.stringify(window.__detailProbePreloaders.filter(p => ['MarketplacePDPContainerQuery', 'MarketplacePDPC2CMediaViewerWithImagesQuery'].includes(p.queryName)).map(p => ({operation:p.queryName, doc_id:p.queryID, variables:p.variables})))") as! String
        let requests = try JSONSerialization.jsonObject(with: Data(templates.utf8)) as! [[String: Any]]
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        for template in requests {
            guard await RequestPacer.shared.waitForSlot() else { return }
            let variables = try JSONSerialization.data(withJSONObject: template["variables"]!)
            var form = URLComponents()
            form.queryItems = ["__user":"0", "av":"0", "__a":"1", "__comet_req":"15",
                "fb_api_caller_class":"RelayModern", "fb_api_req_friendly_name":template["operation"] as! String,
                "doc_id":String(describing: template["doc_id"]!), "variables":String(decoding:variables,as:UTF8.self),
                "server_timestamps":"true"].map { URLQueryItem(name:$0.key,value:$0.value) }
            var request = URLRequest(url: URL(string:"https://www.facebook.com/api/graphql/")!)
            request.httpMethod = "POST"
            request.httpBody = Data(form.percentEncodedQuery!.replacingOccurrences(of:"+",with:"%2B").utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField:"Content-Type")
            request.setValue("OpenMarket/0.0.1 (iOS)", forHTTPHeaderField:"User-Agent")
            request.setValue("application/json", forHTTPHeaderField:"Accept")
            request.httpShouldHandleCookies = false
            request.timeoutInterval = 10
            let started = Date()
            let (data, response) = try await session.data(for:request)
            let status = (response as! HTTPURLResponse).statusCode
            let result = try await engine.webView.callAsyncJavaScript("return window.__detailProbeSummarize(raw, operationName, 'anonymous');",
                arguments:["raw":String(decoding:data,as:UTF8.self), "operationName":template["operation"]!], in:nil,contentWorld:.page)
            print("DETAIL_PROBE anonymous status=\(status) ms=\(Int(Date().timeIntervalSince(started)*1000)) result=\(result ?? "missing")")
            if status == 403 || status == 429 { break }
            if let summary = result as? String, let parsed = try JSONSerialization.jsonObject(with:Data(summary.utf8)) as? [String:Any],
               let codes = parsed["errorCodes"] as? [Any], !codes.isEmpty { break }
        }
        try await compare(detail,webView:engine.webView,label:"anonymous_initial",context:"anonymous")
    }

    static let discovery = #"""
    (function() {
      const seen = new Set();
      window.__detailProbePreloaders = [];
      window.__detailProbeResponses = {};
      window.__detailProbeSummarize = function(raw, operationName, context) {
        let records;
        try { records = raw.replace(/^for \(;;\);/, '').trim().split('\n').filter(Boolean).map(JSON.parse); }
        catch (_) { return JSON.stringify({operationName, bytes:raw.length, json:false}); }
        window.__detailProbeResponses[context + operationName] = records;
        const own = records[0]?.data?.viewer?.marketplace_product_details_page?.target;
        return JSON.stringify({operationName, bytes:raw.length, records:records.length,
          errors:records.flatMap(r => (r.errors || []).map(e => ({code:e.code, severity:e.severity}))),
          errorCodes:records.map(r => r.error).filter(Boolean), errorDescriptions:records.map(r => r.errorDescription).filter(Boolean),
          targetPresent:!!own, photoCount:own?.listing_photos?.length,
          sellerPresent:!!own?.marketplace_listing_seller});
      };
      function walk(x) {
        if (!x || typeof x !== 'object') return;
        if (x.queryName || x.queryID || x.queryId) {
          const name = x.queryName || x.name || '';
          if (/marketplace|pdp/i.test(JSON.stringify(x).slice(0, 1000))) {
            const key = name + Object.keys(x).join();
            if (!seen.has(key)) {
              seen.add(key);
              window.__detailProbePreloaders.push(x);
            }
          }
        }
        Object.values(x).forEach(walk);
      }
      for (const s of document.querySelectorAll('script[type="application/json"]')) {
        try { walk(JSON.parse(s.textContent)); } catch (_) {}
      }
      return JSON.stringify(window.__detailProbePreloaders.filter(p => ['MarketplacePDPContainerQuery','MarketplacePDPC2CMediaViewerWithImagesQuery'].includes(p.queryName)).map(p => ({operation:p.queryName,doc_id:p.queryID,variables:Object.fromEntries(Object.entries(p.variables).filter(([k]) => k !== 'targetId'))})));
    })()
    """#

    static let fetch = #"""
    const op = window.__detailProbePreloaders.find(p => p.queryName === operationName);
    if (!op) return {failure:'missing operation'};
    const actor = require('CurrentUserInitialData').USER_ID;
    const params = require('getAsyncParams')('POST');
    if (!actor || actor === '0' || params.__user !== actor || op.actorID !== actor || !params.fb_dtsg) return JSON.stringify({failure:'session'});
    const fields = new URLSearchParams(params);
    fields.set('av', actor);
    fields.set('fb_api_caller_class', 'RelayModern');
    fields.set('fb_api_req_friendly_name', op.queryName);
    fields.set('doc_id', op.queryID);
    const variables = {...op.variables, targetId:targetID};
    fields.set('variables', JSON.stringify(variables));
    fields.set('server_timestamps', 'true');
    const started = performance.now();
    const response = await fetch('/api/graphql/', {method:'POST', credentials:'same-origin', body:fields, signal:AbortSignal.timeout(10000)});
    const raw = await response.text();
    return JSON.stringify({status:response.status, ms:Math.round(performance.now()-started),
      result:JSON.parse(window.__detailProbeSummarize(raw,operationName,'authenticated'))});
    """#

    func validate(_ result: Any?) throws {
        let text = try XCTUnwrap(result as? String)
        let envelope = try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
        XCTAssertEqual(envelope["status"] as? Int,200)
        let summary = try XCTUnwrap(envelope["result"] as? [String:Any])
        guard (summary["errors"] as? [Any])?.isEmpty == true,
              (summary["errorCodes"] as? [Any])?.isEmpty == true,
              summary["targetPresent"] as? Bool == true else {
            throw NSError(domain:"DetailProbeInvalidResponse",code:1)
        }
    }

    func compare(_ detail: ListingDetail?, webView: WKWebView, label: String, context: String = "authenticated") async throws {
        let baseline = String(decoding:try JSONEncoder().encode(detail),as:UTF8.self)
        let result = try await webView.callAsyncJavaScript(Self.compareScript, arguments:["baselineJSON":baseline,"context":context],in:nil,contentWorld:.page)
        print("DETAIL_PROBE comparison=\(label) result=\(result ?? "missing")")
    }

    static let compareScript = #"""
    const baseline = JSON.parse(baselineJSON) || {};
    const target = window.__detailProbeResponses[context+'MarketplacePDPContainerQuery']?.[0]?.data?.viewer?.marketplace_product_details_page?.target;
    const media = window.__detailProbeResponses[context+'MarketplacePDPC2CMediaViewerWithImagesQuery']?.[0]?.data?.viewer?.marketplace_product_details_page?.target;
    if (!target || !media) return JSON.stringify({failure:'missing target'});
    const seller = target.marketplace_listing_seller;
    const same = (a,b) => a == null && b == null ? 'both_missing' : a == null ? 'graphql_missing' : b == null ? 'browser_missing' : JSON.stringify(a) === JSON.stringify(b) ? 'equal' : 'different';
    const photoKey = u => u.split('?')[0].split('/').pop().split('.')[0].split('_')[1];
    const photos = media.listing_photos || [];
    const paths = [];
    function shape(x,p) {
      if (!x || typeof x !== 'object') { paths.push(p + ':' + (x === null ? 'null' : typeof x)); return; }
      Object.entries(x).forEach(([k,v]) => shape(v,p+'.'+k));
    }
    shape(target.attribute_data, 'attributes');
    shape(seller?.marketplace_user_profile, 'sellerProfile');
    shape(target.commerce_badges_info, 'badges');
    shape(photos[0], 'firstPhoto');
    const stats = seller?.marketplace_ratings_stats_by_role_v2;
    const normalize = s => typeof s === 'string' ? s.replace(/\s+/g,' ').trim() : s;
    const description = target.redacted_description?.text;
    const photoIDs = photos.map(p => photoKey(p.image.uri)).sort();
    const browserPhotoIDs = (baseline.photoURLs||[]).map(photoKey).sort();
    const delivery = target.delivery_types;
    const fulfillment = delivery ? {ships:delivery.includes('SHIPPING_ONSITE'),inPerson:delivery.includes('IN_PERSON'),doorPickup:delivery.includes('DOOR_PICKUP'),doorDropoff:delivery.includes('DOOR_DROPOFF'),publicMeetup:delivery.includes('PUBLIC_MEETUP')} : null;
    const badgeSummary = target.commerce_badges_info?.source_summary;
    return JSON.stringify({
      targetIDsMatch:target.id === media.id,
      comparisons:{description:same(target.redacted_description?.text,baseline.description),
        descriptionNormalized:same(normalize(description),normalize(baseline.description)),
        photoIDs:same(photoIDs,browserPhotoIDs),
        condition:same(target.attribute_data?.find(a => a.attribute_name === 'Condition')?.label,baseline.conditionText),
        locationText:same(target.location_text?.text,baseline.locationText),
        fulfillment:same(fulfillment,baseline.fulfillment ? Object.fromEntries(Object.keys(fulfillment||{}).map(k => [k,baseline.fulfillment[k]])) : null),
        highlyRated:same(badgeSummary == null ? null : /Highly rated/i.test(badgeSummary),baseline.sellerIsHighlyRated),
        latitude:same(target.location?.latitude,baseline.latitude),longitude:same(target.location?.longitude,baseline.longitude),
        sold:same(target.is_sold,baseline.isSold),pending:same(target.is_pending,baseline.isPending),
        sellerName:same(seller?.name,baseline.sellerName),sellerID:same(seller?.id,baseline.sellerProfileID),
        joinedYear:same(seller?.join_time ? String(new Date(seller.join_time*1000).getUTCFullYear()) : null,baseline.sellerJoined?.match(/\d{4}/)?.[0]),
        sellerRating:same(stats?.seller_stats?.five_star_ratings_average,baseline.sellerRating),
        sellerRatingCount:same(stats?.seller_stats?.five_star_total_rating_count_by_role,baseline.sellerRatingCount),
        combinedRating:same(stats?.seller_buyer_combined?.five_star_ratings_average,baseline.sellerRating),
        combinedRatingCount:same(stats?.seller_buyer_combined?.five_star_total_rating_count_by_role,baseline.sellerRatingCount)},
      photoCounts:{graphql:photos.length,browser:(baseline.photoURLs||[]).length},
      photoSizes:photos.map(p => ({width:p.image.width,height:p.image.height})),
      descriptionLengths:{graphql:description?.length,browser:baseline.description?.length},
      descriptionContainsBrowser:description && baseline.description ? description.includes(baseline.description) : null,
      browserContainsDescription:description && baseline.description ? baseline.description.includes(description) : null,
      hasCreationTime:typeof target.creation_time === 'number',
      sellerRatingsPrivate:stats?.seller_ratings_are_private,
      combinedRatingsPrivate:stats?.seller_buyer_combined?.ratings_are_private,
      sellerRatingCountZero:stats?.seller_stats?.five_star_total_rating_count_by_role === 0,
      browserHasCondition:!!baseline.conditionText,browserHasPosted:!!baseline.postedText,
      browserHasHighlyRated:baseline.sellerIsHighlyRated,
      attributes:target.attribute_data, badges:target.commerce_badges_info, shapes:paths,
      sellerProfileFlags:seller?.marketplace_user_profile ? Object.fromEntries(Object.entries(seller.marketplace_user_profile).filter(([k,v]) => typeof v === 'boolean')) : null
    });
    """#
}
