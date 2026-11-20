import Foundation

/// A chat folder (official schema: id, title, emoji, include/exclude chat ids, filters, options).
public struct ChatFolder: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var emoji: String?
    public var include: [Int64]
    public var exclude: [Int64]
    public var filters: [Int]
    public var options: [Int]
    /// Pinned chats of this folder, in display order (`favorites`).
    public var favorites: [Int64] = []

    /// Official filter ids (subset we evaluate locally).
    public enum Filter: Int, CaseIterable, Sendable {
        case unread = 0, read = 1, channel = 2, chat = 3, dialog = 4, owner = 5, admin = 6
        case muted = 7, contact = 8, notContact = 9, bot = 10, notMuted = 11, markedUnread = 12

        public var title: String {
            switch self {
            case .unread: return "Непрочитанные"
            case .read: return "Прочитанные"
            case .channel: return "Каналы"
            case .chat: return "Группы"
            case .dialog: return "Личные"
            case .owner: return "Я владелец"
            case .admin: return "Я админ"
            case .muted: return "Без звука"
            case .contact: return "Контакты"
            case .notContact: return "Не контакты"
            case .bot: return "Боты"
            case .notMuted: return "Со звуком"
            case .markedUnread: return "Отмеченные непрочитанными"
            }
        }
    }

    public init(id: String, title: String, emoji: String? = nil, include: [Int64] = [], exclude: [Int64] = [], filters: [Int] = [], options: [Int] = []) {
        self.id = id
        self.title = title
        self.emoji = emoji
        self.include = include
        self.exclude = exclude
        self.filters = filters
        self.options = options
    }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.stringValue, let title = v["title"]?.stringValue else { return nil }
        self.init(
            id: id, title: title, emoji: v["emoji"]?.stringValue,
            include: (v["include"]?.arrayValue ?? []).compactMap(\.int64Value),
            exclude: (v["exclude"]?.arrayValue ?? []).compactMap(\.int64Value),
            filters: (v["filters"]?.arrayValue ?? []).compactMap { $0.int64Value.map(Int.init) },
            options: (v["options"]?.arrayValue ?? []).compactMap { $0.int64Value.map(Int.init) }
        )
        favorites = (v["favorites"]?.arrayValue ?? []).compactMap(\.int64Value)
    }
}

public extension AppStore {
    // MARK: - Polls

    /// op 304 `{chatId, messageId, pollId, answersIds}` → `{state}`.
    func vote(chatId: Int64, messageId: String, poll: MaxPoll, answerIds: [Int]) async {
        guard let mid = Int64(messageId) else { return }
        do {
            let resp = try await client.sendAndWait(opcode: 304, payload: .object([
                "chatId": .int(chatId), "messageId": .int(mid), "pollId": .int(poll.pollId),
                "answersIds": .array(answerIds.map { .int(Int64($0)) }),
            ]))
            guard let i = messagesByChat[chatId]?.firstIndex(where: { $0.id == messageId }),
                  let j = messagesByChat[chatId]?[i].attaches.firstIndex(where: { $0.poll?.pollId == poll.pollId })
            else { return }
            var updated = poll
            // The server may answer without per-user flags; mark our choice locally.
            for k in updated.answers.indices { updated.answers[k].votedByMe = answerIds.contains(updated.answers[k].id) }
            updated.apply(state: resp.payload["state"])
            messagesByChat[chatId]?[i].attaches[j].poll = updated
        } catch {
            errorBanner = "Голос не принят: \(error.localizedDescription)"
        }
    }

    // MARK: - Folders (272 list, 274 save, 276 delete, push 277)

    func loadFolders() async {
        guard let resp = try? await client.sendAndWait(opcode: 272, payload: .object(["folderSync": .int(0)])) else { return }
        applyFolders(resp.payload)
    }

    internal func applyFolders(_ p: JSONValue) {
        guard let list = p["folders"]?.arrayValue else { return }
        // The server's own "all chats" folder duplicates our «Все» tab.
        let isAll: (ChatFolder) -> Bool = {
            $0.include.isEmpty && $0.filters.isEmpty && ($0.id.lowercased().contains("all") || $0.title.lowercased() == "все")
        }
        let all = list.compactMap(ChatFolder.init)
        serverAllFolder = all.first(where: isAll)
        var parsed = all.filter { !isAll($0) }
        if let order = p["foldersOrder"]?.arrayValue?.compactMap(\.stringValue), !order.isEmpty {
            parsed.sort { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
        }
        folders = parsed
    }

    func saveFolder(_ f: ChatFolder) async {
        var payload: [String: JSONValue] = [
            "id": .string(f.id), "title": .string(f.title),
            "include": .array(f.include.map { .int($0) }),
            "filters": .array(f.filters.map { .int(Int64($0)) }),
            "options": .array(f.options.map { .int(Int64($0)) }),
            "favorites": .array(f.favorites.map { .int($0) }),
        ]
        if let e = f.emoji { payload["emoji"] = .string(e) }
        do {
            let resp = try await client.sendAndWait(opcode: 274, payload: .object(payload))
            if resp.payload["folders"] != nil { applyFolders(resp.payload) } else { await loadFolders() }
        } catch {
            errorBanner = "Папка не сохранена: \(error.localizedDescription)"
        }
    }

    func deleteFolder(_ id: String) async {
        do {
            _ = try await client.sendAndWait(opcode: 276, payload: .object(["folderIds": .array([.string(id)])]))
            folders.removeAll { $0.id == id }
            if selectedFolderId == id { selectedFolderId = nil }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// Local evaluation of folder membership: explicit chats ∪ filter matches, minus exclusions.
    func chats(in folder: ChatFolder) -> [MaxChat] {
        let me = currentAccount?.userId
        return chats.filter { chat in
            if folder.exclude.contains(chat.id) { return false }
            if folder.include.contains(chat.id) { return true }
            guard !folder.filters.isEmpty else { return false }
            return folder.filters.contains { raw in
                guard let f = ChatFolder.Filter(rawValue: raw) else { return false }
                switch f {
                case .unread: return chat.newMessages > 0
                case .read: return chat.newMessages == 0
                case .channel: return chat.type == .channel
                case .chat: return chat.type == .chat
                case .dialog: return chat.type == .dialog
                case .owner: return me != nil && chat.ownerId == me
                case .admin: return me.map { chat.adminIds.contains($0) } ?? false
                case .muted: return chat.isMuted
                case .notMuted: return !chat.isMuted
                case .contact:
                    return chat.type == .dialog && (dialogPeerId(for: chat).flatMap { contacts[$0]?.isInContacts } ?? false)
                case .notContact:
                    return chat.type == .dialog && !(dialogPeerId(for: chat).flatMap { contacts[$0]?.isInContacts } ?? false)
                case .bot, .markedUnread: return false
                }
            }
        }
    }
}
