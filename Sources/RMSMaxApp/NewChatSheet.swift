// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// New group or channel: title + members from the address book, like the official client.
struct NewChatSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var isChannel = false
    @State private var query = ""
    @State private var selected: Set<Int64> = []
    @State private var creating = false

    private var candidates: [MaxContact] {
        let me = store.currentAccount?.userId
        let q = query.lowercased()
        return store.contacts.values
            .filter { $0.isInContacts == true && $0.id != me && $0.isBot != true }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Тип", selection: $isChannel) {
                        Text("Группа").tag(false)
                        Text("Канал").tag(true)
                    }
                    .pickerStyle(.segmented)
                    TextField("Название", text: $title, prompt: Text(isChannel ? "Название канала" : "Название группы"))
                } footer: {
                    Text(isChannel
                         ? "Пишут только администраторы, подписчики читают."
                         : "После создания можно включить групповое сквозное шифрование: значок 🔒 в шапке чата.")
                }

                Section {
                    TextField("Поиск", text: $query, prompt: Text("Найти в контактах"))
                    if candidates.isEmpty {
                        Text("Контактов нет — участников можно добавить позже").foregroundStyle(.secondary)
                    }
                    ForEach(candidates) { c in
                        Button {
                            if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
                        } label: {
                            HStack(spacing: 10) {
                                AvatarView(url: c.avatarURL, title: c.name, size: 30)
                                Text(c.name)
                                Spacer()
                                Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(c.id) ? Color.accentColor : .secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text(isChannel ? "Подписчики (\(selected.count))" : "Участники (\(selected.count))")
                }
            }
            .navigationTitle(isChannel ? "Новый канал" : "Новая группа")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(creating ? "Создаём…" : "Создать") {
                        creating = true
                        let t = title.trimmedForm
                        let ids = Array(selected)
                        let channel = isChannel
                        Task {
                            let id = await store.createChat(title: t, userIds: ids, channel: channel)
                            creating = false
                            if id != nil { dismiss() }
                        }
                    }
                    .disabled(title.trimmedForm.isEmpty || creating)
                }
            }
        }
        .macSheet(width: 480, height: 560)
    }
}
