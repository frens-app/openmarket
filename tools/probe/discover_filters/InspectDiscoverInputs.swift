import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
class Probe: NSObject, WKNavigationDelegate {
 let web: WKWebView
 let window: NSWindow
 override init() {
  let config = WKWebViewConfiguration()
  config.websiteDataStore = .nonPersistent()
  web = WKWebView(frame:NSRect(x:0,y:0,width:1280,height:900),configuration:config)
  window = NSWindow(contentRect:NSRect(x:0,y:0,width:1280,height:900),styleMask:[.titled],backing:.buffered,defer:false)
  super.init()
  window.contentView = web
  web.navigationDelegate = self
  web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
 }
 func start() {
  web.load(URLRequest(url:URL(string:"https://www.facebook.com/marketplace/sanfrancisco/")!))
  DispatchQueue.main.asyncAfter(deadline:.now()+45) { exit(2) }
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
  DispatchQueue.main.asyncAfter(deadline:.now()+5) {
   self.web.evaluateJavaScript(#"""
   (function(){
    const out = {url:location.pathname,queries:[],refinementFields:[]};
    try {
     const names=Object.keys(require('__debug').modulesMap);
     for(const name of names.filter(n=>/MarketplaceCometBrowseFeedLight.*Query.graphql$/.test(n))) {
      try {
       const q=require(name);
       if(q.params?.operationKind!=='query') continue;
       out.queries.push({name,id:q.params.id,args:q.operation.argumentDefinitions,
        root:q.operation.selections.filter(s=>s.name==='marketplace_home_feed').map(s=>({name:s.name,args:s.args}))});
      }catch(e){}
     }
     const component=require('MarketplaceCometBrowseFeedLight.react').toString();
     out.refinementFields=['locality','max_price_cents','min_price_cents','text'].filter(name=>component.includes(name+':'));
    }catch(e){out.error=e.message;}
    return JSON.stringify(out);
   })()
   """#) { result,error in
    if let s=result as? String {print(s)} else {print("error: \(String(describing:error))")}
    exit(error == nil ? 0 : 1)
   }
  }
 }
}
let probe = Probe()
probe.start()
app.run()
