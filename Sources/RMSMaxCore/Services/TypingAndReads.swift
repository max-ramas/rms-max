import Foundation

/// «Печатает…», read marks and chat-list actions — opcodes of the official client:
/// 65 `{chatId, type}` (send typing), push 129 `{chatId, userId, type}`, push 130 `{chatId, userId, mark, unread, setAsUnread}`,
/// 50 READ_MESSAGE, 22 settings (mute), 52 delete chat.
public extension AppStore {
    /// Default on, like the official client; can be switched off in Settings (then nothing is sent).
    var sendsTyping: Bool {
        get { UserDefaults.standard.object(forKey: Self.sendTypingKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.sendTypingKey); objectWillChange.send() }
    }

    /// At most once per 6 s per chat (the official throttle); errors are ignored.
    func sendTyping(chatId: Int64, kind: String = "TEXT") {
        guard sendsTyping, isConnected, !UnsupportedOpcodes.contains(65) else { return }
        if let last = lastTypingSent[chatId], Date().timeIntervalSince(last) < 6 { return }
        lastTypingSent[chatId] = Date()
        Task { _ = try? await client.sendAndWait(opcode: 65, payload: .object(["chatId": .int(chatId), "type": .string(kind)])) }
    }

    /// Push 129; the indicator disappears after 8 s without a refresh.
    func applyTypingPush(_ p: JSONValue) {
        guard let chatId = p["chatId"]?.int64Value, let userId = p["userId"]?.int64Value, userId != currentAccount?.userId else { return }
        typingByChat[chatId, default: [:]][userId] = p["type"]?.stringValue ?? "TEXT"
        let key = "\(chatId)|\(userId)"
        let token = (typingTokens[key] ?? 0) + 1
        typingTokens[key] = token
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard let self, self.typingTokens[key] == token else { return }
            self.typingTokens[key] = nil
            self.typingByChat[chatId]?[userId] = nil
            if self.typingByChat[chatId]?.isEmpty == true { self.typingByChat[chatId] = nil }
        }
        Task { await ensureContacts([userId]) }
    }

    /// «Иван печатает…», «Иван и Мария печатают…», «Иван, Мария и ещё 2 печатают…»; nil when nobody types.
    func typingText(chatId: Int64) -> String? {
        guard let users = typingByChat[chatId], !users.isEmpty else { return nil }
        let isDialog = chats.first { $0.id == chatId }?.type == .dialog
        let kinds = Set(users.values)
        func verb(_ plural: Bool) -> String {
            if kinds == ["AUDIO"] { return plural ? "записывают голосовое…" : "записывает голосовое…" }
            if kinds == ["VIDEO_MSG"] { return plural ? "записывают видео…" : "записывает видео…" }
            if kinds.isSubset(of: ["PHOTO", "VIDEO", "FILE"]) { return plural ? "отправляют файл…" : "отправляет файл…" }
            return plural ? "печатают…" : "печатает…"
        }
        if isDialog { return verb(false) }
        let names = users.keys.sorted().map { contacts[$0]?.firstName.nonEmpty ?? contacts[$0]?.name ?? "Участник" }
        switch names.count {
        case 1: return "\(names[0]) \(verb(false))"
        case 2: return "\(names[0]) и \(names[1]) \(verb(true))"
        default: return "\(names[0]), \(names[1]) и ещё \(names.count - 2) \(verb(true))"
        }
    }

    /// Push 130 / reply of op 50: the mark is the time (ms) of the last message read by `userId`.
    func applyReadMarkPush(_ p: JSONValue) {
        guard let cid = p["chatId"]?.int64Value, let idx = chats.firstIndex(where: { $0.id == cid }) else { return }
        let uid = p["userId"]?.int64Value
        let mark = p["mark"]?.int64Value
        if let uid, uid != currentAccount?.userId {
            if let mark, mark > (chats[idx].participants[uid] ?? 0) { chats[idx].participants[uid] = mark }
            return
        }
        if p["setAsUnread"]?.boolValue != true { chats[idx].newMessages = 0 }
    }

    /// Time (ms) up to which the other side of a dialog has read; 0 when unknown or for groups.
    func peerReadMark(in chat: MaxChat) -> Int64 {
        guard chat.type == .dialog, let peer = dialogPeerId(for: chat) else { return 0 }
        return chat.participants[peer] ?? 0
    }

    func markChatRead(_ chatId: Int64) async {
        guard let chat = chats.first(where: { $0.id == chatId }), let last = chat.lastMessage, let mid = Int64(last.id) else { return }
        _ = try? await client.readMessage(chatId: chatId, messageId: mid, markMs: last.timeMs)
        if let i = chats.firstIndex(where: { $0.id == chatId }) { chats[i].newMessages = 0 }
    }

    /// op 22 `{settings:{chats:{id:{dontDisturbUntil}}}}`; -1 = muted forever, 0 = on.
    func setChatMuted(_ chatId: Int64, muted: Bool) async {
        let value: Int64 = muted ? -1 : 0
        do {
            _ = try await client.sendAndWait(opcode: 22, payload: .object([
                "settings": .object(["chats": .object([String(chatId): .object(["dontDisturbUntil": .int(value)])])]),
            ]))
            if let i = chats.firstIndex(where: { $0.id == chatId }) { chats[i].dontDisturbUntil = value }
        } catch {
            errorBanner = "Не удалось изменить уведомления: \(error.localizedDescription)"
        }
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
