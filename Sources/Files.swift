import SwiftUI
import QuickLook
import ZIPFoundation

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> QLPreviewController {
        let c = QLPreviewController(); c.dataSource = context.coordinator; return c
    }
    func updateUIViewController(_ c: QLPreviewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(url) }
    final class Coord: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(_ u: URL) { url = u }
        func numberOfPreviewItems(in c: QLPreviewController) -> Int { 1 }
        func previewController(_ c: QLPreviewController, previewItemAt i: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct FilesRootView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink { FolderView(dir: Paths.downloads, title: "Downloads", isTrash: false) } label: { Label("Downloads", systemImage: "folder") }
                NavigationLink { FolderView(dir: Paths.trash, title: "Trash", isTrash: true) } label: { Label("Trash", systemImage: "trash") }
            }.navigationTitle("Files")
        }
    }
}

struct FolderView: View {
    let dir: URL
    let title: String
    let isTrash: Bool
    @EnvironmentObject var settings: Settings
    @State private var entries: [URL] = []
    @State private var preview: URL?
    @State private var playing: URL?
    @State private var trimming: URL?
    @State private var renaming: URL?
    @State private var newName = ""
    @State private var moving: URL?
    @State private var info: String?

    private let mediaExt = ["mp4", "m4v", "mov", "mp3", "m4a", "aac", "wav", "flac", "caf", "aiff"]
    private let videoExt = ["mp4", "m4v", "mov"]

    private func isDir(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
    private func rel(_ u: URL) -> String { u.path.replacingOccurrences(of: Paths.documents.path, with: "") }
    private func locked(_ u: URL) -> Bool { settings.lockedFiles.contains(rel(u)) }
    private func size(_ u: URL) -> String {
        let n = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    var body: some View {
        List {
            if entries.isEmpty { Text("Empty").foregroundColor(.secondary) }
            ForEach(entries, id: \.self) { u in
                if isDir(u) {
                    NavigationLink { FolderView(dir: u, title: u.lastPathComponent, isTrash: isTrash) } label: {
                        Label(u.lastPathComponent, systemImage: "folder")
                    }.contextMenu { menu(u) }
                } else {
                    Button { open(u) } label: {
                        HStack {
                            Image(systemName: locked(u) ? "lock.fill" : icon(u))
                            VStack(alignment: .leading) { Text(u.lastPathComponent).lineLimit(1); Text(size(u)).font(.caption).foregroundColor(.secondary) }
                        }
                    }.contextMenu { menu(u) }
                }
            }
        }
        .navigationTitle(title)
        .toolbar {
            if !isTrash { Button { newFolder() } label: { Image(systemName: "folder.badge.plus") } }
            else { Button("Empty", role: .destructive) { entries.forEach { try? FileManager.default.removeItem(at: $0) }; reload() } }
        }
        .onAppear(perform: reload)
        .refreshable { reload() }
        .fullScreenCover(item: $playing) { PlayerView(url: $0) }
        .sheet(item: $preview) { QuickLookView(url: $0) }
        .sheet(item: $trimming) { TrimView(url: $0, onDone: reload) }
        .sheet(item: $renaming) { u in
            NavigationStack {
                Form { TextField("Name", text: $newName).textInputAutocapitalization(.never) }
                    .navigationTitle("Rename")
                    .toolbar { Button("Save") { rename(u); renaming = nil } }
            }.presentationDetents([.height(200)])
        }
        .sheet(item: $moving) { u in MoveSheet(item: u) { reload() } }
        .alert(info ?? "", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) { Button("OK") {} }
    }

    private func icon(_ u: URL) -> String {
        let e = u.pathExtension.lowercased()
        if videoExt.contains(e) { return "film" }
        if mediaExt.contains(e) { return "music.note" }
        if e == "pdf" { return "doc.richtext" }
        if e == "zip" { return "doc.zipper" }
        if ["ts", "m2ts", "mts"].contains(e) { return "film.stack" }
        return "doc"
    }

    @ViewBuilder private func menu(_ u: URL) -> some View {
        if isTrash {
            Button { restore(u) } label: { Label("Restore", systemImage: "arrow.uturn.backward") }
            Button(role: .destructive) { try? FileManager.default.removeItem(at: u); reload() } label: { Label("Delete forever", systemImage: "trash") }
        } else {
            Button { newName = u.lastPathComponent; renaming = u } label: { Label("Rename", systemImage: "pencil") }
            Button { moving = u } label: { Label("Move…", systemImage: "folder") }
            ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") }
            if !isDir(u) {
                Button { toggleLock(u) } label: { Label(locked(u) ? "Remove lock" : "Lock with Face ID", systemImage: "lock") }
            }
            if videoExt.contains(u.pathExtension.lowercased()) {
                Button { auth(u) { trimming = u } } label: { Label("Trim video", systemImage: "scissors") }
            }
            if ["ts", "m2ts", "mts"].contains(u.pathExtension.lowercased()) {
                Button { convertToMP4(u) } label: { Label("Convert to MP4", systemImage: "film") }
            }
            if u.pathExtension.lowercased() == "zip" {
                Button { extract(u) } label: { Label("Extract", systemImage: "arrow.down.doc") }
            } else {
                Button { compress(u) } label: { Label("Compress to ZIP", systemImage: "doc.zipper") }
            }
            Button(role: .destructive) { trash(u) } label: { Label("Move to Trash", systemImage: "trash") }
        }
    }

    private func auth(_ u: URL, _ then: @escaping () -> Void) {
        if locked(u) { Auth.authenticate(reason: "Open protected file") { if $0 { then() } } } else { then() }
    }

    private func open(_ u: URL) {
        auth(u) {
            let e = u.pathExtension.lowercased()
            if mediaExt.contains(e) { playing = u } else { preview = u }
        }
    }

    private func reload() {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        entries = all.sorted { (isDir($0) ? 0 : 1, $0.lastPathComponent.lowercased()) < (isDir($1) ? 0 : 1, $1.lastPathComponent.lowercased()) }
    }

    private func newFolder() {
        let u = DownloadManager.shared.uniqueURL(dir, "New Folder")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        reload()
    }

    private func rename(_ u: URL) {
        let dest = u.deletingLastPathComponent().appendingPathComponent(newName)
        guard !newName.isEmpty, (try? FileManager.default.moveItem(at: u, to: dest)) != nil else { return }
        if let i = settings.lockedFiles.firstIndex(of: rel(u)) { settings.lockedFiles[i] = rel(dest) }
        reload()
    }

    private func trash(_ u: URL) {
        let dest = DownloadManager.shared.uniqueURL(Paths.trash, u.lastPathComponent)
        try? FileManager.default.moveItem(at: u, to: dest)
        reload()
    }

    private func restore(_ u: URL) {
        let dest = DownloadManager.shared.uniqueURL(Paths.downloads, u.lastPathComponent)
        try? FileManager.default.moveItem(at: u, to: dest)
        reload()
    }

    private func toggleLock(_ u: URL) {
        if let i = settings.lockedFiles.firstIndex(of: rel(u)) {
            Auth.authenticate(reason: "Remove lock") { if $0 { settings.lockedFiles.remove(at: i) } }
        } else { settings.lockedFiles.append(rel(u)) }
    }

    private func convertToMP4(_ u: URL) {
        info = "Converting to MP4 in the background. Check this folder in a minute."
        let dest = DownloadManager.shared.uniqueURL(u.deletingLastPathComponent(), u.deletingPathExtension().lastPathComponent + ".mp4")
        Task.detached(priority: .userInitiated) {
            do {
                try TSRemux.convert(ts: u, to: dest)
                await MainActor.run { info = "Converted: \(dest.lastPathComponent)"; reload() }
            } catch {
                await MainActor.run { info = "Couldn't convert this file. Only H.264 video with AAC audio is supported." }
            }
        }
    }

    private func compress(_ u: URL) {
        let dest = DownloadManager.shared.uniqueURL(dir, u.deletingPathExtension().lastPathComponent + ".zip")
        do { try FileManager.default.zipItem(at: u, to: dest); reload() } catch { info = "Compression failed" }
    }

    private func extract(_ u: URL) {
        let dest = DownloadManager.shared.uniqueURL(dir, u.deletingPathExtension().lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            try FileManager.default.unzipItem(at: u, to: dest)
            reload()
        } catch { info = "Could not extract this archive" }
    }
}

extension URL: Identifiable { public var id: String { absoluteString } }

struct MoveSheet: View {
    let item: URL
    let done: () -> Void
    @Environment(\.dismiss) var dismiss

    private func folders() -> [URL] {
        var out: [URL] = [Paths.downloads]
        if let en = FileManager.default.enumerator(at: Paths.downloads, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in en where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && u != item {
                out.append(u)
            }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            List(folders(), id: \.self) { f in
                Button(f.path.replacingOccurrences(of: Paths.documents.path + "/", with: "")) {
                    let dest = DownloadManager.shared.uniqueURL(f, item.lastPathComponent)
                    try? FileManager.default.moveItem(at: item, to: dest)
                    done(); dismiss()
                }
            }.navigationTitle("Move to")
        }
    }
}
