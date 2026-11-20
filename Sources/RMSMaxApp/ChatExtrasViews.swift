// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import SwiftUI
import RMSMaxCore

/// Photos and videos of a chat (op 51) as a grid inside the info form.
struct ChatMediaSection: View {
    @EnvironmentObject private var store: AppStore
    let chatId: Int64
    @State private var items: [(msg: MaxMessage, url: String)] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: 4)]

    var body: some View {
        Section("Медиа") {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if items.isEmpty {
                Text("Фото и видео нет").foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(items, id: \.url) { it in
                        RemoteImage(url: it.url)
                            .aspectRatio(1, contentMode: .fill)
                            .frame(minWidth: 84, minHeight: 84)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture { Task { await store.openMessage(chatId: chatId, message: it.msg) } }
                    }
                }
            }
        }
        .task {
            let msgs = await store.chatMedia(chatId: chatId)
            items = msgs.flatMap { m in
                m.attaches.compactMap { a in a.url.map { (m, $0) } }.filter { _ in true }
            }
            .prefix(60).map { $0 }
            loaded = true
        }
    }
}

/// Clear history / delete chat, with confirmation (ops 54 / 52).
struct ChatDangerSection: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: MaxChat
    @State private var confirmClear = false
    @State private var confirmDelete = false

    var body: some View {
        Section {
            Button("Очистить историю…", role: .destructive) { confirmClear = true }
            Button(chat.type == .dialog ? "Удалить чат…" : "Удалить и покинуть…", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Очистить историю?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Только у меня", role: .destructive) { Task { await store.clearHistory(chatId: chat.id, forAll: false) } }
            if chat.type == .dialog {
                Button("У меня и у собеседника", role: .destructive) { Task { await store.clearHistory(chatId: chat.id, forAll: true) } }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сообщения будут удалены без возможности восстановления.")
        }
        .confirmationDialog("Удалить чат?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Удалить у меня", role: .destructive) {
                Task { await store.deleteChat(chatId: chat.id, forAll: false); dismiss() }
            }
            if chat.type == .dialog {
                Button("Удалить у обоих", role: .destructive) {
                    Task { await store.deleteChat(chatId: chat.id, forAll: true); dismiss() }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Чат и его история пропадут из списка. Это нельзя отменить.")
        }
    }
}

/// The user's profile photos (op 39).
struct ProfilePhotosSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let userId: Int64
    @State private var urls: [String] = []
    @State private var index = 0
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if !loaded {
                    ProgressView().tint(.white)
                } else if urls.isEmpty, let one = store.contacts[userId]?.avatarURL {
                    RemoteImage(url: one).padding()
                } else if urls.isEmpty {
                    Text("Фото нет").foregroundStyle(.white)
                } else {
                    RemoteImage(url: urls[index]).padding()
                    HStack {
                        Button { index = max(0, index - 1) } label: { Image(systemName: "chevron.left.circle.fill").font(.largeTitle) }
                            .disabled(index == 0)
                        Spacer()
                        Button { index = min(urls.count - 1, index + 1) } label: { Image(systemName: "chevron.right.circle.fill").font(.largeTitle) }
                            .disabled(index >= urls.count - 1)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding()
                }
            }
            .navigationTitle(urls.count > 1 ? "Фото \(index + 1) из \(urls.count)" : "Фото")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
            .task {
                urls = await store.profilePhotos(userId: userId)
                loaded = true
            }
        }
        .macSheet(width: 520, height: 560)
    }
}

/// Who voted for an answer (op 305).
struct PollVotersSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let messageId: String
    let pollId: Int64
    let answer: (id: Int64, text: String)
    @State private var ids: [Int64] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && ids.isEmpty { Text("Голосов нет или голосование анонимное").foregroundStyle(.secondary) }
                ForEach(ids, id: \.self) { id in
                    HStack {
                        AvatarView(url: store.contacts[id]?.avatarURL, title: store.contacts[id]?.name ?? "", size: 28)
                        Text(store.contacts[id]?.name ?? "Участник")
                    }
                }
            }
            .navigationTitle(answer.text)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .task {
                ids = await store.pollVoters(chatId: chatId, messageId: messageId, pollId: pollId, answerId: answer.id)
                loaded = true
            }
        }
        .macSheet(width: 400, height: 460)
    }
}

/// Who reacted with what (op 181).
struct ReactionsDetailSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    let messageId: String
    @State private var voters: [ReactionVoter] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            List {
                if loaded && voters.isEmpty { Text("Нет данных").foregroundStyle(.secondary) }
                ForEach(voters) { v in
                    HStack {
                        AvatarView(url: store.contacts[v.userId]?.avatarURL, title: store.contacts[v.userId]?.name ?? "", size: 28)
                        Text(store.contacts[v.userId]?.name ?? "Участник")
                        Spacer()
                        Text(v.reaction)
                    }
                }
            }
            .navigationTitle("Реакции")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Готово") { dismiss() } } }
            .task {
                voters = await store.detailedReactions(chatId: chatId, messageId: messageId)
                loaded = true
            }
        }
        .macSheet(width: 400, height: 460)
    }
}

/// «/» menu with the bot's commands (op 144) next to the composer.
struct BotCommandsButton: View {
    @EnvironmentObject private var store: AppStore
    let chatId: Int64
    let onSelect: (String) -> Void
    @State private var commands: [BotCommand] = []

    var body: some View {
        Menu {
            if commands.isEmpty { Text("Команд нет") }
            ForEach(commands) { c in
                Button(c.description.map { "/\(c.name) — \($0)" } ?? "/\(c.name)") { onSelect("/" + c.name) }
            }
        } label: {
            Image(systemName: "slash.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Команды бота")
        .task(id: chatId) { commands = await store.botCommands(chatId: chatId) }
    }
}

private struct LinkBox: Identifiable { let id: String }

/// Public channels, groups, bots and users from op 60, shown under chat search.
struct PublicSearchSection: View {
    @EnvironmentObject private var store: AppStore
    let query: String
    @State private var hits: [PublicSearchHit] = []
    @State private var openLink: String?

    var body: some View {
        Section("Каналы, боты и люди в MAX") {
            if hits.isEmpty { Text("Ничего не найдено").font(.caption).foregroundStyle(.secondary) }
            ForEach(hits) { h in
                Button {
                    if h.isUser { store.openDialog(with: h.id) }
                    else if store.chats.contains(where: { $0.id == h.id }) { store.selectedChatId = h.id }
                    else if let link = h.link { openLink = link }
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(url: h.avatarURL, title: h.title, symbol: h.isChannel ? "megaphone.fill" : nil, size: 32)
                        VStack(alignment: .leading) {
                            Text(h.title).lineLimit(1)
                            Text(h.isChannel ? "канал" : (h.isBot ? "бот" : (h.isUser ? "пользователь" : "группа")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sheet(item: Binding(get: { openLink.map(LinkBox.init) }, set: { openLink = $0?.id })) { JoinByLinkSheet(initialLink: $0.id) }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            hits = await store.searchPublic(query)
        }
    }
}
