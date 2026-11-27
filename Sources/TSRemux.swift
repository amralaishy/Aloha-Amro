import Foundation

enum RemuxError: Error { case unsupported(String), noVideo, badStream(String) }
struct RemuxFailure: Error { let text: String }

fileprivate func readPTS(_ b: [UInt8], _ i: Int) -> Int64 {
    (Int64(b[i] & 0x0E) << 29) | (Int64(b[i + 1]) << 22) | (Int64(b[i + 2] & 0xFE) << 14) | (Int64(b[i + 3]) << 7) | (Int64(b[i + 4]) >> 1)
}

// MARK: - tiny MP4 box helpers
fileprivate func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
fileprivate func be32(_ v: Int) -> [UInt8] { [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
fileprivate func s32(_ v: Int) -> [UInt8] { be32(Int(UInt32(bitPattern: Int32(truncatingIfNeeded: v)))) }
fileprivate func be64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> UInt64(56 - 8 * $0)) & 0xFF) } }
fileprivate func zeros(_ n: Int) -> [UInt8] { [UInt8](repeating: 0, count: n) }
fileprivate func boxA(_ type: String, _ parts: [[UInt8]]) -> [UInt8] {
    var body = [UInt8]()
    for p in parts { body.append(contentsOf: p) }
    return be32(body.count + 8) + Array(type.utf8) + body
}
fileprivate func box(_ type: String, _ parts: [UInt8]...) -> [UInt8] { boxA(type, parts) }
fileprivate func fullbox(_ type: String, _ ver: Int, _ flags: Int, _ parts: [UInt8]...) -> [UInt8] {
    boxA(type, [be32((ver << 24) | flags)] + parts)
}
fileprivate func runs(_ v: [Int]) -> [(count: Int, value: Int)] {
    var out: [(count: Int, value: Int)] = []
    for x in v {
        if let last = out.last, last.value == x { out[out.count - 1].count += 1 } else { out.append((1, x)) }
    }
    return out
}
fileprivate func pairs(_ r: [(count: Int, value: Int)]) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(r.count * 8)
    for e in r { out += be32(e.count); out += be32(e.value) }
    return out
}

// MARK: - H.264 SPS parsing (for picture size)
fileprivate struct BitReader {
    let b: [UInt8]
    var p = 0
    init(_ b: [UInt8]) { self.b = b }
    mutating func u(_ n: Int) -> Int {
        var v = 0
        for _ in 0..<n {
            let idx = p >> 3
            let byte = idx < b.count ? Int(b[idx]) : 0
            v = (v << 1) | ((byte >> (7 - (p & 7))) & 1)
            p += 1
        }
        return v
    }
    mutating func ue() -> Int {
        var z = 0
        while z < 32 {
            if u(1) == 1 { break }
            z += 1
        }
        return z == 0 ? 0 : (1 << z) - 1 + u(z)
    }
    mutating func se() -> Int {
        let k = ue()
        return (k & 1) == 1 ? (k + 1) / 2 : -(k / 2)
    }
}

fileprivate struct SPSInfo { var profile = 0, level = 0, chroma = 1, bdl = 0, bdc = 0, width = 0, height = 0 }

fileprivate func unescape(_ nal: ArraySlice<UInt8>) -> [UInt8] {
    var out = [UInt8]()
    out.reserveCapacity(nal.count)
    var z = 0
    for c in nal {
        if z >= 2 && c == 3 { z = 0; continue }
        out.append(c)
        z = (c == 0) ? z + 1 : 0
    }
    return out
}

fileprivate func parseSPS(_ sps: [UInt8]) -> SPSInfo {
    var r = BitReader(unescape(sps[1...]))
    var i = SPSInfo()
    i.profile = r.u(8)
    _ = r.u(8)
    i.level = r.u(8)
    _ = r.ue()
    if [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135].contains(i.profile) {
        i.chroma = r.ue()
        if i.chroma == 3 { _ = r.u(1) }
        i.bdl = r.ue()
        i.bdc = r.ue()
        _ = r.u(1)
        if r.u(1) == 1 {
            let lists = i.chroma != 3 ? 8 : 12
            for k in 0..<lists {
                if r.u(1) == 1 {
                    let size = k < 6 ? 16 : 64
                    var last = 8, next = 8
                    for _ in 0..<size {
                        if next != 0 { next = (last + r.se() + 256) % 256 }
                        last = (next == 0) ? last : next
                    }
                }
            }
        }
    }
    _ = r.ue()
    let poc = r.ue()
    if poc == 0 {
        _ = r.ue()
    } else if poc == 1 {
        _ = r.u(1); _ = r.se(); _ = r.se()
        let n = min(r.ue(), 255)
        for _ in 0..<n { _ = r.se() }
    }
    _ = r.ue()
    _ = r.u(1)
    let w = (r.ue() + 1) * 16
    var h = (r.ue() + 1) * 16
    let fmo = r.u(1)
    if fmo == 0 { _ = r.u(1) }
    h *= (2 - fmo)
    _ = r.u(1)
    var cl = 0, cr = 0, ct = 0, cb = 0
    if r.u(1) == 1 { cl = r.ue(); cr = r.ue(); ct = r.ue(); cb = r.ue() }
    let cux = (i.chroma == 1 || i.chroma == 2) ? 2 : 1
    let cuy = (i.chroma == 1 ? 2 : 1) * (2 - fmo)
    i.width = w - (cl + cr) * cux
    i.height = h - (ct + cb) * cuy
    if i.width <= 0 || i.height <= 0 { i.width = w; i.height = h }
    return i
}

// MARK: - TS -> MP4
/// Repackages an MPEG transport stream (H.264 video + AAC audio) as an MP4 without re-encoding.
/// Streams from disk and writes its own MP4 boxes, so there is no size limit and no dependency on AVAssetWriter.
final class TSRemux {
    struct VSample { var data: [UInt8]; var pts: Int64; var dts: Int64; var dur: Int64; var key: Bool }

    static func describe(_ e: Error) -> String { (e as? RemuxFailure)?.text ?? e.localizedDescription }

    /// Returns true when the stream had audio that couldn't be carried over (not AAC).
    @discardableResult
    static func convert(ts: URL, to mp4: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> Bool {
        let r = TSRemux(src: ts, dst: mp4, progress: progress)
        do {
            return try r.run()
        } catch {
            try? r.out?.close()
            try? FileManager.default.removeItem(at: mp4)
            throw RemuxFailure(text: r.report(error))
        }
    }

    private let src: URL, dst: URL
    private let progress: (Double) -> Void
    private init(src: URL, dst: URL, progress: @escaping (Double) -> Void) { self.src = src; self.dst = dst; self.progress = progress }

    private struct Track {
        var sizes: [Int] = []
        var durs: [Int] = []
        var cts: [Int] = []
        var keys: [Int] = []
        var chunks: [(offset: UInt64, count: Int)] = []
        var buf: [UInt8] = []
        var bufCount = 0
        var bufDur = 0
    }

    private var out: FileHandle?
    private var pos: UInt64 = 0
    private var mdatStart: UInt64 = 0
    private var tv = Track(), ta = Track()

    private var pmtPID = -1, videoPID = -1, audioPID = -1
    private var vBuf = [UInt8](), aBuf = [UInt8]()
    private var vHeader: (pts: Int64, dts: Int64)?
    private var aHeaderPTS: Int64?
    private var sps: [UInt8]?, pps: [UInt8]?
    private var gotKey = false, vclSeen = 0
    private var vShift: Int64 = 0
    private var pendingV: VSample?
    private var lastDur: Int64 = 3003
    private var vStartDTS: Int64 = 0, vFirstPTS: [Int64] = [], vPresEnd: Int64 = 0, vSamples = 0
    private var sampleRate = 0, channels = 0, aot = 0, sfi = 0
    private var aAnchor: Int64 = -1, aCount: Int64 = 0, aFirstPTS: Int64 = -1
    private var pkts = 0
    private let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    private func report(_ e: Error) -> String {
        let what: String
        switch e {
        case RemuxError.unsupported(let c): what = "unsupported codec \(c)"
        case RemuxError.noVideo: what = "no H.264 video found in this file"
        case RemuxError.badStream(let m): what = m
        default: what = e.localizedDescription
        }
        return "\(what) (packets \(pkts), video PID \(videoPID), audio PID \(audioPID), SPS \(sps != nil), PPS \(pps != nil), frames \(vSamples), audio frames \(ta.sizes.count))"
    }

    // MARK: output
    private func write(_ bytes: [UInt8]) throws {
        guard let o = out else { return }
        try o.write(contentsOf: Data(bytes))
        pos += UInt64(bytes.count)
    }

    private func flushChunk(_ t: inout Track) throws {
        guard t.bufCount > 0 else { return }
        t.chunks.append((pos, t.bufCount))
        try write(t.buf)
        t.buf.removeAll(keepingCapacity: true)
        t.bufCount = 0
        t.bufDur = 0
    }

    private func emitVideo(_ s: VSample) throws {
        if tv.sizes.isEmpty { vStartDTS = s.dts }
        if vFirstPTS.count < 16 { vFirstPTS.append(s.pts) }
        vPresEnd = max(vPresEnd, s.pts + s.dur)
        tv.sizes.append(s.data.count)
        tv.durs.append(Int(s.dur))
        tv.cts.append(Int(s.pts - s.dts))
        if s.key { tv.keys.append(tv.sizes.count) }
        tv.buf.append(contentsOf: s.data)
        tv.bufCount += 1
        tv.bufDur += Int(s.dur)
        vSamples += 1
        if tv.bufDur >= 90000 { try flushChunk(&tv) }
    }

    private func emitAudio(_ d: [UInt8], _ pts: Int64) throws {
        if aFirstPTS < 0 { aFirstPTS = pts }
        ta.sizes.append(d.count)
        ta.buf.append(contentsOf: d)
        ta.bufCount += 1
        ta.bufDur += 1024
        if ta.bufDur >= sampleRate { try flushChunk(&ta) }
    }

    // MARK: main loop
    private func run() throws -> Bool {
        _ = FileManager.default.createFile(atPath: dst.path, contents: nil)
        out = try FileHandle(forWritingTo: dst)
        try write(box("ftyp", Array("isom".utf8), be32(512), Array("isomiso2avc1mp41".utf8)))
        mdatStart = pos
        try write(be32(1) + Array("mdat".utf8) + be64(0))

        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let total = max(1, ((try? FileManager.default.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.intValue ?? 1)
        var carry = [UInt8]()
        var read = 0
        while true {
            var finished = false
            try autoreleasepool {
                guard let chunk = try fh.read(upToCount: 188 * 2048), !chunk.isEmpty else { finished = true; return }
                read += chunk.count
                let buf = carry + [UInt8](chunk)
                var i = 0
                while i + 188 <= buf.count {
                    if buf[i] == 0x47 {
                        try packet(buf, i)
                        i += 188
                    } else {
                        // lost sync (junk between segments): find the next verified packet start
                        var j = i + 1
                        while j + 188 < buf.count, !(buf[j] == 0x47 && buf[j + 188] == 0x47) { j += 1 }
                        if j + 188 >= buf.count { break }
                        i = j
                    }
                }
                carry = Array(buf[i...])
                progress(min(1, Double(read) / Double(total)))
            }
            if finished { break }
        }
        try flushVideo()
        try flushAudio()
        if var p = pendingV { p.dur = lastDur; pendingV = nil; try emitVideo(p) }
        guard !tv.sizes.isEmpty, let s = sps, let p = pps else { throw RemuxError.noVideo }
        try flushChunk(&tv)
        try flushChunk(&ta)

        let mdatEnd = pos
        try out?.seek(toOffset: mdatStart + 8)
        try out?.write(contentsOf: Data(be64(mdatEnd - mdatStart)))
        try out?.seek(toOffset: mdatEnd)
        pos = mdatEnd
        try write(buildMoov(sps: s, pps: p))
        try out?.close()
        out = nil
        return audioPID >= 0 && ta.sizes.isEmpty
    }

    // MARK: TS parsing
    private func packet(_ b: [UInt8], _ o: Int) throws {
        pkts += 1
        if b[o + 1] & 0x80 != 0 { return }
        let pusi = (b[o + 1] & 0x40) != 0
        let pid = (Int(b[o + 1] & 0x1F) << 8) | Int(b[o + 2])
        let afc = (b[o + 3] >> 4) & 3
        var s = o + 4
        if afc & 2 != 0 { s += 1 + Int(b[o + 4]) }
        let e = o + 188
        if pid == 0x1FFF { return }
        guard afc & 1 != 0, s < e else { return }

        if pid == 0 {
            if pusi { parsePAT(b, s, e) }
        } else if pid == pmtPID {
            if pusi { try parsePMT(b, s, e) }
        } else if pid == videoPID {
            if pusi {
                try flushVideo()
                vBuf.removeAll(keepingCapacity: true)
                vHeader = nil
                if let h = pesHeader(b, s, e), let pts = h.pts {
                    vHeader = (pts, h.dts ?? pts)
                    vBuf.append(contentsOf: b[h.dataStart..<e])
                }
            } else if vHeader != nil {
                vBuf.append(contentsOf: b[s..<e])
            }
        } else if pid == audioPID {
            if pusi {
                try flushAudio()
                aBuf.removeAll(keepingCapacity: true)
                aHeaderPTS = nil
                if let h = pesHeader(b, s, e), let pts = h.pts {
                    aHeaderPTS = pts
                    aBuf.append(contentsOf: b[h.dataStart..<e])
                }
            } else if aHeaderPTS != nil {
                aBuf.append(contentsOf: b[s..<e])
            }
        }
    }

    private func pesHeader(_ b: [UInt8], _ s: Int, _ e: Int) -> (pts: Int64?, dts: Int64?, dataStart: Int)? {
        guard s + 9 <= e, b[s] == 0, b[s + 1] == 0, b[s + 2] == 1 else { return nil }
        let flags = b[s + 7] >> 6
        let hl = Int(b[s + 8])
        var pts: Int64?, dts: Int64?
        if flags >= 2, s + 14 <= e { pts = readPTS(b, s + 9) }
        if flags == 3, s + 19 <= e { dts = readPTS(b, s + 14) }
        return (pts, dts, min(s + 9 + hl, e))
    }

    private func parsePAT(_ b: [UInt8], _ s: Int, _ e: Int) {
        let sec = s + 1 + Int(b[s])
        guard sec + 8 <= e, b[sec] == 0 else { return }
        let len = (Int(b[sec + 1] & 0x0F) << 8) | Int(b[sec + 2])
        var p = sec + 8
        let end = min(sec + 3 + len - 4, e)
        while p + 4 <= end {
            let prog = (Int(b[p]) << 8) | Int(b[p + 1])
            let pid = (Int(b[p + 2] & 0x1F) << 8) | Int(b[p + 3])
            if prog != 0 { pmtPID = pid; return }
            p += 4
        }
    }

    private func parsePMT(_ b: [UInt8], _ s: Int, _ e: Int) throws {
        let sec = s + 1 + Int(b[s])
        guard sec + 12 <= e, b[sec] == 2 else { return }
        let len = (Int(b[sec + 1] & 0x0F) << 8) | Int(b[sec + 2])
        let pil = (Int(b[sec + 10] & 0x0F) << 8) | Int(b[sec + 11])
        var p = sec + 12 + pil
        let end = min(sec + 3 + len - 4, e)
        while p + 5 <= end {
            let st = b[p]
            let pid = (Int(b[p + 1] & 0x1F) << 8) | Int(b[p + 2])
            let esl = (Int(b[p + 3] & 0x0F) << 8) | Int(b[p + 4])
            if st == 0x1B, videoPID < 0 { videoPID = pid }
            else if st == 0x24, videoPID < 0 { throw RemuxError.unsupported("HEVC/H.265 video") }
            else if st == 0x0F, audioPID < 0 { audioPID = pid }
            p += 5 + esl
        }
    }

    private func nalRanges(_ b: [UInt8]) -> [Range<Int>] {
        var starts: [(code: Int, data: Int)] = []
        var i = 0
        let n = b.count
        while i + 3 < n {
            if b[i] == 0, b[i + 1] == 0 {
                if b[i + 2] == 1 { starts.append((i, i + 3)); i += 3; continue }
                if b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, i + 4)); i += 4; continue }
            }
            i += 1
        }
        var result: [Range<Int>] = []
        for k in 0..<starts.count {
            let ds = starts[k].data
            var e = k + 1 < starts.count ? starts[k + 1].code : n
            while e > ds, b[e - 1] == 0 { e -= 1 }
            if e > ds { result.append(ds..<e) }
        }
        return result
    }

    private func flushVideo() throws {
        guard let h = vHeader, !vBuf.isEmpty else { return }
        var data = [UInt8]()
        var key = false, vcl = false
        for r in nalRanges(vBuf) {
            let t = vBuf[r.lowerBound] & 0x1F
            switch t {
            case 7: if sps == nil { sps = Array(vBuf[r]) }
            case 8: if pps == nil { pps = Array(vBuf[r]) }
            case 1...6:
                if t == 5 { key = true }
                if t <= 5 { vcl = true }
                data += be32(r.count)
                data.append(contentsOf: vBuf[r])
            default: break
            }
        }
        guard vcl else { return }
        vclSeen += 1
        guard sps != nil, pps != nil else { return }
        if !gotKey {
            if key || vclSeen > 30 { gotKey = true; key = true } else { return }
        }
        var dts = h.dts + vShift, pts = h.pts + vShift
        if var p = pendingV {
            var d = dts - p.dts
            if d <= 0 || d > 90000 * 5 {          // timestamp jump or rollover: stitch the timeline
                let fix = (p.dts + lastDur) - dts
                vShift += fix; dts += fix; pts += fix
                d = lastDur
            }
            lastDur = d
            p.dur = d
            pendingV = nil
            try emitVideo(p)
        }
        pendingV = VSample(data: data, pts: pts, dts: dts, dur: 0, key: key)
    }

    private func flushAudio() throws {
        guard let start = aHeaderPTS, !aBuf.isEmpty else { return }
        var i = 0
        while i + 7 <= aBuf.count {
            guard aBuf[i] == 0xFF, (aBuf[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let prot = aBuf[i + 1] & 1
            let prof = Int(aBuf[i + 2] >> 6) & 3
            let f = Int(aBuf[i + 2] >> 2) & 0xF
            let ch = (Int(aBuf[i + 2] & 1) << 2) | Int(aBuf[i + 3] >> 6)
            let len = (Int(aBuf[i + 3] & 3) << 11) | (Int(aBuf[i + 4]) << 3) | (Int(aBuf[i + 5]) >> 5)
            let hdr = prot == 1 ? 7 : 9
            guard len > hdr, i + len <= aBuf.count, f < rates.count else { break }
            if sampleRate == 0 {
                sampleRate = rates[f]; channels = max(ch, 1); aot = prof + 1; sfi = f
            }
            let frameTicks = Int64(1024 * 90000 / sampleRate)
            let shifted = start + vShift
            if aAnchor < 0 || abs(shifted - (aAnchor + aCount * 1024 * 90000 / Int64(sampleRate))) > frameTicks * 2 {
                aAnchor = shifted; aCount = 0      // (re)anchor on timestamp jumps
            }
            let pts = aAnchor + aCount * 1024 * 90000 / Int64(sampleRate)
            try emitAudio(Array(aBuf[(i + hdr)..<(i + len)]), pts)
            aCount += 1
            i += len
        }
    }

    // MARK: moov
    private func chunkTables(_ t: Track) -> (stsz: [UInt8], stsc: [UInt8], co64: [UInt8]) {
        var sz = [UInt8]()
        sz.reserveCapacity(t.sizes.count * 4)
        for x in t.sizes { sz += be32(x) }
        let stsz = fullbox("stsz", 0, 0, be32(0), be32(t.sizes.count), sz)
        var sc = [(first: Int, count: Int)]()
        for (i, c) in t.chunks.enumerated() where sc.last?.count != c.count { sc.append((i + 1, c.count)) }
        var scb = [UInt8]()
        for e in sc { scb += be32(e.first); scb += be32(e.count); scb += be32(1) }
        let stsc = fullbox("stsc", 0, 0, be32(sc.count), scb)
        var cob = [UInt8]()
        cob.reserveCapacity(t.chunks.count * 8)
        for c in t.chunks { cob += be64(c.offset) }
        let co64 = fullbox("co64", 0, 0, be32(t.chunks.count), cob)
        return (stsz, stsc, co64)
    }

    private func tkhd(_ id: Int, _ dur: Int, _ w: Int, _ h: Int, _ vol: Int) -> [UInt8] {
        let matrix = be32(0x10000) + be32(0) + be32(0) + be32(0) + be32(0x10000) + be32(0) + be32(0) + be32(0) + be32(0x40000000)
        let now = be32(Int(Date().timeIntervalSince1970) + 2_082_844_800)
        return fullbox("tkhd", 0, 3, now, now, be32(id), be32(0), be32(dur), zeros(8),
                       be16(0), be16(0), be16(vol), be16(0), matrix, be32(w << 16), be32(h << 16))
    }

    private func mdhd(_ ts: Int, _ dur: Int) -> [UInt8] {
        let now = be32(Int(Date().timeIntervalSince1970) + 2_082_844_800)
        return fullbox("mdhd", 0, 0, now, now, be32(ts), be32(dur), be16(0x55C4), be16(0))
    }

    private func hdlr(_ type: String, _ name: String) -> [UInt8] {
        fullbox("hdlr", 0, 0, be32(0), Array(type.utf8), zeros(12), Array(name.utf8), [0])
    }

    private func buildMoov(sps: [UInt8], pps: [UInt8]) throws -> [UInt8] {
        guard sps.count > 3 else { throw RemuxError.badStream("invalid SPS") }
        let info = parseSPS(sps)
        let MS = 1000
        let now = Int(Date().timeIntervalSince1970) + 2_082_844_800
        func mv(_ t: Int) -> Int { t * MS / 90000 }
        let dinf = box("dinf", fullbox("dref", 0, 0, be32(1), fullbox("url ", 0, 1)))

        // ---- video track
        var avc: [UInt8] = [1, sps[1], sps[2], sps[3], 0xFF, 0xE1] + be16(sps.count) + sps + [1] + be16(pps.count) + pps
        if [100, 110, 122, 144, 244].contains(info.profile) {
            avc += [UInt8(truncatingIfNeeded: 0xFC | info.chroma), UInt8(truncatingIfNeeded: 0xF8 | info.bdl), UInt8(truncatingIfNeeded: 0xF8 | info.bdc), 0]
        }
        let avc1 = box("avc1", zeros(6), be16(1), zeros(16), be16(info.width), be16(info.height),
                       be32(0x00480000), be32(0x00480000), be32(0), be16(1), zeros(32), be16(0x18), be16(0xFFFF),
                       box("avcC", avc))
        let vRuns = pairs(runs(tv.durs))
        let stts = fullbox("stts", 0, 0, be32(runs(tv.durs).count), vRuns)
        var ctts = [UInt8]()
        if tv.cts.contains(where: { $0 != 0 }) {
            let r = runs(tv.cts)
            ctts = fullbox("ctts", 0, 0, be32(r.count), pairs(r))
        }
        var stss = [UInt8]()
        if tv.keys.count != tv.sizes.count {
            var kb = [UInt8]()
            for k in tv.keys { kb += be32(k) }
            stss = fullbox("stss", 0, 0, be32(tv.keys.count), kb)
        }
        let vt = chunkTables(tv)
        let stblV = box("stbl", fullbox("stsd", 0, 0, be32(1), avc1), stts, ctts, stss, vt.stsc, vt.stsz, vt.co64)

        let vdur = tv.durs.reduce(0, +)
        let p0 = Int(vFirstPTS.min() ?? vStartDTS)
        let c0 = p0 - Int(vStartDTS)
        let presEnd = Int(vPresEnd - vStartDTS)
        let vMovieDur = mv(presEnd - c0)
        let elstV = fullbox("elst", 0, 0, be32(1), be32(vMovieDur), s32(c0), be16(1), be16(0))
        let trakV = box("trak", tkhd(1, vMovieDur, info.width, info.height, 0), box("edts", elstV),
                        box("mdia", mdhd(90000, vdur), hdlr("vide", "VideoHandler"),
                            box("minf", fullbox("vmhd", 0, 1, zeros(8)), dinf, stblV)))
        var traks = [trakV]
        var total = vMovieDur

        // ---- audio track
        if !ta.sizes.isEmpty, sampleRate > 0 {
            let sr = sampleRate
            let mediaDur = ta.sizes.count * 1024
            let dTicks = Int(aFirstPTS) - p0
            var elst: [UInt8]
            var aMovieDur: Int
            if dTicks > 0 {
                let lead = mv(dTicks), body = mediaDur * MS / sr
                elst = fullbox("elst", 0, 0, be32(2), be32(lead), s32(-1), be16(1), be16(0), be32(body), s32(0), be16(1), be16(0))
                aMovieDur = lead + body
            } else {
                let skip = min((-dTicks) * sr / 90000, max(0, mediaDur - 1024))
                let body = (mediaDur - skip) * MS / sr
                elst = fullbox("elst", 0, 0, be32(1), be32(body), s32(skip), be16(1), be16(0))
                aMovieDur = body
            }
            total = max(total, aMovieDur)
            let at = chunkTables(ta)
            let asc: [UInt8] = [UInt8(truncatingIfNeeded: (aot << 3) | (sfi >> 1)), UInt8(truncatingIfNeeded: ((sfi & 1) << 7) | (channels << 3))]
            let dec: [UInt8] = [0x40, 0x15] + zeros(11) + [0x05, 0x80, 0x80, 0x80, UInt8(asc.count)] + asc
            let es: [UInt8] = be16(0) + [0] + [0x04, 0x80, 0x80, 0x80, UInt8(dec.count)] + dec + [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
            let esds = fullbox("esds", 0, 0, [0x03, 0x80, 0x80, 0x80, UInt8(es.count)] + es)
            let mp4a = box("mp4a", zeros(6), be16(1), zeros(8), be16(channels), be16(16), be16(0), be16(0),
                           be32(sr < 65536 ? sr << 16 : 0), esds)
            let sttsA = fullbox("stts", 0, 0, be32(1), be32(ta.sizes.count), be32(1024))
            let stblA = box("stbl", fullbox("stsd", 0, 0, be32(1), mp4a), sttsA, at.stsc, at.stsz, at.co64)
            traks.append(box("trak", tkhd(2, aMovieDur, 0, 0, 0x100), box("edts", elst),
                             box("mdia", mdhd(sr, mediaDur), hdlr("soun", "SoundHandler"),
                                 box("minf", fullbox("smhd", 0, 0, zeros(4)), dinf, stblA))))
        }

        let matrix = be32(0x10000) + be32(0) + be32(0) + be32(0) + be32(0x10000) + be32(0) + be32(0) + be32(0) + be32(0x40000000)
        let mvhd = fullbox("mvhd", 0, 0, be32(now), be32(now), be32(MS), be32(total), be32(0x10000), be16(0x100),
                           zeros(10), matrix, zeros(24), be32(traks.count + 1))
        return boxA("moov", [mvhd] + traks)
    }

    // MARK: duration estimate (used by the in-app player for raw .ts files)
    static func duration(of url: URL) -> Double? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let span = 188 * 4000
        func scan(_ off: UInt64) -> [Int64] {
            try? fh.seek(toOffset: off)
            let b = [UInt8]((try? fh.read(upToCount: span)) ?? Data())
            var res: [Int64] = []
            var i = 0
            while i + 188 < b.count, !(b[i] == 0x47 && b[i + 188] == 0x47) { i += 1 }
            while i + 188 <= b.count {
                if b[i] == 0x47, b[i + 1] & 0x40 != 0 {
                    let afc = (b[i + 3] >> 4) & 3
                    var s = i + 4
                    if afc & 2 != 0 { s += 1 + Int(b[i + 4]) }
                    if afc & 1 != 0, s + 14 <= i + 188, b[s] == 0, b[s + 1] == 0, b[s + 2] == 1,
                       (b[s + 3] & 0xF0) == 0xE0, (b[s + 7] >> 6) >= 2 { res.append(readPTS(b, s + 9)) }
                }
                i += 188
            }
            return res
        }
        let head = scan(0)
        let tailOff: UInt64 = size > UInt64(span) ? ((size - UInt64(span)) / 188) * 188 : 0
        let tail = scan(tailOff)
        guard let a = head.min(), let z = tail.max(), z > a else { return nil }
        return Double(z - a) / 90000 + 1
    }
}

/// Lets the in-app player open raw .ts files by wrapping them in a one-segment local HLS playlist.
enum TSPlayback {
    static func playableURL(for url: URL) -> URL {
        guard ["ts", "m2ts", "mts"].contains(url.pathExtension.lowercased()) else { return url }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tsplay-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let link = dir.appendingPathComponent("media.ts")
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url) } catch { return url }
        let dur = TSRemux.duration(of: url) ?? 3600
        let text = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:\(Int(dur.rounded(.up)) + 1)\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:\(String(format: "%.3f", dur)),\nmedia.ts\n#EXT-X-ENDLIST\n"
        let pl = dir.appendingPathComponent("index.m3u8")
        do { try text.write(to: pl, atomically: true, encoding: .utf8) } catch { return url }
        return pl
    }
}
