import SwiftUI
import AVFoundation
import MediaPlayer

final class PlayerContainer: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? {
        didSet { playerLayer.player = player }
    }
    override init(frame: CGRect) {
        super.init(frame: frame)
        playerLayer.videoGravity = .resizeAspect
        NotificationCenter.default.addObserver(self, selector: #selector(bg), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(fg), name: UIApplication.willEnterForegroundNotification, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    // Detaching the layer lets audio keep playing in the background
    @objc private func bg() { playerLayer.player = nil }
    @objc private func fg() { playerLayer.player = player }
}

struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerContainer { let v = PlayerContainer(); v.player = player; return v }
    func updateUIView(_ v: PlayerContainer, context: Context) {}
}

final class PlayerModel: ObservableObject {
    let player: AVPlayer
    @Published var playing = true
    @Published var time = 0.0
    @Published var duration = 1.0
    @Published var speed: Float = 1.0
    @Published var audioOptions: [AVMediaSelectionOption] = []
    @Published var subOptions: [AVMediaSelectionOption] = []
    private var token: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            guard let self else { return }
            self.time = t.seconds
            if let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 { self.duration = d }
        }
        player.play()
        Task { await loadTracks() }
    }

    deinit { if let token { player.removeTimeObserver(token) }; player.pause() }

    func loadTracks() async {
        guard let asset = player.currentItem?.asset else { return }
        if let g = try? await asset.loadMediaSelectionGroup(for: .audible) { audioOptions = g.options }
        if let g = try? await asset.loadMediaSelectionGroup(for: .legible) { subOptions = g.options }
    }

    func select(_ o: AVMediaSelectionOption?, legible: Bool) {
        guard let item = player.currentItem else { return }
        Task {
            let ch = legible ? AVMediaCharacteristic.legible : .audible
            if let g = try? await item.asset.loadMediaSelectionGroup(for: ch) { item.select(o, in: g) }
        }
    }

    func toggle() { playing.toggle(); playing ? (player.rate = speed) : player.pause() }
    func seek(_ s: Double) { player.seek(to: CMTime(seconds: max(0, min(s, duration)), preferredTimescale: 600)) }
    func setSpeed(_ s: Float) { speed = s; if playing { player.rate = s } }
}

enum SystemVolume {
    private static let view = MPVolumeView(frame: .zero)
    static var slider: UISlider? { view.subviews.compactMap { $0 as? UISlider }.first }
    static var value: Float { get { AVAudioSession.sharedInstance().outputVolume } set { slider?.value = newValue } }
}

struct PlayerView: View {
    let url: URL
    @StateObject private var m: PlayerModel
    @Environment(\.dismiss) var dismiss
    @State private var showControls = true
    @State private var mode: Int? // 0 seek, 1 brightness, 2 volume
    @State private var startTime = 0.0
    @State private var startB: CGFloat = 0
    @State private var startV: Float = 0
    @State private var hud: String?

    init(url: URL) { self.url = url; _m = StateObject(wrappedValue: PlayerModel(url: url)) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                PlayerSurface(player: m.player).ignoresSafeArea()
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { withAnimation { showControls.toggle() } }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 14)
                            .onChanged { v in
                                if mode == nil {
                                    if abs(v.translation.width) > abs(v.translation.height) { mode = 0; startTime = m.time }
                                    else if v.startLocation.x < geo.size.width / 2 { mode = 1; startB = UIScreen.main.brightness }
                                    else { mode = 2; startV = SystemVolume.value }
                                }
                                switch mode {
                                case 0:
                                    let t = max(0, min(startTime + Double(v.translation.width / geo.size.width) * 120, m.duration))
                                    hud = "\(fmt(t)) / \(fmt(m.duration))"
                                case 1:
                                    let b = max(0, min(1, startB - v.translation.height / 300))
                                    UIScreen.main.brightness = b; hud = "Brightness \(Int(b * 100))%"
                                case 2:
                                    let vol = max(0, min(1, startV - Float(v.translation.height / 300)))
                                    SystemVolume.value = vol; hud = "Volume \(Int(vol * 100))%"
                                default: break
                                }
                            }
                            .onEnded { v in
                                if mode == 0 { m.seek(startTime + Double(v.translation.width / geo.size.width) * 120) }
                                mode = nil; hud = nil
                            }
                    )
                    .onLongPressGesture(minimumDuration: 0.4, pressing: { p in
                        if m.playing { m.player.rate = p ? 2.0 : m.speed }
                    }, perform: {})
                if let hud { Text(hud).padding(10).background(.ultraThinMaterial, in: Capsule()).foregroundColor(.white) }
                if showControls { controls }
            }
        }
        .statusBarHidden(true)
    }

    private func fmt(_ s: Double) -> String {
        let i = Int(max(0, s)); return String(format: "%d:%02d", i / 60, i % 60)
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title) }
                Spacer()
                Menu {
                    Menu("Speed") { ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in Button("\(s)x") { m.setSpeed(Float(s)) } } }
                    if !m.audioOptions.isEmpty {
                        Menu("Audio") { ForEach(m.audioOptions, id: \.self) { o in Button(o.displayName) { m.select(o, legible: false) } } }
                    }
                    if !m.subOptions.isEmpty {
                        Menu("Subtitles") {
                            Button("Off") { m.select(nil, legible: true) }
                            ForEach(m.subOptions, id: \.self) { o in Button(o.displayName) { m.select(o, legible: true) } }
                        }
                    }
                } label: { Image(systemName: "slider.horizontal.3").font(.title2) }
            }
            Spacer()
            HStack(spacing: 40) {
                Button { m.seek(m.time - 10) } label: { Image(systemName: "gobackward.10") }
                Button { m.toggle() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(.system(size: 44)) }
                Button { m.seek(m.time + 10) } label: { Image(systemName: "goforward.10") }
            }.font(.largeTitle)
            Spacer()
            HStack {
                Text(fmt(m.time)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { m.time }, set: { m.seek($0) }), in: 0...max(m.duration, 1))
                Text(fmt(m.duration)).font(.caption.monospacedDigit())
            }
        }
        .foregroundColor(.white).padding()
    }
}

struct TrimView: View {
    let url: URL
    var onDone: () -> Void
    @Environment(\.dismiss) var dismiss
    @State private var duration = 1.0
    @State private var start = 0.0
    @State private var end = 1.0
    @State private var busy = false
    @State private var msg = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Keep from \(Int(start))s to \(Int(end))s") {
                    Slider(value: $start, in: 0...max(end - 1, 0.1)).onChange(of: start) { _ in if start >= end { start = max(0, end - 1) } }
                    Slider(value: $end, in: min(start + 1, duration)...duration)
                }
                Button(busy ? "Exporting…" : "Save trimmed copy") { export() }.disabled(busy)
                if !msg.isEmpty { Text(msg).font(.caption) }
            }
            .navigationTitle("Trim video")
            .toolbar { Button("Close") { dismiss() } }
            .task {
                if let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite { duration = d; end = d }
            }
        }
    }

    private func export() {
        let asset = AVURLAsset(url: url)
        guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { msg = "Can't export this file"; return }
        let type = s.supportedFileTypes.contains(.mp4) && url.pathExtension.lowercased() == "mp4" ? AVFileType.mp4 : (s.supportedFileTypes.contains(.mov) ? .mov : s.supportedFileTypes.first!)
        let ext = type == .mp4 ? "mp4" : "mov"
        let dest = DownloadManager.shared.uniqueURL(url.deletingLastPathComponent(), url.deletingPathExtension().lastPathComponent + " trimmed." + ext)
        s.outputURL = dest
        s.outputFileType = type
        s.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        busy = true
        s.exportAsynchronously {
            DispatchQueue.main.async {
                busy = false
                if s.status == .completed { msg = "Saved \(dest.lastPathComponent)"; onDone() } else { msg = "Export failed" }
            }
        }
    }
}
