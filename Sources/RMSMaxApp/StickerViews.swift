// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Image from a Max CDN URL, cached on disk.
struct RemoteImage: View {
    let url: String
    @State private var data: Data?

    var body: some View {
        Group {
            #if os(macOS)
            if let data, let img = NSImage(data: data) {
                Image(nsImage: img).resizable().scaledToFit()
            } else { placeholder }
            #else
            if let data, let img = UIImage(data: data) {
                Image(uiImage: img).resizable().scaledToFit()
            } else { placeholder }
            #endif
        }
        .task(id: url) { data = await MediaCache.remoteImage(url) }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1))
    }
}

/// Sticker keyboard: local recents, the user's packs and search.
struct StickerPicker: View {
    @EnvironmentObject private var store: AppStore
    let onPick: (Sticker) -> Void
    @State private var selected = "recent"
    @State private var query = ""
    @State private var results: [Sticker] = []
    @State private var managing = false

    private let columns = [GridItem(.adaptive(minimum: 72), spacing: 8)]

    var body: some View {
        VStack(spacing: 8) {
            TextField("Поиск стикеров", text: $query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { results = await store.searchStickers(query) } }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    tab("recent", "Недавние")
                    ForEach(store.stickerPacks) { tab($0.id, $0.title) }
                    Button { managing = true } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("Мои стикеры")
                }
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(current, id: \.id) { s in
                        Button { onPick(s) } label: {
                            RemoteImage(url: s.displayURL).frame(width: 72, height: 72)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if current.isEmpty {
                    Text(query.isEmpty ? (selected == "recent" ? "Здесь появятся отправленные стикеры" : "Загрузка…") : "Ничего не найдено")
                        .font(.caption).foregroundStyle(.secondary).padding()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $managing) { StickerManageSheet().environmentObject(store) }
        .task {
            if store.stickerPacks.isEmpty { await store.loadStickerPacks() }
        }
        .task(id: selected) {
            if let pack = store.stickerPacks.first(where: { $0.id == selected }) {
                await store.ensureStickers(pack.stickerIds)
            }
        }
    }

    private var current: [Sticker] {
        if !query.trimmingCharacters(in: .whitespaces).isEmpty { return results }
        if selected == "recent" { return store.recentStickers }
        guard let pack = store.stickerPacks.first(where: { $0.id == selected }) else { return [] }
        return pack.stickerIds.compactMap { store.stickerCache[$0] }
    }

    private func tab(_ id: String, _ title: String) -> some View {
        Button(title) { selected = id; query = "" }
            .buttonStyle(.bordered)
            .tint(selected == id ? .accentColor : .secondary)
            .controlSize(.small)
    }
}

/// Report a message, chat or user to MAX moderation (official reasons list).
struct ComplaintSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let target: ComplaintTarget
    let ids: [Int64]
    let parentId: Int64?
    @State private var reasons: [ComplaintReason] = []
    @State private var sent = false

    var body: some View {
        NavigationStack {
            List {
                if sent {
                    Label("Жалоба отправлена", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if reasons.isEmpty {
                    ProgressView()
                }
                ForEach(reasons) { r in
                    Button(r.title) {
                        Task {
                            sent = await store.sendComplaint(target: target, ids: ids, reasonId: r.id, parentId: parentId)
                            if sent { try? await Task.sleep(nanoseconds: 900_000_000); dismiss() }
                        }
                    }
                    .disabled(sent)
                }
            }
            .navigationTitle("Пожаловаться")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } } }
            .task { reasons = await store.complaintReasons(for: target) }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 380)
        #endif
    }
}

/// «Мои стикеры»: remove packs, add one by link, clear recents.
struct StickerManageSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var busy = false

    var body: some View {
        NavigationStack {
            List {
                Section("Добавить набор по ссылке") {
                    HStack {
                        TextField("Ссылка на набор стикеров", text: $link)
                        Button("Добавить") {
                            busy = true
                            Task { if await store.addStickerSet(link: link) { link = "" }; busy = false }
                        }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                    }
                }
                Section("Мои наборы") {
                    ForEach(store.stickerPacks.filter { $0.id.hasPrefix("set-") }) { pack in
                        HStack {
                            Text(pack.title)
                            Spacer()
                            Button(role: .destructive) {
                                if let id = Int64(pack.id.dropFirst(4)) { Task { await store.removeStickerSet(id: id) } }
                            } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                        }
                    }
                }
                Section { Button("Очистить недавние", role: .destructive) { Task { await store.clearRecentStickers() } } }
            }
            .navigationTitle("Мои стикеры")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
        .frame(minWidth: 400, minHeight: 420)
    }
}
