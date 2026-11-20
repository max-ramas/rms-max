// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// «Отправить позже»: pick a time for the text in the composer.
struct ScheduleSendSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let text: String
    var elements: [TextElement] = []
    let onScheduled: () -> Void
    @State private var date = Date().addingTimeInterval(3600)

    var body: some View {
        NavigationStack {
            Form {
                Section("Сообщение") { Text(text).lineLimit(4) }
                DatePicker("Когда отправить", selection: $date, in: Date().addingTimeInterval(60)...)
            }
            .formStyle(.grouped)
            .navigationTitle("Отправить позже")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Запланировать") {
                        Task { if await store.scheduleMessage(chatId: chatId, text: text, at: date, richElements: elements) { onScheduled(); dismiss() } }
                    }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 300)
    }
}

/// Messages waiting for their time; each can be deleted.
struct ScheduledListSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    @State private var items: [MaxMessage] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && items.isEmpty { Text("Запланированных сообщений нет").foregroundStyle(.secondary) }
                ForEach(items) { m in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.displayText).lineLimit(3)
                            Text(m.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            Task { await store.deleteScheduled(chatId: chatId, messageId: m.id); items.removeAll { $0.id == m.id } }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("Запланированные")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task { items = await store.loadScheduled(chatId: chatId); loaded = true }
        }
        .frame(minWidth: 380, minHeight: 320)
    }
}
