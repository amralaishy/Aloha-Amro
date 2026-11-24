import SwiftUI
import WebKit
import PhotosUI

enum Sheet: Identifiable {
    case tabs, bookmarks, history, settings, files, downloads, qr, media([String]), hidden, passwords
    var id: String {
        switch self {
        case .tabs: return "tabs"; case .bookmarks: return "bookmarks"; case .history: return "history"
        case .settings: return "settings"; case .files: return "files"; case .downloads: return "downloads"
        case .qr: return "qr"; case .media: return "media"; case .hidden: return "hidden"; case .passwords: return "passwords"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: BrowserStore
    var body: some View {
        if let t = store.current { BrowserPage(tab: t).id(t.id) }
    }
}

struct WebViewHost: UIViewRepresentable {
    let tab: Tab
    func makeUIView(context: Context) -> WKWebView { tab.webView }
    func updateUIView(_ v: WKWebView, context: Context) {}
}

struct BrowserPage: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings
    @State private var text = ""
    @FocusState private var focused: Bool
    @State private var sheet: Sheet?
    @State private var showFind = false
    @State private var findText = ""
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            if !settings.addressAtBottom { chrome }
            ZStack {
                if tab.isHome { HomeView(tab: tab) } else { WebViewHost(tab: tab) }
                if let toast {
                    Text(toast).padding(10).background(.ultraThinMaterial, in: Capsule())
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 20)
                }
            }
            .sheet(item: $store.videoPicker) { p in VideoPickerView(picker: p) }
            if settings.addressAtBottom { chrome }
            bottomBar
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .tabs: TabManagerView()
            case .bookmarks: BookmarksView(tab: tab)
            case .history: HistoryView(tab: tab)
            case .settings: SettingsView()
            case .files: FilesRootView()
            case .downloads: DownloadsView()
            case .qr: QRScannerView { code in sheet = nil; open(code) }
            case .media(let links): MediaListView(links: links)
            case .hidden: HiddenView()
            case .passwords: PasswordsView()
            }
        }
        .onChange(of: tab.url) { u in if !focused { text = u?.absoluteString ?? "" } }
        .onAppear { text = tab.url?.absoluteString ?? "" }
    }

    private func open(_ s: String) {
        if let u = settings.resolve(s) { tab.load(u) }
    }

    private func flash(_ m: String) {
        toast = m
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { toast = nil }
    }

    private var chrome: some View {
        VStack(spacing: 0) {
            if showFind { findBar }
            addressBar
            if tab.isLoading { ProgressView(value: tab.progress).progressViewStyle(.linear) }
        }
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            if tab.isPrivate { Image(systemName: "eye.slash.fill").foregroundColor(.purple) }
            HStack {
                Image(systemName: tab.url?.scheme == "https" ? "lock.fill" : "magnifyingglass")
                    .foregroundColor(.secondary).font(.caption)
                TextField("Search or enter address", text: $text)
                    .focused($focused)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.webSearch)
                    .submitLabel(.go)
                    .onSubmit { open(text) }
                Button {
                    if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
                } label: { Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise") }
                .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10).background(Color(.secondarySystemBackground), in: Capsule())
            .overlay(Capsule().stroke(focused ? settings.theme.accent : Color.clear, lineWidth: 1.5))
        }
        .padding(.horizontal).padding(.vertical, 6)
    }

    private var findBar: some View {
        HStack {
            TextField("Find in page", text: $findText).textFieldStyle(.roundedBorder)
                .onSubmit { find(false) }
            Button { find(true) } label: { Image(systemName: "chevron.up") }
            Button { find(false) } label: { Image(systemName: "chevron.down") }
            Button("Done") { showFind = false }
        }.padding(.horizontal).padding(.bottom, 6)
    }

    private func find(_ back: Bool) {
        let c = WKFindConfiguration(); c.backwards = back; c.wraps = true
        tab.webView.find(findText, configuration: c) { _ in }
    }

    private var bottomBar: some View {
        HStack {
            Button { tab.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!tab.canGoBack)
            Spacer()
            if settings.homeButton {
                Button { tab.goHome() } label: { Image(systemName: "house") }
            } else {
                Button { tab.webView.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!tab.canGoForward)
            }
            Spacer()
            Button { sheet = .tabs } label: {
                Text("\(store.tabs.count)").font(.caption.bold()).frame(width: 24, height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(lineWidth: 2))
            }
            Spacer()
            Button { sheet = .downloads } label: { Image(systemName: "arrow.down.circle") }
            Spacer()
            menu
        }
        .font(.title3).padding(.horizontal, 24).padding(.vertical, 10)
        .background(.bar)
    }

    private var menu: some View {
        Menu {
            Button { store.newTab() } label: { Label("New tab", systemImage: "plus") }
            Button { store.newTab(isPrivate: true) } label: { Label("New private tab", systemImage: "eye.slash") }
            Divider()
            Button { store.toggleBookmark(tab) } label: {
                Label(store.isBookmarked(tab) ? "Remove bookmark" : "Add bookmark", systemImage: store.isBookmarked(tab) ? "bookmark.slash" : "bookmark")
            }.disabled(tab.isHome)
            Button { sheet = .bookmarks } label: { Label("Bookmarks", systemImage: "book") }
            Button { sheet = .history } label: { Label("History", systemImage: "clock") }
            Button { sheet = .files } label: { Label("Files", systemImage: "folder") }
            Divider()
            Button { tab.toggleDesktop() } label: { Label(tab.desktop ? "Mobile site" : "Desktop site", systemImage: "desktopcomputer") }
            Button { showFind = true } label: { Label("Find in page", systemImage: "magnifyingglass") }
            Button { tab.mediaLinks { sheet = .media($0) } } label: { Label("Download media on page", systemImage: "square.and.arrow.down") }
            Button { tab.savePagePDF { flash($0 ? "Saved full page as PDF" : "Could not save") } } label: { Label("Full-page screenshot (PDF)", systemImage: "camera.viewfinder") }
            Button { tab.pickElementToHide(); flash("Tap the element to hide") } label: { Label("Hide an element", systemImage: "eye.slash.circle") }
            if let u = tab.url, !tab.isHome { ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") } }
            Divider()
            Button { sheet = .qr } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
            Button { sheet = .settings } label: { Label("Settings", systemImage: "gear") }
        } label: { Image(systemName: "ellipsis.circle") }
    }
}

struct HomeView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @EnvironmentObject var settings: Settings

    var body: some View {
        ZStack {
            if let img = UIImage(contentsOfFile: Paths.wallpaper.path), settings.wallpaperVersion >= 0 {
                Image(uiImage: img).resizable().scaledToFill().ignoresSafeArea()
            } else {
                LinearGradient(colors: settings.theme.colors, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            }
            VStack(spacing: 24) {
                if tab.isPrivate {
                    Label("Private tab: no history or cookies are kept", systemImage: "eye.slash")
                        .padding(8).background(.ultraThinMaterial, in: Capsule())
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 20) {
                    ForEach(store.speedDial) { item in
                        Button { if let u = URL(string: item.url) { tab.load(u) } } label: {
                            VStack {
                                Text(String(item.title.prefix(1)).uppercased()).font(.title.bold())
                                    .frame(width: 60, height: 60).background(LinearGradient(colors: [settings.theme.accent, settings.theme.accent.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 18))
                                Text(item.title).font(.caption).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { store.speedDial.removeAll { $0.id == item.id } } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                }.padding(.horizontal)
                Spacer()
            }
            .padding(.top, 40).foregroundColor(.white)
        }
    }
}

struct MediaListView: View {
    let links: [String]
    var body: some View {
        NavigationStack {
            List {
                if links.isEmpty {
                    Text("No downloadable media found. Streams that use blob: URLs can't be saved this way.").foregroundColor(.secondary)
                }
                ForEach(links, id: \.self) { l in
                    Button { if let u = URL(string: l) { DownloadManager.shared.start(url: u) } } label: {
                        VStack(alignment: .leading) {
                            Text(URL(string: l)?.lastPathComponent ?? l).lineLimit(1)
                            Text(l).font(.caption2).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }.navigationTitle("Media on this page")
        }
    }
}

struct TabManagerView: View {
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) var dismiss
    @State private var showPrivate = false
    let groups = ["None", "Work", "Personal", "Shopping", "Research"]

    var body: some View {
        NavigationStack {
            VStack {
                Picker("", selection: $showPrivate) {
                    Text("Tabs").tag(false); Text("Private").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                ScrollView {
                    let shown = store.tabs.filter { $0.isPrivate == showPrivate }
                    ForEach(groups, id: \.self) { g in
                        let inGroup = shown.filter { $0.group == g }
                        if !inGroup.isEmpty {
                            Text(g == "None" ? "Ungrouped" : g).font(.headline)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                                ForEach(inGroup) { t in TabCard(tab: t, dismiss: dismiss) }
                            }.padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("Tabs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close all", role: .destructive) { store.closeAll(private: showPrivate); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { store.newTab(isPrivate: showPrivate); dismiss() } label: { Image(systemName: "plus") }
                }
            }
        }
    }
}

struct TabCard: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    let dismiss: DismissAction
    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(tab.title).font(.subheadline.bold()).lineLimit(1)
                Spacer()
                Button { store.close(tab) } label: { Image(systemName: "xmark.circle.fill") }.foregroundColor(.secondary)
            }
            Text(tab.url?.host ?? "Home").font(.caption).foregroundColor(.secondary).lineLimit(1)
        }
        .padding().frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(store.currentID == tab.id ? Color.accentColor : .clear, lineWidth: 2))
        .onTapGesture { store.currentID = tab.id; dismiss() }
        .contextMenu {
            Menu("Move to group") {
                ForEach(["None", "Work", "Personal", "Shopping", "Research"], id: \.self) { g in
                    Button(g) { tab.group = g; store.objectWillChange.send() }
                }
            }
        }
    }
}

struct BookmarksView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.bookmarks) { b in
                    Button { if let u = URL(string: b.url) { tab.load(u); dismiss() } } label: {
                        VStack(alignment: .leading) { Text(b.title); Text(b.url).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                    }
                    .contextMenu {
                        Button { store.speedDial.append(b) } label: { Label("Add to Speed Dial", systemImage: "square.grid.2x2") }
                    }
                }
                .onDelete { store.bookmarks.remove(atOffsets: $0) }
                .onMove { store.bookmarks.move(fromOffsets: $0, toOffset: $1) }
            }
            .navigationTitle("Bookmarks").toolbar { EditButton() }
        }
    }
}

struct HistoryView: View {
    @ObservedObject var tab: Tab
    @EnvironmentObject var store: BrowserStore
    @Environment(\.dismiss) var dismiss
    @State private var q = ""
    var body: some View {
        NavigationStack {
            List {
                ForEach(store.history.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }) { h in
                    Button { if let u = URL(string: h.url) { tab.load(u); dismiss() } } label: {
                        VStack(alignment: .leading) { Text(h.title).lineLimit(1); Text(h.url).font(.caption).foregroundColor(.secondary).lineLimit(1) }
                    }
                }
                .onDelete { idx in
                    let ids = idx.map { store.history[$0].id }
                    store.history.removeAll { ids.contains($0.id) }
                }
            }
            .searchable(text: $q)
            .navigationTitle("History")
            .toolbar { Button("Clear", role: .destructive) { store.history = [] } }
        }
    }
}

struct HiddenView: View {
    @EnvironmentObject var settings: Settings
    var body: some View {
        NavigationStack {
            List {
                ForEach(settings.hidden.keys.sorted(), id: \.self) { host in
                    Section(host) {
                        ForEach(settings.hidden[host] ?? [], id: \.self) { Text($0).font(.caption2).lineLimit(2) }
                            .onDelete { idx in settings.hidden[host]?.remove(atOffsets: idx) }
                    }
                }
            }
            .navigationTitle("Hidden by me")
            .toolbar { Button("Reset all", role: .destructive) { settings.hidden = [:] } }
        }
    }
}

struct PasswordsView: View {
    @State private var items = Keychain.all()
    var body: some View {
        NavigationStack {
            List {
                ForEach(items) { e in
                    VStack(alignment: .leading) { Text(e.host); Text(e.user).font(.caption).foregroundColor(.secondary) }
                }.onDelete { idx in
                    idx.forEach { Keychain.delete(host: items[$0].host, user: items[$0].user) }
                    items = Keychain.all()
                }
            }.navigationTitle("Saved passwords")
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var store: BrowserStore
    @ObservedObject var wifi = WifiServer.shared
    @State private var newFilter = ""
    @State private var filterMsg = ""
    @State private var photo: PhotosPickerItem?
    @State private var sheet: Sheet?

    var body: some View {
        NavigationStack {
            Form {
                Section("Privacy & blocking") {
                    Toggle("Block ads & trackers", isOn: $settings.adblock)
                    Toggle("Block redirects to other apps", isOn: $settings.blockRedirects)
                    Toggle("Warn before sending insecure forms", isOn: $settings.warnInsecure)
                    Toggle("Lock app with Face ID / passcode", isOn: $settings.appLock)
                    Button("Hidden by me") { sheet = .hidden }
                    Button("Saved passwords") { sheet = .passwords }
                    Button("Clear cookies & website data", role: .destructive) {
                        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
                    }
                }
                Section {
                    ForEach(settings.customFilters, id: \.self) { f in Text(f).font(.caption).lineLimit(1) }
                        .onDelete { $0.forEach { AdBlock.shared.removeFilter(url: settings.customFilters[$0]) } }
                    HStack {
                        TextField("Filter list URL", text: $newFilter).textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Add") {
                            AdBlock.shared.addFilter(url: newFilter) { ok in filterMsg = ok ? "Added" : "Failed"; if ok { newFilter = "" } }
                        }
                    }
                    if !filterMsg.isEmpty { Text(filterMsg).font(.caption) }
                } header: { Text("Custom filter lists") } footer: { Text("Supports ||domain^ and ##selector rules, e.g. an EasyList URL.") }
                Section("Browsing") {
                    Picker("Search engine", selection: $settings.engine) { ForEach(SearchEngine.allCases) { Text($0.rawValue).tag($0) } }
                    Toggle("Desktop site by default", isOn: $settings.desktopDefault)
                    Toggle("Home button instead of Forward", isOn: $settings.homeButton)
                }
                Section("Appearance") {
                    Picker("Theme", selection: $settings.theme) { ForEach(AppTheme.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    Picker("Appearance", selection: $settings.appearance) {
                        Text("Dark").tag("dark"); Text("Light").tag("light"); Text("System").tag("system")
                    }
                    Toggle("Address bar at bottom", isOn: $settings.addressAtBottom)
                    PhotosPicker("Choose wallpaper", selection: $photo, matching: .images)
                    Button("Remove wallpaper") { try? FileManager.default.removeItem(at: Paths.wallpaper); settings.wallpaperVersion += 1 }
                }
                Section {
                    Toggle("Wi-Fi file sharing", isOn: Binding(get: { wifi.running }, set: { $0 ? wifi.start() : wifi.stop() }))
                    if wifi.running, let a = wifi.address { Text(a).font(.callout.monospaced()) }
                } header: { Text("Sharing") } footer: { Text("Open the address in a browser on the same Wi-Fi to download or upload files in Downloads.") }
            }
            .navigationTitle("Settings")
            .onChange(of: photo) { item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data),
                       let jpg = img.jpegData(compressionQuality: 0.85) {
                        try? jpg.write(to: Paths.wallpaper); settings.wallpaperVersion += 1
                    }
                }
            }
            .sheet(item: $sheet) { s in
                if case .hidden = s { HiddenView() } else { PasswordsView() }
            }
        }
    }
}
