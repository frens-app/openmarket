import WebKit
import XCTest
@testable import OpenMarket

@MainActor
final class AnonymousSellerProbeTests: XCTestCase {
    func testDiscovery() async throws {
        let browser = DesktopFeedEngine(dataStore: .nonPersistent())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        host.view.addSubview(browser.webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        _ = await browser.loadCards(URL(string: "https://www.facebook.com/marketplace/profile/504408982/")!)
        for _ in 0..<40 {
            if await browser.evaluate("document.querySelector('[aria-label=\"Inventory availability status\"]') ? 'ready' : ''") == "ready" { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let result = try await browser.webView.evaluateJavaScript(#"""
        (() => {
          const names=['MarketplaceSellerProfileInventoryQuery','MarketplaceSellerProfileInventoryList_profile','MarketplaceSellerProfileDialogQuery'];
          const results={};
          for(const name of names) {try {const q=require(name+'.graphql');results[name]={params:q.params,metadata:q.metadata,argumentDefinitions:q.argumentDefinitions,operation:q.operation}} catch(e){results[name]={error:e.message}}}
          return JSON.stringify(results);
        })()
        """#) as! String
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("seller-query-metadata.json")
        try Data(result.utf8).write(to: path)
        print("ANONYMOUS_SELLER_METADATA \(path.path)")
        let summaries = try await browser.webView.evaluateJavaScript(#"""
        (()=>{const out=[];function walk(x){if(!x||typeof x!=='object')return;if(x.__bbox?.result?.data?.profile){const p=x.__bbox.result.data.profile;out.push({keys:Object.keys(p),connectionKeys:Object.keys(p.marketplace_listing_sets||{}),count:p.marketplace_listing_sets?.edges?.length})}Object.values(x).forEach(walk)}for(const s of document.querySelectorAll('script[type="application/json"]'))try{walk(JSON.parse(s.textContent))}catch{}return JSON.stringify(out)})()
        """#)
        print("ANONYMOUS_SELLER_SUMMARY \(summaries)")
        let component = try await browser.webView.evaluateJavaScript(#"""
        (()=>{const out={};out.availabilityOptions=JSON.stringify(require('MarketplaceSellerProfileInventoryAvailabilityInput.options'),(k,v)=>typeof v==='function'?String(v):v);for(const name of ['MarketplaceSellerProfileInventoryList.react','MarketplaceSellerProfileInventoryFilterBar.react'])try{out[name]=String(require(name)).slice(0,40000)}catch(e){out[name]=e.message}return JSON.stringify(out)})()
        """#) as! String
        let componentPath = path.deletingLastPathComponent().appendingPathComponent("seller-component.json")
        try Data(component.utf8).write(to: componentPath)
        print("ANONYMOUS_SELLER_COMPONENT \(componentPath.path)")

    }
}
