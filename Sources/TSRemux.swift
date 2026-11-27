import Foundation
import AVFoundation
import CoreMedia

enum RemuxError: Error { case unsupported(String), noVideo, write }

/// Converts an MPEG transport stream (H.264 video + AAC audio) into an MP4 without re-encoding.
/// Streams the input from disk, so file size is not limited by memory.
final class TSRemux {
    struct VSample { var data: [UInt8]; var pts: Int64; var dts: Int64; var dur: Int64; var key: Bool }
    struct ASample { var data: [UInt8]; var pts: Int64 }

    static func convert(ts: URL, to mp4: URL, progress: @escaping (Double) -> Void = { _ in }) throws {
        let r = TSRemux(src: ts, dst: mp4, progress: progress)
        do { try r.run() } catch {
            r.writer?.cancelWriting()
            try? FileManager.default.removeItem(at: mp4)
            throw error
        }
    }

    private let src: URL, dst: URL
    private let progress: (Double) -> Void
    private init(src: URL, dst: URL, progress: @escaping (Double) -> Void) { self.src = src; self.dst = dst; self.progress = progress }

    private var pmtPID = -1, videoPID = -1, audioPID = -1
    private var vBuf = [UInt8](), aBuf = [UInt8]()
    private var vHeader: (pts: Int64, dts: Int64)?
    private var aHeaderPTS: Int64?
    private var sps: [UInt8]?, pps: [UInt8]?
    private var vfd: CMVideoFormatDescription?
    private var afd: CMAudioFormatDescription?
    private var sampleRate = 44100
    private var gotKey = false
    private var pendingV: VSample?
    private var lastDur: Int64 = 3003
    private var vq = [VSample](), aq = [ASample]()
    fileprivate var writer: AVAssetWriter?
    private var vIn: AVAssetWriterInput?, aIn: AVAssetWriterInput?
    private var base: Int64 = 0
    private var giveUpAudio = false
    private let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    // MARK: main loop
    private func run() throws {
        try? FileManager.default.removeItem(at: dst)
        let fh = try FileHandle(forReadingFrom: src)
        defer { try? fh.close() }
        let total = max(1, ((try? FileManager.default.attributesOfItem(atPath: src.path)[.size]) as? NSNumber)?.intValue ?? 1)
        var carry = [UInt8]()
        var synced = false
        var read = 0
        while true {
            var finished = false
            try autoreleasepool {
                guard let chunk = try fh.read(upToCount: 188 * 2048), !chunk.isEmpty else { finished = true; return }
                read += chunk.count
                let buf = carry + [UInt8](chunk)
                var i = 0
                if !synced {
                    while i + 188 < buf.count, !(buf[i] == 0x47 && buf[i + 188] == 0x47) { i += 1 }
                    synced = true
                }
                while i + 188 <= buf.count {
                    if buf[i] != 0x47 { i += 1; continue }
                    try packet(buf, i)
                    i += 188
                }
                carry = Array(buf[i...])
                progress(min(1, Double(read) / Double(total)))
            }
            if finished { break }
        }
        try flushVideo()
        try flushAudio()
        if var p = pendingV { p.dur = lastDur; vq.append(p); pendingV = nil }
        try pump(final: true)
        guard let w = writer else { throw RemuxError.noVideo }
        vIn?.markAsFinished(); aIn?.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        w.finishWriting { sem.signal() }
        sem.wait()
        guard w.status == .completed else { throw w.error ?? RemuxError.write }
    }

    // MARK: TS parsing
    private func readTS(_ b: [UInt8], _ i: Int) -> Int64 {
        (Int64(b[i] & 0x0E) << 29) | (Int64(b[i + 1]) << 22) | (Int64(b[i + 2] & 0xFE) << 14) | (Int64(b[i + 3]) << 7) | (Int64(b[i + 4]) >> 1)
    }

    private func packet(_ b: [UInt8], _ o: Int) throws {
        if b[o + 1] & 0x80 != 0 { return }
        let pusi = (b[o + 1] & 0x40) != 0
        let pid = (Int(b[o + 1] & 0x1F) << 8) | Int(b[o + 2])
        let afc = (b[o + 3] >> 4) & 3
        var s = o + 4
        if afc & 2 != 0 { s += 1 + Int(b[o + 4]) }
        let e = o + 188
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
        if flags >= 2, s + 14 <= e { pts = readTS(b, s + 9) }
        if flags == 3, s + 19 <= e { dts = readTS(b, s + 14) }
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
            else if st == 0x24, videoPID < 0 { throw RemuxError.unsupported("HEVC") }
            else if st == 0x0F, audioPID < 0 { audioPID = pid }
            p += 5 + esl
        }
    }

    // MARK: video
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
        var out: [Range<Int>] = []
        for k in 0..<starts.count {
            let ds = starts[k].data
            var e = k + 1 < starts.count ? starts[k + 1].code : n
            while e > ds, b[e - 1] == 0 { e -= 1 }
            if e > ds { out.append(ds..<e) }
        }
        return out
    }

    private func flushVideo() throws {
        guard let h = vHeader, !vBuf.isEmpty else { return }
        var out = [UInt8]()
        var key = false, vcl = false
        for r in nalRanges(vBuf) {
            let t = vBuf[r.lowerBound] & 0x1F
            switch t {
            case 7: if sps == nil { sps = Array(vBuf[r]) }
            case 8: if pps == nil { pps = Array(vBuf[r]) }
            case 1...6:
                if t == 5 { key = true }
                if t <= 5 { vcl = true }
                let n = r.count
                out.append(contentsOf: [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)])
                out.append(contentsOf: vBuf[r])
            default: break
            }
        }
        guard vcl else { return }
        if vfd == nil {
            guard let s = sps, let p = pps else { return }
            var fd: CMVideoFormatDescription?
            let st: OSStatus = s.withUnsafeBufferPointer { sp in
                p.withUnsafeBufferPointer { pp in
                    let ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
                    let sizes = [s.count, p.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                        parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
                }
            }
            guard st == noErr, fd != nil else { throw RemuxError.write }
            vfd = fd
        }
        if !gotKey { if key { gotKey = true } else { return } }
        let cur = VSample(data: out, pts: h.pts, dts: h.dts, dur: 0, key: key)
        if var p = pendingV {
            var d = cur.dts - p.dts
            if d <= 0 { d = lastDur }
            lastDur = d
            p.dur = d
            vq.append(p)
        }
        pendingV = cur
        try pump(final: false)
    }

    // MARK: audio
    private func flushAudio() throws {
        guard let start = aHeaderPTS, !aBuf.isEmpty else { return }
        var i = 0, idx: Int64 = 0
        while i + 7 <= aBuf.count {
            guard aBuf[i] == 0xFF, (aBuf[i + 1] & 0xF0) == 0xF0 else { i += 1; continue }
            let prot = aBuf[i + 1] & 1
            let prof = Int(aBuf[i + 2] >> 6) & 3
            let sfi = Int(aBuf[i + 2] >> 2) & 0xF
            let ch = (Int(aBuf[i + 2] & 1) << 2) | Int(aBuf[i + 3] >> 6)
            let len = (Int(aBuf[i + 3] & 3) << 11) | (Int(aBuf[i + 4]) << 3) | (Int(aBuf[i + 5]) >> 5)
            let hdr = prot == 1 ? 7 : 9
            guard len > hdr, i + len <= aBuf.count, sfi < rates.count else { break }
            if afd == nil {
                sampleRate = rates[sfi]
                try makeAudioFD(aot: prof + 1, sfi: sfi, ch: max(ch, 1))
            }
            let pts = start + idx * 1024 * 90000 / Int64(sampleRate)
            aq.append(ASample(data: Array(aBuf[(i + hdr)..<(i + len)]), pts: pts))
            idx += 1
            i += len
        }
        try pump(final: false)
    }

    private func makeAudioFD(aot: Int, sfi: Int, ch: Int) throws {
        let asc: [UInt8] = [UInt8((aot << 3) | (sfi >> 1)), UInt8(((sfi & 1) << 7) | (ch << 3))]
        let cookie: [UInt8] = [0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x00, 0x00,
                               0x04, 0x80, 0x80, 0x80, 0x14, 0x40, 0x15, 0x00, 0x00, 0x00,
                               0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                               0x05, 0x80, 0x80, 0x80, 0x02] + asc + [0x06, 0x80, 0x80, 0x80, 0x01, 0x02]
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: UInt32(aot), mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: UInt32(ch), mBitsPerChannel: 0, mReserved: 0)
        var fd: CMAudioFormatDescription?
        let st: OSStatus = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: cookie.count, magicCookie: $0.baseAddress,
                                           extensions: nil, formatDescriptionOut: &fd)
        }
        guard st == noErr, fd != nil else { throw RemuxError.write }
        afd = fd
    }

    // MARK: writing
    private func startIfReady(final: Bool) throws {
        let needAudio = audioPID >= 0 && !giveUpAudio
        if needAudio, afd == nil, vq.count > 3000 { giveUpAudio = true }
        guard vfd != nil, !vq.isEmpty else {
            if final { throw RemuxError.noVideo }
            return
        }
        let useAudio = audioPID >= 0 && !giveUpAudio && afd != nil && !aq.isEmpty
        if needAudio && !useAudio && !final && !giveUpAudio { return }
        let w = try AVAssetWriter(outputURL: dst, fileType: .mp4)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vfd)
        vi.expectsMediaDataInRealTime = false
        w.add(vi)
        if useAudio {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: afd)
            ai.expectsMediaDataInRealTime = false
            w.add(ai)
            aIn = ai
            base = min(vq[0].dts, aq[0].pts)
        } else {
            base = vq[0].dts
        }
        guard w.startWriting() else { throw w.error ?? RemuxError.write }
        w.startSession(atSourceTime: .zero)
        writer = w
        vIn = vi
    }

    private func pump(final: Bool) throws {
        if writer == nil {
            try startIfReady(final: final)
            if writer == nil { return }
        }
        let hasA = aIn != nil
        if !hasA { aq.removeAll() }
        while true {
            let useVideo: Bool
            if let v = vq.first, let a = aq.first { useVideo = v.dts <= a.pts }
            else if vq.first != nil { if hasA && !final && vq.count < 900 { return }; useVideo = true }
            else if aq.first != nil { if !final && aq.count < 1500 { return }; useVideo = false }
            else { return }
            if useVideo { try appendVideo(vq.removeFirst()) } else { try appendAudio(aq.removeFirst()) }
        }
    }

    private func block(_ d: [UInt8]) -> CMBlockBuffer? {
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: d.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: d.count, flags: 0, blockBufferOut: &bb) == noErr, let b = bb else { return nil }
        let ok = d.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: b, offsetIntoDestination: 0, dataLength: d.count)
        }
        return ok == noErr ? b : nil
    }

    private func waitReady(_ input: AVAssetWriterInput) throws {
        var spins = 0
        while !input.isReadyForMoreMediaData {
            guard writer?.status == .writing else { throw writer?.error ?? RemuxError.write }
            Thread.sleep(forTimeInterval: 0.005)
            spins += 1
            if spins > 6000 { throw RemuxError.write }
        }
    }

    private func appendVideo(_ s: VSample) throws {
        guard let vi = vIn, let fd = vfd, let bb = block(s.data) else { throw RemuxError.write }
        var timing = CMSampleTimingInfo(duration: CMTime(value: s.dur, timescale: 90000),
                                        presentationTimeStamp: CMTime(value: s.pts - base, timescale: 90000),
                                        decodeTimeStamp: CMTime(value: s.dts - base, timescale: 90000))
        var size = s.data.count
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        guard st == noErr, let buf = sb else { throw RemuxError.write }
        if !s.key, let att = CMSampleBufferGetSampleAttachmentsArray(buf, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        try waitReady(vi)
        guard vi.append(buf) else { throw writer?.error ?? RemuxError.write }
    }

    private func appendAudio(_ s: ASample) throws {
        guard let ai = aIn, let fd = afd, let bb = block(s.data) else { throw RemuxError.write }
        var desc = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(s.data.count))
        var sb: CMSampleBuffer?
        let st = CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: bb, formatDescription: fd,
                                                                      sampleCount: 1,
                                                                      presentationTimeStamp: CMTime(value: s.pts - base, timescale: 90000),
                                                                      packetDescriptions: &desc, sampleBufferOut: &sb)
        guard st == noErr, let buf = sb else { throw RemuxError.write }
        try waitReady(ai)
        guard ai.append(buf) else { throw writer?.error ?? RemuxError.write }
    }
}
