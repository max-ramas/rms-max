// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// «💬 12 комментариев» under a channel post.
struct CommentsButton: View {
    let message: MaxMessage
    @State private var showing = false

    var body: some View {
        if let n = message.commentsCount {
            Button { showing = true } label: {
                Label(n == 0 ? "Комментировать" : "\(n) \(AppStore.commentsWord(n))", systemImage: "bubble.left.and.bubble.right")
                    .font(.caption.bold())
            }
            .buttonStyle(.borderless)
            .sheet(isPresented: $showing) { CommentsSheet(post: message) }
        }
    }
}

/// Discussion under one post: list, composer, periodic refresh.
struct CommentsSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let post: MaxMessage
    @State private var draft = ""
    @State private var loading = true
    @State private var failed = false
    @State private var sending = false

    private var comments: [MaxMessage] { store.commentsByPost[store.commentsKey(post.chatId, post.id)] ?? [] }
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "dd.MM HH:mm"; return f
    }()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text(post.displayText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
                    .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.08))
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            if loading && comments.isEmpty { ProgressView().frame(maxWidth: .infinity).padding() }
                            if failed && comments.isEmpty {
                                Text("Не удалось загрузить комментарии. Возможно, они отключены или сервер ответил ошибкой — подробности в журнале диагностики.")
                                    .font(.caption).foregroundStyle(.secondary).padding()
                            } else if !loading && comments.isEmpty {
                                Text("Комментариев пока нет — напишите первым.").foregroundStyle(.secondary).padding()
                            }
                            ForEach(comments) { c in
                                HStack(alignment: .top, spacing: 8) {
                                    AvatarView(url: store.contacts[c.senderId]?.avatarURL, title: store.contacts[c.senderId]?.name ?? "", size: 30)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack {
                                            Text(store.contacts[c.senderId]?.name ?? "Участник").font(.caption.bold())
                                            Text(Self.timeFormat.string(from: c.date)).font(.caption2).foregroundStyle(.secondary)
                                        }
                                        Text(linkified(c.bodyText.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)))
                                            .textSelection(.enabled)
                                    }
                                }
                                .id(c.id)
                            }
                        }
                        .padding(12)
                    }
                    .onChange(of: comments.count) { _, _ in
                        if let last = comments.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                Divider()
                HStack {
                    TextField("", text: $draft, prompt: Text("Комментарий"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "paperplane.fill") }
                        .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || sending)
                }
                .padding(10)
            }
            .navigationTitle("Комментарии")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                failed = !(await store.loadComments(chatId: post.chatId, postId: post.id))
                loading = false
                // The server pushes new comments with its own routing; poll gently while the sheet is open.
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 8_000_000_000)
                    if Task.isCancelled { break }
                    _ = await store.loadComments(chatId: post.chatId, postId: post.id)
                }
            }
        }
        .macSheet(width: 480, height: 560)
    }

    private func send() {
        let t = draft
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        sending = true
        Task {
            if await store.sendComment(chatId: post.chatId, postId: post.id, text: t) { draft = "" }
            sending = false
        }
    }
}
