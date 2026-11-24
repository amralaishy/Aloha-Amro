import SwiftUI
import Combine
import WebKit

struct Bookmark: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var url: String
}

struct HistoryItem: Identifiable, Codable {
    var id = UUID()
    var title: String
    var url: String
    var date = Date()
}

enum AppTheme: String, CaseIterable, Identifiable {
    case midnight, ocean, sunset, forest, graphite
    var id: String { rawValue }
    var accent: Color {
        switch self {
        case .midnight: return Color(red: 0.31, green: 0.55, blue: 1.0)
        case .ocean: return .blue
        case .sunset: return .orange
        case .forest: return .green
        case .graphite: return .gray
        }
    }
    var colors: [Color] {
        switch self {
        case .midnight: return [Color(red: 0.03, green: 0.04, blue: 0.10), Color(red: 0.14, green: 0.12, blue: 0.34)]
        case .ocean: return [Color(red: 0.05, green: 0.25, blue: 0.5), Color(red: 0.2, green: 0.6, blue: 0.8)]
        case .sunset: return [Color(red: 0.6, green: 0.15, blue: 0.3), Color(red: 0.98, green: 0.6, blue: 0.2)]
        case .forest: return [Color(red: 0.05, green: 0.3, blue: 0.2), Color(red: 0.4, green: 0.7, blue: 0.4)]
        case .graphite: return [Color(white: 0.1), Color(white: 0.35)]
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable {
    case duckduckgo = "DuckDuckGo", google = "Google", bing = "Bing", brave = "Brave"
    var id: String { rawValue }
    func url(for query: String) -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .duckduckgo: return URL(string: "https://duckduckgo.com/?q=\(q)")
        case .google: return URL(string: "https://www.google.com/search?q=\(q)")
        case .bing: return URL(string: "https://www.bing.com/search?q=\(q)")
        case .brave: return URL(string: "https://search.brave.com/search?q=\(q)")
        }
    }
}

enum Paths {
    private static func dir(_ u: URL) -> URL {
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var support: URL { dir(FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) }
    static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static var downloads: URL { dir(documents.appendingPathComponent("Downloads")) }
    static var trash: URL { dir(support.appendingPathComponent("Trash")) }
    static var wallpaper: URL { support.appendingPathComponent("wallpaper.jpg") }
}

func loadJSON<T: Decodable>(_ key: String, _ def: T) -> T {
    guard let d = UserDefaults.standard.data(forKey: key),
          let v = try? JSONDecoder().decode(T.self, from: d) else { return def }
    return v
}
func saveJSON<T: Encodable>(_ v: T, _ key: String) {
    if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
}

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var adblock: Bool { didSet { d.set(adblock, forKey: "adblock"); AdBlock.shared.rebuild() } }
    @Published var blockRedirects: Bool { didSet { d.set(blockRedirects, forKey: "blockRedirects") } }
    @Published var warnInsecure: Bool { didSet { d.set(warnInsecure, forKey: "warnInsecure") } }
    @Published var appLock: Bool { didSet { d.set(appLock, forKey: "appLock") } }
    @Published var homeButton: Bool { didSet { d.set(homeButton, forKey: "homeButton") } }
    @Published var desktopDefault: Bool { didSet { d.set(desktopDefault, forKey: "desktopDefault") } }
    @Published var engine: SearchEngine { didSet { d.set(engine.rawValue, forKey: "engine") } }
    @Published var theme: AppTheme { didSet { d.set(theme.rawValue, forKey: "theme") } }
    @Published var customFilters: [String] { didSet { saveJSON(customFilters, "customFilters") } }
    @Published var hidden: [String: [String]] { didSet { saveJSON(hidden, "hidden") } }
    @Published var lockedFiles: [String] { didSet { saveJSON(lockedFiles, "lockedFiles") } }
    @Published var wallpaperVersion = 0
    @Published var addressAtBottom: Bool { didSet { d.set(addressAtBottom, forKey: "addressAtBottom") } }
    @Published var appearance: String { didSet { d.set(appearance, forKey: "appearance") } }
    var scheme: ColorScheme? {
        switch appearance { case "light": return .light; case "system": return nil; default: return .dark }
    }

    init() {
        adblock = d.object(forKey: "adblock") as? Bool ?? true
        blockRedirects = d.object(forKey: "blockRedirects") as? Bool ?? true
        warnInsecure = d.object(forKey: "warnInsecure") as? Bool ?? true
        appLock = d.bool(forKey: "appLock")
        homeButton = d.bool(forKey: "homeButton")
        desktopDefault = d.bool(forKey: "desktopDefault")
        engine = SearchEngine(rawValue: d.string(forKey: "engine") ?? "") ?? .duckduckgo
        theme = AppTheme(rawValue: d.string(forKey: "theme") ?? "") ?? .midnight
        addressAtBottom = d.object(forKey: "addressAtBottom") as? Bool ?? true
        appearance = d.string(forKey: "appearance") ?? "dark"
        customFilters = loadJSON("customFilters", [String]())
        hidden = loadJSON("hidden", [String: [String]]())
        lockedFiles = loadJSON("lockedFiles", [String]())
    }

    func resolve(_ input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let u = URL(string: t), let s = u.scheme, ["http", "https", "file", "about"].contains(s) { return u }
        if !t.contains(" "), t.contains("."), let u = URL(string: "https://" + t) { return u }
        return engine.url(for: t)
    }
}

struct VideoCandidate: Hashable { let url: String; let label: String }
struct VideoPicker: Identifiable { let id = UUID(); let title: String; let page: URL?; let candidates: [VideoCandidate] }

final class BrowserStore: ObservableObject {
    @Published var videoPicker: VideoPicker?
    @Published var tabs: [Tab] = []
    @Published var currentID: UUID?
    @Published var bookmarks: [Bookmark] { didSet { saveJSON(bookmarks, "bookmarks") } }
    @Published var history: [HistoryItem] { didSet { saveJSON(Array(history.prefix(1000)), "history") } }
    @Published var speedDial: [Bookmark] { didSet { saveJSON(speedDial, "speedDial") } }

    var current: Tab? { tabs.first { $0.id == currentID } }

    init() {
        bookmarks = loadJSON("bookmarks", [Bookmark]())
        history = loadJSON("history", [HistoryItem]())
        speedDial = loadJSON("speedDial", [
            Bookmark(title: "DuckDuckGo", url: "https://duckduckgo.com"),
            Bookmark(title: "Wikipedia", url: "https://wikipedia.org"),
            Bookmark(title: "YouTube", url: "https://youtube.com"),
            Bookmark(title: "GitHub", url: "https://github.com"),
            Bookmark(title: "Reddit", url: "https://reddit.com"),
            Bookmark(title: "News", url: "https://news.ycombinator.com")
        ])
        newTab()
    }

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false) -> Tab {
        let t = Tab(isPrivate: isPrivate, store: self)
        tabs.append(t)
        currentID = t.id
        if let url { t.load(url) }
        return t
    }

    func close(_ t: Tab) {
        guard let i = tabs.firstIndex(where: { $0.id == t.id }) else { return }
        tabs.remove(at: i)
        if tabs.isEmpty { newTab() }
        else if currentID == t.id { currentID = tabs[min(i, tabs.count - 1)].id }
    }

    func closeAll(private only: Bool? = nil) {
        tabs.removeAll { only == nil || $0.isPrivate == only }
        if tabs.isEmpty { newTab() } else if current == nil { currentID = tabs.first?.id }
    }

    func record(_ tab: Tab) {
        guard !tab.isPrivate, let u = tab.url, u.absoluteString != "about:blank" else { return }
        if history.first?.url == u.absoluteString { return }
        history.insert(HistoryItem(title: tab.title, url: u.absoluteString), at: 0)
    }

    func toggleBookmark(_ tab: Tab) {
        guard let u = tab.url?.absoluteString else { return }
        if let i = bookmarks.firstIndex(where: { $0.url == u }) { bookmarks.remove(at: i) }
        else { bookmarks.append(Bookmark(title: tab.title, url: u)) }
    }
    func isBookmarked(_ tab: Tab) -> Bool {
        guard let u = tab.url?.absoluteString else { return false }
        return bookmarks.contains { $0.url == u }
    }
}
