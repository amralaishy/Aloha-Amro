import Foundation
import CommonCrypto
import AVFoundation

struct HLSVariant: Identifiable {
    let id = UUID()
    let url: URL
    let height: Int
    let bandwidth: Int
    let audio: URL?
    var label: String { height > 0 ? "\(height)p" : (bandwidth > 0 ? "\(bandwidth / 1000) kbps" : "Auto") }
}

enum HLSError: Error { case drm, empty, merge }

enum HLS {
    static func request(_ url: URL, referer: URL?) -> URLRequest {
        var r = URLRequest(url: url)
        if let referer { r.setValue(referer.absoluteString, forHTTPHeaderField: "Referer") }
        return r
    }

    static func fetch(_ url: URL, referer: URL?) async throws -> Data {
        var last: Error = HLSError.empty
        for _ in 0..<3 {
            do {
                let (d, r) = try await URLSession.shared.data(for: request(url, referer: referer))
                if let h = r as? HTTPURLResponse, h.statusCode >= 400 { throw URLError(.badServerResponse) }
                return d
            } catch { last = error }
        }
        throw last
    }

    static func text(_ url: URL, referer: URL?) async throws -> String {
        String(decoding: try await fetch(url, referer: referer), as: UTF8.self)
    }

    static func contentLength(_ url: URL, referer: URL?) async -> String? {
        var r = request(url, referer: referer)
        r.httpMethod = "HEAD"
        guard let (_, resp) = try? await URLSession.shared.data(for: r),
              let h = resp as? HTTPURLResponse, h.statusCode < 400,
              h.expectedContentLength > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: h.expectedContentLength, countStyle: .file)
    }

    static func value(_ line: String) -> String {
        guard let i = line.firstIndex(of: ":") else { return "" }
        return String(line[line.index(after: i)...])
    }

    static func attrs(_ s: String) -> [String: String] {
        var out = [String: String]()
        var key = "", val = ""
        var inKey = true, quoted = false
        for ch in s {
            if inKey {
                if ch == "=" { inKey = false } else { key.append(ch) }
            } else if ch == "\"" {
                quoted.toggle()
            } else if ch == "," && !quoted {
                out[key.trimmingCharacters(in: .whitespaces)] = val
                key = ""; val = ""; inKey = true
            } else { val.append(ch) }
        }
        if !key.isEmpty { out[key.trimmingCharacters(in: .whitespaces)] = val }
        return out
    }

    /// Returns the quality choices of a master playlist (or one entry if the URL is already a media playlist).
    static func variants(_ url: URL, referer: URL?) async throws -> [HLSVariant] {
        let t = try await text(url, referer: referer)
        guard t.contains("#EXT-X-STREAM-INF") else { return [HLSVariant(url: url, height: 0, bandwidth: 0, audio: nil)] }
        let lines = t.components(separatedBy: .newlines)
        var audioGroups = [String: URL]()
        for l in lines where l.hasPrefix("#EXT-X-MEDIA:") {
            let a = attrs(value(l))
            if a["TYPE"] == "AUDIO", let g = a["GROUP-ID"], let u = a["URI"],
               let au = URL(string: u, relativeTo: url)?.absoluteURL, audioGroups[g] == nil || a["DEFAULT"] == "YES" {
                audioGroups[g] = au
            }
        }
        var out = [HLSVariant]()
        var i = 0
        while i < lines.count {
            if lines[i].hasPrefix("#EXT-X-STREAM-INF:") {
                let a = attrs(value(lines[i]))
                var j = i + 1
                while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces).isEmpty || lines[j].hasPrefix("#") { j += 1 }
                if j < lines.count, let u = URL(string: lines[j].trimmingCharacters(in: .whitespaces), relativeTo: url)?.absoluteURL {
                    let h = a["RESOLUTION"].flatMap { Int($0.split(separator: "x").last ?? "") } ?? 0
                    let bw = Int(a["BANDWIDTH"] ?? "") ?? 0
                    out.append(HLSVariant(url: u, height: h, bandwidth: bw, audio: a["AUDIO"].flatMap { audioGroups[$0] }))
                }
                i = j
            }
            i += 1
        }
        return out.sorted { ($0.height, $0.bandwidth) > ($1.height, $1.bandwidth) }
    }

    private static func hex(_ s: String) -> Data? {
        var h = s.lowercased()
        if h.hasPrefix("0x") { h.removeFirst(2) }
        var d = Data()
        var idx = h.startIndex
        while idx < h.endIndex {
            guard let next = h.index(idx, offsetBy: 2, limitedBy: h.endIndex), let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            d.append(b); idx = next
        }
        return d
    }

    private static func decrypt(_ d: Data, key: Data, iv: Data) -> Data? {
        var out = Data(count: d.count + kCCBlockSizeAES128)
        var moved = 0
        let outCount = out.count
        let status: CCCryptorStatus = out.withUnsafeMutableBytes { o in
            d.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, d.count, o.baseAddress, outCount, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return Data(out.prefix(moved))
    }

    /// Downloads every segment of a media playlist into one file at `base` and returns the extension to use ("mp4" or "ts").
    /// Supports AES-128 encryption. Streams protected by real DRM (SAMPLE-AES / FairPlay) can't be saved.
    static func download(playlist: URL, referer: URL?, to base: URL, progress: @escaping (Double) -> Void) async throws -> String {
        let t = try await text(playlist, referer: referer)
        if t.contains("SAMPLE-AES") || t.contains("skd://") { throw HLSError.drm }
        var seq = 0
        var keyURL: URL?, keyIV: Data?
        var method = "NONE"
        var mapURL: URL?
        var segs: [(url: URL, key: URL?, iv: Data?, seq: Int)] = []
        for raw in t.components(separatedBy: .newlines) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { seq = Int(value(l)) ?? 0 }
            else if l.hasPrefix("#EXT-X-KEY:") {
                let a = attrs(value(l))
                method = a["METHOD"] ?? "NONE"
                keyURL = a["URI"].flatMap { URL(string: $0, relativeTo: playlist)?.absoluteURL }
                keyIV = a["IV"].flatMap(hex)
            } else if l.hasPrefix("#EXT-X-MAP:") {
                mapURL = attrs(value(l))["URI"].flatMap { URL(string: $0, relativeTo: playlist)?.absoluteURL }
            } else if !l.isEmpty, !l.hasPrefix("#"), let u = URL(string: l, relativeTo: playlist)?.absoluteURL {
                segs.append((u, method == "AES-128" ? keyURL : nil, keyIV, seq))
                seq += 1
            }
        }
        guard !segs.isEmpty else { throw HLSError.empty }
        let fmp4 = mapURL != nil || ["m4s", "mp4", "cmfv", "cmfa", "m4a"].contains(segs[0].url.pathExtension.lowercased())

        var keys = [URL: Data]()
        for u in Set(segs.compactMap { $0.key }) { keys[u] = try await fetch(u, referer: referer) }

        FileManager.default.createFile(atPath: base.path, contents: nil)
        let fh = try FileHandle(forWritingTo: base)
        defer { try? fh.close() }
        if let m = mapURL { try fh.write(contentsOf: try await fetch(m, referer: referer)) }

        let batch = 6
        var idx = 0
        while idx < segs.count {
            try Task.checkCancellation()
            let range = idx..<min(idx + batch, segs.count)
            var results = [Int: Data]()
            let snapshot = segs
            let keySnapshot = keys
            try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                for i in range {
                    group.addTask {
                        let s = snapshot[i]
                        var d = try await fetch(s.url, referer: referer)
                        if let k = s.key, let kd = keySnapshot[k] {
                            var iv = s.iv ?? Data()
                            if iv.isEmpty {
                                var be = UInt64(s.seq).bigEndian
                                iv = Data(count: 8) + Data(bytes: &be, count: 8)
                            }
                            guard let plain = decrypt(d, key: kd, iv: iv) else { throw HLSError.drm }
                            d = plain
                        }
                        return (i, d)
                    }
                }
                for try await (i, d) in group { results[i] = d }
            }
            for i in range { if let d = results[i] { try fh.write(contentsOf: d) } }
            idx += batch
            progress(min(1, Double(idx) / Double(segs.count)))
        }
        return fmp4 ? "mp4" : "ts"
    }

    /// Joins a separate video-only and audio-only fMP4 into one .mp4 (no re-encoding).
    static func merge(video: URL, audio: URL, to dest: URL) async throws {
        let va = AVURLAsset(url: video), aa = AVURLAsset(url: audio)
        guard let vt = try await va.loadTracks(withMediaType: .video).first,
              let at = try await aa.loadTracks(withMediaType: .audio).first else { throw HLSError.merge }
        let comp = AVMutableComposition()
        guard let cv = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let ca = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw HLSError.merge }
        let vdur = try await va.load(.duration)
        let adur = try await aa.load(.duration)
        try cv.insertTimeRange(CMTimeRange(start: .zero, duration: vdur), of: vt, at: .zero)
        try ca.insertTimeRange(CMTimeRange(start: .zero, duration: CMTimeMinimum(adur, vdur)), of: at, at: .zero)
        cv.preferredTransform = try await vt.load(.preferredTransform)
        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough) else { throw HLSError.merge }
        ex.outputURL = dest
        ex.outputFileType = .mp4
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in ex.exportAsynchronously { c.resume() } }
        guard ex.status == .completed else { throw HLSError.merge }
    }
}
