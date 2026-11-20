// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// MAX account privacy (who finds me, calls me, invites me, sees my number and online status).
struct PrivacySettingsSection: View {
    @EnvironmentObject private var store: AppStore

    private func choice(_ title: String, _ key: String, _ options: [(String, String)]) -> some View {
        Picker(title, selection: Binding(
            get: { store.privacyChoice(key) },
            set: { v in Task { await store.setPrivacy(key, to: .string(v)) } }
        )) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func flag(_ title: String, _ key: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { store.privacyFlag(key) },
            set: { v in Task { await store.setPrivacy(key, to: .bool(v)) } }
        ))
    }

    var body: some View {
        Section("Приватность аккаунта MAX") {
            choice("Найти меня по номеру", "SEARCH_BY_PHONE", [("ALL", "Все"), ("CONTACTS", "Только контакты")])
            choice("Кто может мне звонить", "INCOMING_CALL", [("ALL", "Все"), ("CONTACTS", "Только контакты")])
            choice("Кто может приглашать в чаты", "CHATS_INVITE", [("ALL", "Все"), ("CONTACTS", "Только контакты")])
            choice("Кто видит мой номер", "PHONE_NUMBER_PRIVACY", [("ALL", "Все"), ("CONTACTS", "Контакты"), ("NOBODY", "Никто")])
            flag("Скрыть статус «в сети»", "HIDDEN")
            flag("Показывать контент 18+", "CONTENT_LEVEL_ACCESS")
        }
    }
}
