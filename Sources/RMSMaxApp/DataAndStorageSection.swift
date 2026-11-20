// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// Settings → «Данные и память»: what the cache holds, its limit, auto-download rules, cleaning.
struct DataAndStorageSection: View {
    @State private var stats: [MediaKind: Int64] = [:]
    @State private var rules = MediaAutoDownload.current
    @State private var limitMB = MediaAutoDownload.limitMB
    @State private var confirmClear: Set<MediaKind>?

    private var total: Int64 { stats.values.reduce(0, +) }

    var body: some View {
        Section {
            ForEach(MediaKind.allCases) { kind in
                LabeledContent(kind.title, value: MediaCache.formatted(stats[kind] ?? 0))
            }
            LabeledContent("Всего на устройстве") { Text(MediaCache.formatted(total)).bold() }
            Picker("Хранить не больше", selection: $limitMB) {
                Text("500 МБ").tag(500)
                Text("1 ГБ").tag(1024)
                Text("2 ГБ").tag(2048)
                Text("5 ГБ").tag(5120)
                Text("10 ГБ").tag(10240)
                Text("Без ограничений").tag(0)
            }
            Menu("Очистить кэш…") {
                ForEach(MediaKind.allCases) { kind in
                    Button("\(kind.title) — \(MediaCache.formatted(stats[kind] ?? 0))") { confirmClear = [kind] }
                        .disabled((stats[kind] ?? 0) == 0)
                }
                Divider()
                Button("Всё — \(MediaCache.formatted(total))", role: .destructive) { confirmClear = Set(MediaKind.allCases) }
                    .disabled(total == 0)
            }
        } header: {
            Text("Данные и память")
        } footer: {
            Text("Когда кэш превышает лимит, удаляются самые давние файлы. Очистка не затрагивает сообщения: удалённое скачается снова при открытии.")
        }

        Section {
            Toggle("Фото", isOn: $rules.photos)
            Toggle("Видеосообщения (кружки)", isOn: $rules.circles)
            Toggle("Голосовые сообщения", isOn: $rules.voice)
            Picker("Видео до", selection: $rules.videoMaxMB) {
                Text("Не загружать").tag(0)
                Text("10 МБ").tag(10); Text("20 МБ").tag(20); Text("50 МБ").tag(50); Text("100 МБ").tag(100)
            }
            Picker("Файлы до", selection: $rules.fileMaxMB) {
                Text("Не загружать").tag(0)
                Text("5 МБ").tag(5); Text("10 МБ").tag(10); Text("25 МБ").tag(25); Text("50 МБ").tag(50)
            }
            Toggle("Загружать и по мобильной сети", isOn: $rules.onMeteredNetwork)
        } header: {
            Text("Автозагрузка")
        } footer: {
            Text("Выбранное скачивается заранее — при открытии чата и для новых сообщений, поэтому кружки, голосовые и фото открываются сразу. Файлы из зашифрованных (E2E) чатов заранее не сохраняются. По мобильной сети или через точку доступа без разрешения загружаются только голосовые.")
        }
        .onChange(of: rules) { _, new in MediaAutoDownload.current = new }
        .onChange(of: limitMB) { _, new in
            MediaAutoDownload.limitMB = new
            MediaCache.scheduleLimitCheck()
        }
        .task { await refresh() }
        .confirmationDialog("Очистить кэш?", isPresented: Binding(get: { confirmClear != nil }, set: { if !$0 { confirmClear = nil } }), titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                if let kinds = confirmClear { MediaCache.clear(kinds: kinds) }
                confirmClear = nil
                Task { await refresh() }
            }
            Button("Отмена", role: .cancel) { confirmClear = nil }
        } message: {
            Text("Файлы удалятся с устройства; при необходимости скачаются заново.")
        }
    }

    private func refresh() async {
        stats = await Task.detached(priority: .utility) { MediaCache.stats() }.value
    }
}
