import SwiftUI
import AVFoundation

@main
struct LumenApp: App {
    @StateObject private var store = BrowserStore()
    @StateObject private var settings = Settings.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        AdBlock.shared.rebuild()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
                .environmentObject(settings)
                .tint(settings.theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.scenePhase) var phase
    @State private var locked = Settings.shared.appLock

    var body: some View {
        ZStack {
            ContentView()
            if locked {
                ZStack {
                    Color(.systemBackground).ignoresSafeArea()
                    VStack(spacing: 16) {
                        Image(systemName: "lock.fill").font(.system(size: 48))
                        Button("Unlock") { unlock() }.buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear { if locked { unlock() } }
        .onChange(of: phase) { p in
            if p == .background && settings.appLock { locked = true }
            if p == .active && locked { unlock() }
        }
    }

    private func unlock() {
        Auth.authenticate(reason: "Unlock the browser") { ok in if ok { locked = false } }
    }
}
