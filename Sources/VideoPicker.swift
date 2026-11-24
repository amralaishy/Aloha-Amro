import SwiftUI

struct VideoPickerView: View {
    let picker: VideoPicker
    @Environment(\.dismiss) var dismiss

    enum Kind { case direct(URL), hls(HLSVariant) }
    struct Row: Identifiable { let id = UUID(); let title: String; let subtitle: String; let kind: Kind }

    @State private var rows: [Row] = []
    @State private var loading = true
    @State private var sawBlob = false

    var body: some View {
        NavigationStack {
            List {
                if loading { HStack { ProgressView(); Text("Looking for qualities…").foregroundColor(.secondary) } }
                ForEach(rows) { r in
                    Button { start(r); dismiss() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill").font(.title2)
                            VStack(alignment: .leading) {
                                Text(r.title).font(.headline)
                                Text(r.subtitle).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if !loading && rows.isEmpty {
                    Text(sawBlob ? "This site streams the video in a protected way (blob/MSE), so it can't be saved directly."
                                 : "No downloadable video found here.")
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Download video")
            .toolbar { Button("Close") { dismiss() } }
        }
        .presentationDetents([.medium, .large])
        .task { await build() }
    }

    private func clean(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?*\"<>|")
        let t = s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String((t.isEmpty ? "video" : t).prefix(60))
    }

    private func start(_ r: Row) {
        let title = clean(picker.title)
        switch r.kind {
        case .direct(let u):
            let name = r.title == "Original quality" ? title : "\(title) \(r.title)"
            DownloadManager.shared.start(url: u, name: name, referer: picker.page)
        case .hls(let v):
            DownloadManager.shared.startHLS(v, title: title, referer: picker.page)
        }
    }

    @MainActor private func build() async {
        var out: [Row] = []
        var seen = Set<String>()
        for c in picker.candidates.prefix(12) {
            guard let u = URL(string: c.url) else { continue }
            if c.url.hasPrefix("blob:") { sawBlob = true; continue }
            guard seen.insert(c.url).inserted else { continue }
            if u.path.lowercased().contains(".m3u8") {
                if let vs = try? await HLS.variants(u, referer: picker.page) {
                    for v in vs {
                        let rate = v.bandwidth > 0 ? " · \(v.bandwidth / 1000) kbps" : ""
                        out.append(Row(title: v.label, subtitle: "Stream (HLS)\(rate)", kind: .hls(v)))
                    }
                }
            } else {
                let size = await HLS.contentLength(u, referer: picker.page)
                let ext = u.pathExtension.isEmpty ? "VIDEO" : u.pathExtension.uppercased()
                let label = c.label.isEmpty ? "Original quality" : c.label
                out.append(Row(title: label, subtitle: [ext, size].compactMap { $0 }.joined(separator: " · "), kind: .direct(u)))
            }
            rows = out
        }
        loading = false
    }
}
