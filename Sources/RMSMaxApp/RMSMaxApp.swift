import SwiftUI
import RMSMaxCore

@main
struct RMSMaxApp: App {
    @StateObject private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true
    @AppStorage("appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                BackgroundKeepAlive.shared.appDidEnterBackground(callActive: store.activeCall.phase != .idle)
            case .active:
                BackgroundKeepAlive.shared.appWillEnterForeground()
                Task { await PermissionsCenter.shared.refresh() } // the user may have switched something in system settings
            default:
                break
            }
        }
        .defaultSize(width: 1080, height: 740)
        .commands { RMSMaksCommands() }

        #if os(macOS)
        Settings {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(appearance == "light" ? .light : (appearance == "dark" ? .dark : nil))
                .frame(minWidth: 520, minHeight: 560)
        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarContent().environmentObject(store)
        } label: {
            let unread = store.chats.filter { !$0.isMuted }.reduce(0) { $0 + $1.newMessages }
            Image(systemName: unread > 0 ? "bubble.left.and.exclamationmark.bubble.right.fill" : "bubble.left.and.bubble.right")
        }
        #endif
    }
}
