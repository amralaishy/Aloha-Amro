import SwiftUI
import WebKit

final class DownloadItem: ObservableObject, Identifiable {
    enum State { case running, done, failed }
    let id = UUID()
    @Published var name: String
    @Published var progress = 0.0
    @Published var state = State.running
    var dest: URL?
    var wk: WKDownload?
    var task: URLSessionDownloadTask?
    var obs: NSKeyValueObservation?
    var preferredName: String?
    var job: Task<Void, Never>?
    @Published var note: String?
    init(name: String) { self.name = name }
}

/// Files are streamed straight to disk by WebKit / URLSession, so there is no size cap
/// (the only limit is free storage on the device).
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate, URLSessionDownloadDelegate {
    static let shared = DownloadManager()
    @Published var items: [DownloadItem] = []
    private var wkMap: [ObjectIdentifier: DownloadItem] = [:]
    private var taskMap: [Int: DownloadItem] = [:]
    private var bgTask = UIBackgroundTaskIdentifier.invalid
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func uniqueURL(_ dir: URL, _ name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "_")
        var u = dir.appendingPathComponent(clean)
        var n = 1
        let ext = u.pathExtension
        let base = u.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return u
    }

    private func updateBackground() {
        let running = items.contains { $0.state == .running }
        if running, bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask { [weak self] in
                guard let self else { return }
                UIApplication.shared.endBackgroundTask(self.bgTask); self.bgTask = .invalid
            }
        } else if !running, bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        }
    }

    // MARK: direct URL downloads
    func start(url: URL, name: String? = nil, referer: URL? = nil) {
        let item = DownloadItem(name: name ?? (url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent))
        if let name {
            let e = url.pathExtension
            item.preferredName = (e.isEmpty || e.count > 5) ? name + ".mp4" : name + "." + e
        }
        var req = URLRequest(url: url)
        if let referer { req.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        let t = session.downloadTask(with: req)
        item.task = t
        taskMap[t.taskIdentifier] = item
        items.insert(item, at: 0)
        t.resume()
        updateBackground()
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten w: Int64, totalBytesExpectedToWrite e: Int64) {
        if e > 0 { taskMap[t.taskIdentifier]?.progress = Double(w) / Double(e) }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = taskMap[t.taskIdentifier] else { return }
        if let h = t.response as? HTTPURLResponse, h.statusCode >= 400 {
            item.state = .failed; item.note = "Server refused the download (HTTP \(h.statusCode))"
            try? FileManager.default.removeItem(at: location)
            updateBackground(); return
        }
        let name = item.preferredName ?? t.response?.suggestedFilename ?? item.name
        let dest = uniqueURL(Paths.downloads, name)
        do {
            try FileManager.default.moveItem(at: location, to: dest)
            item.dest = dest; item.name = dest.lastPathComponent; item.progress = 1; item.state = .done
        } catch { item.state = .failed }
        updateBackground()
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil, let item = taskMap[t.taskIdentifier], item.state == .running {
            item.state = .failed
            updateBackground()
        }
    }

    // MARK: WKDownload (links, attachments, unknown MIME types)
    func download(_ d: WKDownload, decideDestinationUsing r: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = uniqueURL(Paths.downloads, suggestedFilename)
        let item = DownloadItem(name: dest.lastPathComponent)
        item.dest = dest
        item.wk = d
        item.obs = d.progress.observe(\.fractionCompleted) { p, _ in
            DispatchQueue.main.async { item.progress = p.fractionCompleted }
        }
        wkMap[ObjectIdentifier(d)] = item
        items.insert(item, at: 0)
        updateBackground()
        completionHandler(dest)
    }

    func downloadDidFinish(_ d: WKDownload) {
        wkMap[ObjectIdentifier(d)]?.state = .done
        wkMap[ObjectIdentifier(d)]?.progress = 1
        updateBackground()
    }

    func download(_ d: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        wkMap[ObjectIdentifier(d)]?.state = .failed
        updateBackground()
    }

    func startHLS(_ v: HLSVariant, title: String, referer: URL?) {
        let item = DownloadItem(name: "\(title) \(v.label)")
        items.insert(item, at: 0)
        updateBackground()
        let hasAudio = v.audio != nil
        item.job = Task {
            let tmp = FileManager.default.temporaryDirectory
            var temps: [URL] = []
            defer { temps.forEach { try? FileManager.default.removeItem(at: $0) } }
            do {
                let vBase = tmp.appendingPathComponent(UUID().uuidString)
                let ext = try await HLS.download(playlist: v.url, referer: referer, to: vBase) { p in
                    DispatchQueue.main.async { item.progress = hasAudio ? p * 0.8 : p }
                }
                let vFile = vBase.appendingPathExtension(ext)
                try FileManager.default.moveItem(at: vBase, to: vFile)
                temps.append(vFile)
                let dest = self.uniqueURL(Paths.downloads, "\(title) \(v.label).\(ext)")
                if let a = v.audio, ext == "mp4" {
                    let aBase = tmp.appendingPathComponent(UUID().uuidString)
                    let aExt = try await HLS.download(playlist: a, referer: referer, to: aBase) { p in
                        DispatchQueue.main.async { item.progress = 0.8 + p * 0.15 }
                    }
                    let aFile = aBase.appendingPathExtension(aExt)
                    try FileManager.default.moveItem(at: aBase, to: aFile)
                    temps.append(aFile)
                    try await HLS.merge(video: vFile, audio: aFile, to: dest)
                } else {
                    try FileManager.default.moveItem(at: vFile, to: dest)
                }
                await MainActor.run {
                    item.dest = dest; item.name = dest.lastPathComponent
                    item.progress = 1; item.state = .done
                    self.updateBackground()
                }
            } catch {
                await MainActor.run {
                    item.state = .failed
                    if case HLSError.drm = error { item.note = "DRM-protected, can't be saved" }
                    else if error is CancellationError { item.note = "Cancelled" }
                    else { item.note = "Download failed" }
                    self.updateBackground()
                }
            }
        }
    }

    func cancel(_ item: DownloadItem) {
        item.job?.cancel()
        item.wk?.cancel { _ in }
        item.task?.cancel()
        item.state = .failed
        updateBackground()
    }

    func remove(_ item: DownloadItem) { items.removeAll { $0.id == item.id } }
}

struct DownloadsView: View {
    @ObservedObject var dm = DownloadManager.shared
    @State private var urlText = ""
    var body: some View {
        NavigationStack {
            List {
                Section("Download from URL") {
                    HStack {
                        TextField("https://…", text: $urlText)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Button("Get") {
                            if let u = URL(string: urlText), u.scheme?.hasPrefix("http") == true {
                                dm.start(url: u); urlText = ""
                            }
                        }
                    }
                }
                Section("Downloads") {
                    ForEach(dm.items) { DownloadRow(item: $0) }
                        .onDelete { idx in idx.forEach { dm.remove(dm.items[$0]) } }
                }
            }
            .navigationTitle("Downloads")
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).lineLimit(1)
            switch item.state {
            case .running:
                HStack {
                    ProgressView(value: item.progress)
                    Button { DownloadManager.shared.cancel(item) } label: { Image(systemName: "xmark.circle") }
                }
            case .done: Label("Saved to Files › Downloads", systemImage: "checkmark.circle").font(.caption).foregroundColor(.green)
            case .failed: Label(item.note ?? "Failed", systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.red)
            }
        }
    }
}
