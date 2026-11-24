import WebKit

final class AdBlock {
    static let shared = AdBlock()
    private(set) var lists: [WKContentRuleList] = []
    private(set) var controllers = NSHashTable<WKUserContentController>.weakObjects()

    static let domains = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "adnxs.com",
        "adsrvr.org", "taboola.com", "outbrain.com", "criteo.com", "criteo.net", "scorecardresearch.com",
        "quantserve.com", "moatads.com", "amazon-adsystem.com", "pubmatic.com", "rubiconproject.com",
        "openx.net", "casalemedia.com", "advertising.com", "facebook.net", "hotjar.com", "mixpanel.com",
        "segment.io", "branch.io", "adjust.com", "appsflyer.com", "popads.net", "popcash.net",
        "propellerads.com", "exoclick.com", "juicyads.com", "trafficjunky.net", "adsterra.com",
        "mgid.com", "revcontent.com", "zedo.com", "smartadserver.com", "yieldmo.com", "2mdn.net"
    ]
    static let hideSelectors = [
        ".adsbygoogle", "[id^='google_ads']", "[class*='ad-banner']", "[class*='advert']",
        "[id*='ad-container']", "ins.adsbygoogle", ".sponsored-content", "[data-ad-slot]"
    ]

    func rebuild() {
        let s = Settings.shared
        guard s.adblock else {
            lists = []
            applyAll()
            return
        }
        var rules: [[String: Any]] = AdBlock.domains.map {
            ["trigger": ["url-filter": "^https?://([^/]+\\.)?" + $0.replacingOccurrences(of: ".", with: "\\.") + "[/:]?"],
             "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": AdBlock.hideSelectors.joined(separator: ",")]])
        compile(id: "builtin", rules: rules) { [weak self] builtin in
            let custom = self?.customRules() ?? []
            if custom.isEmpty { self?.finish([builtin].compactMap { $0 }); return }
            self?.compile(id: "custom", rules: custom) { c in
                self?.finish([builtin, c].compactMap { $0 })
            }
        }
    }

    private func finish(_ l: [WKContentRuleList]) {
        lists = l
        applyAll()
    }

    private func compile(id: String, rules: [[String: Any]], done: @escaping (WKContentRuleList?) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: rules),
              let json = String(data: data, encoding: .utf8) else { done(nil); return }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: id, encodedContentRuleList: json) { list, _ in
            DispatchQueue.main.async { done(list) }
        }
    }

    // Supports the common subset of EasyList syntax: ||domain^ and ##selector
    private func customRules() -> [[String: Any]] {
        var rules: [[String: Any]] = []
        var selectors: [String] = []
        for url in Settings.shared.customFilters {
            guard let text = try? String(contentsOf: cacheFile(url), encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("||"), line.hasSuffix("^"), !line.contains("$") {
                    let d = String(line.dropFirst(2).dropLast())
                    if d.contains("*") || d.contains("/") { continue }
                    rules.append(["trigger": ["url-filter": "^https?://([^/]+\\.)?" + d.replacingOccurrences(of: ".", with: "\\.") + "[/:]?"],
                                  "action": ["type": "block"]])
                } else if line.hasPrefix("##") {
                    selectors.append(String(line.dropFirst(2)))
                }
                if rules.count > 40000 { break }
            }
        }
        for chunk in stride(from: 0, to: selectors.count, by: 500) {
            let part = selectors[chunk..<min(chunk + 500, selectors.count)].joined(separator: ",")
            rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": part]])
        }
        return rules
    }

    private func cacheFile(_ url: String) -> URL {
        Paths.support.appendingPathComponent("filter_\(abs(url.hashValue)).txt")
    }

    func addFilter(url: String, completion: @escaping (Bool) -> Void) {
        guard let u = URL(string: url) else { completion(false); return }
        URLSession.shared.dataTask(with: u) { data, _, _ in
            DispatchQueue.main.async {
                guard let data, let _ = String(data: data, encoding: .utf8) else { completion(false); return }
                try? data.write(to: self.cacheFile(url))
                if !Settings.shared.customFilters.contains(url) { Settings.shared.customFilters.append(url) }
                self.rebuild()
                completion(true)
            }
        }.resume()
    }

    func removeFilter(url: String) {
        try? FileManager.default.removeItem(at: cacheFile(url))
        Settings.shared.customFilters.removeAll { $0 == url }
        rebuild()
    }

    func attach(_ c: WKUserContentController) {
        controllers.add(c)
        lists.forEach { c.add($0) }
    }

    private func applyAll() {
        for c in controllers.allObjects {
            c.removeAllContentRuleLists()
            lists.forEach { c.add($0) }
        }
    }
}
