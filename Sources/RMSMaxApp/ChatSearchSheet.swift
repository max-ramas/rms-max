// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// Search inside one chat (⌘F): results from the server (op 73) and from decrypted E2E messages.
struct ChatSearchSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    @State private var query = ""
    @State private var hits: [MessageSearchHit] = []
    @State private var next: Int64?
    @State private var loading = false
    @State private var searched = false

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yy HH:mm"
        return f
    }()

    var body: some View {
        NavigationStack {
            List {
                if searched && hits.isEmpty && !loading {
                    Text("Ничего не найдено").foregroundStyle(.secondary)
                }
                ForEach(hits) { hit in
                    Button {
                        Task { await store.openMessage(chatId: chatId, message: hit.message); dismiss() }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(store.contacts[hit.message.senderId]?.name ?? (hit.message.senderId == store.currentAccount?.userId ? "Вы" : "Участник"))
                                    .font(.caption.bold()).foregroundStyle(.secondary)
                                Spacer()
                                Text(Self.timeFormat.string(from: hit.message.date)).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(hit.snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)).lineLimit(3)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if next != nil {
                    Button("Показать ещё") { Task { await more() } }
                        .disabled(loading)
                }
                if loading { ProgressView().frame(maxWidth: .infinity) }
            }
            .searchable(text: $query, placement: .toolbar, prompt: "Поиск в чате")
            .onSubmit(of: .search) { Task { await run() } }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                await run()
            }
            .navigationTitle("Поиск в чате")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .macSheet(width: 520, height: 560)
    }

    private func run() async {
        let q = query
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { hits = []; next = nil; searched = false; return }
        loading = true
        let r = await store.searchInChat(chatId: chatId, query: q)
        guard q == query else { return }
        hits = r.hits; next = r.next; searched = true; loading = false
    }

    private func more() async {
        guard let marker = next else { return }
        loading = true
        let r = await store.searchInChat(chatId: chatId, query: query, marker: marker)
        hits += r.hits; next = r.next; loading = false
    }
}
