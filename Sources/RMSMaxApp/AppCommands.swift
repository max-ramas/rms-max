// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#endif

/// Window-level actions triggered from the menu bar, the menu-bar extra or keyboard shortcuts.
enum AppAction: String {
    case contacts, newGroup, callHistory, joinCall, openLink, checkUpdates, quickSwitch, nextChat, previousChat, createConference, settings, about

    static let notification = Notification.Name("RMSMaksAppAction")

    func post() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain && !($0.className.contains("StatusBar")) }?.makeKeyAndOrderFront(nil)
        #endif
        NotificationCenter.default.post(name: Self.notification, object: rawValue)
    }
}

struct RMSMaksCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("О программе RMS MAKS") { AppAction.about.post() }
            Button("Проверить обновления…") { AppAction.checkUpdates.post() }
        }
        CommandGroup(after: .newItem) {
            Button("Новая группа") { AppAction.newGroup.post() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Открыть ссылку MAX…") { AppAction.openLink.post() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Чаты") {
            Button("Быстрый переход…") { AppAction.quickSwitch.post() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Следующий чат") { AppAction.nextChat.post() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Предыдущий чат") { AppAction.previousChat.post() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
        }
        CommandMenu("Контакты") {
            Button("Контакты") { AppAction.contacts.post() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("История звонков") { AppAction.callHistory.post() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Button("Создать конференцию…") { AppAction.createConference.post() }
            Button("Присоединиться к звонку по ссылке…") { AppAction.joinCall.post() }
        }
    }
}

#if os(macOS)
/// Menu-bar ("tray") item: connection state, unread count, quick actions.
struct MenuBarContent: View {
    @EnvironmentObject private var store: AppStore

    private var unread: Int { store.chats.filter { !$0.isMuted }.reduce(0) { $0 + $1.newMessages } }

    var body: some View {
        Text(store.isConnected ? "Подключено" : "Нет подключения")
        if unread > 0 { Text("Непрочитанных: \(unread)") }
        if let u = store.availableUpdate {
            Button("Доступна версия \(u.version)…") { store.updatePromptShown = true; AppAction.checkUpdates.post() }
        }
        Divider()
        Button("Открыть RMS MAKS") { AppAction.contacts.activateOnly() }
        Button("Контакты") { AppAction.contacts.post() }
        Button("Новая группа") { AppAction.newGroup.post() }
        Button("История звонков") { AppAction.callHistory.post() }
        Divider()
        Button("Проверить обновления…") { AppAction.checkUpdates.post() }
        SettingsLink { Text("Настройки…") }
        Button("О программе RMS MAKS") { AppAction.about.post() }
        Divider()
        Button("Выйти из RMS MAKS") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

extension AppAction {
    func activateOnly() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
#endif
