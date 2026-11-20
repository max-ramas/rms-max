// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

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
                .onOpenURL { store.incomingURL = $0 }
                #if os(macOS)
                // The chat list (min 320: the whole top button panel fits) and the chat (min 380) must always fit, otherwise AppKit squeezes the list
                // down to a few letters and the toolbar buttons disappear.
                .frame(minWidth: 720, minHeight: 520)
                .background(WindowStateKeeper(frameKey: "rmsmaks.window.main.frame", splitKey: "rmsmaks.window.main.sidebarWidth",
                                              sidebarMin: 320, sidebarMax: 520, minWindowWidth: 720))
                #endif
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
                .background(WindowStateKeeper(frameKey: "rmsmaks.window.settings.frame"))
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
