import SwiftUI
import WebKit
import Combine

extension UIApplication {
    var topVC: UIViewController? {
        var vc = connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }
}

private final class ScriptProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

enum Scripts {
    static let forms = """
    (function(){
      if (window.__lumenForms) return; window.__lumenForms = true;
      document.addEventListener('submit', function(e){
        var f = e.target; if(!f || !f.querySelector) return;
        var pw = f.querySelector('input[type=password]');
        if (pw && pw.value) {
          var user = '';
          var inputs = f.querySelectorAll('input');
          for (var i=0;i<inputs.length;i++){ if(inputs[i]===pw) break; var t=(inputs[i].type||'text').toLowerCase(); if((t==='text'||t==='email'||t==='tel') && inputs[i].value) user = inputs[i].value; }
          window.webkit.messageHandlers.savePassword.postMessage({host: location.hostname, user: user, pass: pw.value});
        }
        var a = f.action || '';
        if (a.indexOf('http://') === 0 && !window.__lumenAllow) {
          e.preventDefault(); e.stopPropagation();
          window.__lumenPending = f;
          window.webkit.messageHandlers.insecureForm.postMessage({action: a});
        }
      }, true);
    })();
    """

    static let pick = """
    (function(){
      if (window.__lumenPick) return; window.__lumenPick = true;
      function sel(e){
        if (e.id) return '#' + CSS.escape(e.id);
        var p=[]; while(e && e.nodeType===1 && e!==document.body){
          var s=e.tagName.toLowerCase(), i=1, sb=e;
          while(sb=sb.previousElementSibling){ if(sb.tagName===e.tagName) i++; }
          p.unshift(s+':nth-of-type('+i+')'); e=e.parentElement; }
        return 'body > ' + p.join(' > ');
      }
      function h(ev){
        ev.preventDefault(); ev.stopPropagation();
        var el=ev.target, s=sel(el); el.style.display='none';
        window.webkit.messageHandlers.hide.postMessage({host: location.hostname, sel: s});
        document.removeEventListener('click', h, true); window.__lumenPick=false;
      }
      document.addEventListener('click', h, true);
    })();
    """

    static let video = #"""
    (function(){
      if (window.__lumenVid) return; window.__lumenVid = true;
      function fix(v){ v.setAttribute('playsinline',''); v.setAttribute('webkit-playsinline',''); v.style.webkitTouchCallout='none'; }
      function scan(){ document.querySelectorAll('video').forEach(fix); }
      new MutationObserver(scan).observe(document, {childList:true, subtree:true});
      document.addEventListener('DOMContentLoaded', scan);
      var timer=null, sx=0, sy=0;
      function videoAt(x,y){
        var els = document.elementsFromPoint(x,y);
        for (var i=0;i<els.length;i++){ if(els[i].tagName==='VIDEO') return els[i]; }
        var vs=document.querySelectorAll('video');
        for (var j=0;j<vs.length;j++){ var r=vs[j].getBoundingClientRect();
          if(r.width>100 && x>=r.left && x<=r.right && y>=r.top && y<=r.bottom) return vs[j]; }
        return null;
      }
      function collect(v){
        var out=[];
        function add(u,l){ if(!u) return; if(u.indexOf('http')!==0 && u.indexOf('blob:')!==0) return; out.push({url:u,label:l||''}); }
        add(v.currentSrc||v.src,'');
        v.querySelectorAll('source').forEach(function(s){
          add(s.src, s.getAttribute('label')||s.getAttribute('title')||s.getAttribute('res')||(s.getAttribute('size')?s.getAttribute('size')+'p':''));
        });
        try{ performance.getEntriesByType('resource').forEach(function(e){
          if(/\.(m3u8|mp4|m4v|webm|mov)(\?|$)/i.test(e.name)) add(e.name,''); }); }catch(e){}
        return out;
      }
      document.addEventListener('touchstart', function(e){
        if(e.touches.length!==1) return;
        var t=e.touches[0]; sx=t.clientX; sy=t.clientY;
        clearTimeout(timer);
        timer=setTimeout(function(){
          var v=videoAt(sx,sy); if(!v) return;
          window.webkit.messageHandlers.videoMenu.postMessage({page:location.href, title:document.title, sources:collect(v)});
        }, 650);
      }, {passive:true, capture:true});
      ['touchmove','touchend','touchcancel'].forEach(function(n){
        document.addEventListener(n, function(e){
          if(n==='touchmove' && e.touches[0] && Math.abs(e.touches[0].clientX-sx)<12 && Math.abs(e.touches[0].clientY-sy)<12) return;
          clearTimeout(timer);
        }, {passive:true, capture:true});
      });
    })();
    """#

    static let media = """
    (function(){var r=[];document.querySelectorAll('video,audio,source,a[href]').forEach(function(e){
      var s=e.currentSrc||e.src||e.href||''; if(s.indexOf('http')!==0) return;
      if(e.tagName==='A' && !/\\.(mp4|m4v|mov|webm|mkv|mp3|m4a|aac|wav|flac|pdf|zip|rar|7z|dmg|apk|ipa|iso)(\\?|$)/i.test(s)) return;
      if(r.indexOf(s)<0) r.push(s);}); return r;})()
    """
}

final class Tab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    let id = UUID()
    let isPrivate: Bool
    let webView: WKWebView
    weak var store: BrowserStore?

    @Published var title = "New Tab"
    @Published var url: URL?
    @Published var progress = 0.0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var desktop: Bool
    @Published var group = "None"

    private var obs: [NSKeyValueObservation] = []
    private var navTimes: [Date] = []
    private var alertCount = 0

    var isHome: Bool { url == nil || url?.absoluteString == "about:blank" }

    init(isPrivate: Bool, store: BrowserStore) {
        self.isPrivate = isPrivate
        self.store = store
        self.desktop = Settings.shared.desktopDefault
        let c = WKWebViewConfiguration()
        c.websiteDataStore = isPrivate ? .nonPersistent() : .default()
        c.allowsInlineMediaPlayback = true
        c.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: c)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        let ucc = c.userContentController
        for n in ["hide", "insecureForm", "savePassword", "videoMenu"] { ucc.add(ScriptProxy(self), name: n) }
        ucc.addUserScript(WKUserScript(source: Scripts.forms, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: Scripts.video, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        AdBlock.shared.attach(ucc)

        obs = [
            webView.observe(\.url) { [weak self] w, _ in DispatchQueue.main.async { self?.url = w.url } },
            webView.observe(\.title) { [weak self] w, _ in DispatchQueue.main.async { if let t = w.title, !t.isEmpty { self?.title = t } } },
            webView.observe(\.estimatedProgress) { [weak self] w, _ in DispatchQueue.main.async { self?.progress = w.estimatedProgress } },
            webView.observe(\.isLoading) { [weak self] w, _ in DispatchQueue.main.async { self?.isLoading = w.isLoading } },
            webView.observe(\.canGoBack) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoBack = w.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] w, _ in DispatchQueue.main.async { self?.canGoForward = w.canGoForward } }
        ]
    }

    func load(_ u: URL) { webView.load(URLRequest(url: u)) }
    func goHome() {
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        title = "New Tab"
    }

    // MARK: tools
    func toggleDesktop() { desktop.toggle(); webView.reload() }

    func pickElementToHide() { webView.evaluateJavaScript(Scripts.pick) }

    func mediaLinks(_ done: @escaping ([String]) -> Void) {
        webView.evaluateJavaScript(Scripts.media) { r, _ in done((r as? [String]) ?? []) }
    }

    func savePagePDF(_ done: @escaping (Bool) -> Void) {
        let cfg = WKPDFConfiguration()
        cfg.rect = CGRect(origin: .zero, size: webView.scrollView.contentSize)
        webView.createPDF(configuration: cfg) { result in
            guard case .success(let data) = result else { done(false); return }
            let name = (self.title.isEmpty ? "page" : self.title).replacingOccurrences(of: "/", with: "-") + ".pdf"
            let dest = DownloadManager.shared.uniqueURL(Paths.downloads, name)
            done((try? data.write(to: dest)) != nil)
        }
    }

    private func injectHidden() {
        guard let host = url?.host, let sels = Settings.shared.hidden[host], !sels.isEmpty else { return }
        let css = sels.map { "\($0){display:none!important}" }.joined()
        guard let data = try? JSONEncoder().encode(css), let lit = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("(function(){var s=document.createElement('style');s.textContent=\(lit);document.head.appendChild(s);})()")
    }

    private func autofill() {
        guard let host = url?.host, let c = Keychain.credential(host: host),
              let u = try? JSONEncoder().encode(c.user), let p = try? JSONEncoder().encode(c.pass),
              let us = String(data: u, encoding: .utf8), let ps = String(data: p, encoding: .utf8) else { return }
        let js = """
        (function(){var pw=document.querySelector('input[type=password]'); if(!pw||pw.value) return;
        var inputs=document.querySelectorAll('input'); var user=null;
        for(var i=0;i<inputs.length;i++){ if(inputs[i]===pw) break; var t=(inputs[i].type||'text').toLowerCase(); if(t==='text'||t==='email'||t==='tel') user=inputs[i]; }
        function set(el,v){var d=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value'); d.set.call(el,v); el.dispatchEvent(new Event('input',{bubbles:true}));}
        if(user&&!user.value) set(user,\(us)); set(pw,\(ps));})()
        """
        webView.evaluateJavaScript(js)
    }

    // MARK: script messages
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        switch m.name {
        case "hide":
            if let h = body["host"] as? String, let s = body["sel"] as? String {
                Settings.shared.hidden[h, default: []].append(s)
            }
        case "insecureForm":
            guard Settings.shared.warnInsecure else {
                webView.evaluateJavaScript("window.__lumenAllow=true; window.__lumenPending&&window.__lumenPending.submit()"); return
            }
            confirm("Insecure form", "This form sends your data over an unencrypted connection. Continue?", ok: "Send anyway") { yes in
                if yes { self.webView.evaluateJavaScript("window.__lumenAllow=true; window.__lumenPending&&window.__lumenPending.submit()") }
            }
        case "savePassword":
            guard !isPrivate, let h = body["host"] as? String, let u = body["user"] as? String, let p = body["pass"] as? String else { return }
            if let existing = Keychain.credential(host: h), existing.user == u, existing.pass == p { return }
            confirm("Save password?", "Save the password for \(u.isEmpty ? h : u) on \(h)?", ok: "Save") { yes in
                if yes { Keychain.save(host: h, user: u, pass: p) }
            }
        case "videoMenu":
            guard let arr = body["sources"] as? [[String: Any]] else { return }
            var seen = Set<String>()
            let cands: [VideoCandidate] = arr.compactMap { d in
                guard let u = d["url"] as? String, seen.insert(u).inserted else { return nil }
                return VideoCandidate(url: u, label: d["label"] as? String ?? "")
            }
            let name = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (url?.host ?? "video")
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            syncCookies { [weak self] in
                guard let self else { return }
                self.store?.videoPicker = VideoPicker(title: name, page: self.url, candidates: cands)
            }
        default: break
        }
    }

    /// Lets downloads reuse the site's login/session cookies (skipped in private tabs).
    func syncCookies(_ done: @escaping () -> Void) {
        if isPrivate { done(); return }
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
            DispatchQueue.main.async(execute: done)
        }
    }

    private func confirm(_ title: String, _ msg: String, ok: String, _ done: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: title, message: msg, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        a.addAction(UIAlertAction(title: ok, style: .default) { _ in done(true) })
        UIApplication.shared.topVC?.present(a, animated: true)
    }

    // MARK: WKNavigationDelegate
    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        if let u = action.request.url, let s = u.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data", "file"].contains(s) {
            if Settings.shared.blockRedirects && action.navigationType != .linkActivated {
                decisionHandler(.cancel, preferences); return
            }
            UIApplication.shared.open(u)
            decisionHandler(.cancel, preferences); return
        }
        if action.shouldPerformDownload { decisionHandler(.download, preferences); return }
        decisionHandler(.allow, preferences)
    }

    func webView(_ w: WKWebView, decidePolicyFor r: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !r.canShowMIMEType { decisionHandler(.download); return }
        if let h = r.response as? HTTPURLResponse,
           let cd = h.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().contains("attachment") {
            decisionHandler(.download); return
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, navigationAction: WKNavigationAction, didBecome d: WKDownload) { d.delegate = DownloadManager.shared }
    func webView(_ w: WKWebView, navigationResponse: WKNavigationResponse, didBecome d: WKDownload) { d.delegate = DownloadManager.shared }

    func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) {
        alertCount = 0
        // On-device guard against pages that spam navigations to freeze the browser
        let now = Date()
        navTimes = navTimes.filter { now.timeIntervalSince($0) < 2 } + [now]
        if navTimes.count > 8 {
            w.stopLoading()
            navTimes = []
            confirm("Suspicious page", "This page tried to redirect repeatedly, so loading was stopped.", ok: "OK") { _ in }
        }
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        injectHidden()
        autofill()
        store?.record(self)
    }

    // MARK: WKUIDelegate
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if a.navigationType == .linkActivated, a.targetFrame == nil, let u = a.request.url {
            store?.newTab(url: u, isPrivate: isPrivate)
        }
        return nil // popups that were not user-initiated are blocked
    }

    func webView(_ w: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping () -> Void) {
        alertCount += 1
        if alertCount > 3 { completionHandler(); return }
        let a = UIAlertController(title: f.request.url?.host, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        UIApplication.shared.topVC?.present(a, animated: true)
    }

    func webView(_ w: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame f: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        alertCount += 1
        if alertCount > 3 { completionHandler(false); return }
        confirm(f.request.url?.host ?? "", message, ok: "OK", completionHandler)
    }
}
