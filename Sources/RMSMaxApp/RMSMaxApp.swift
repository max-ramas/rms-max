import SwiftUI
import RMSMaxCore

@main
struct RMSMaxApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                BackgroundKeepAlive.shared.appDidEnterBackground(callActive: store.activeCall.phase != .idle)
            case .active:
                BackgroundKeepAlive.shared.appWillEnterForeground()
            default:
                break
            }
        }
        .defaultSize(width: 1080, height: 740)

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(store)
                .frame(minWidth: 520, minHeight: 560)
        }
        #endif
    }
}
