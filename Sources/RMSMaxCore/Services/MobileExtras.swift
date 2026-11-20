import Foundation

public struct BotCommand: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let description: String?
}

public struct PublicSearchHit: Identifiable, Sendable {
    public let id: Int64
    public let title: String
    public let avatarURL: String?
    public let link: String?
    public let isChannel: Bool
    public let isBot: Bool
    public let isUser: Bool
}

public struct ReactionVoter: Identifiable, Sendable {
    public var id: String { "\(userId)|\(reaction)" }
    public let userId: Int64
    public let reaction: String
}

/// Mobile-protocol features from rumax/maxplus: delete/clear chat, chat media, public search, bot commands,
/// poll voters, detailed reactions, call invite link, profile photo gallery.
public extension AppStore {
    /// op 52 `{chatId, lastEventTime, forAll}`.
    func deleteChat(chatId: Int64, forAll: Bool) async {
        let last = chats.first { $0.id == chatId }?.lastEventTime ?? Int64(Date().timeIntervalSince1970 * 1000)
        do {
            _ = try await client.sendAndWait(opcode: 52, payload: .object([
                "chatId": .int(chatId), "lastEventTime": .int(last), "forAll": .bool(forAll),
            ]))
            chats.removeAll { $0.id == chatId }
            messagesByChat[chatId] = nil
            if selectedChatId == chatId { selectedChatId = nil }
        } catch {
            errorBanner = "Чат не удалён: \(error.localizedDescription)"
        }
    }

    /// op 54 `{chatId, lastEventTime, forAll}`.
    func clearHistory(chatId: Int64, forAll: Bool) async {
        let last = chats.first { $0.id == chatId }?.lastEventTime ?? Int64(Date().timeIntervalSince1970 * 1000)
        do {
            _ = try await client.sendAndWait(opcode: 54, payload: .object([
                "chatId": .int(chatId), "lastEventTime": .int(last), "forAll": .bool(forAll),
            ]))
            messagesByChat[chatId] = []
            if let i = chats.firstIndex(where: { $0.id == chatId }) { chats[i].lastMessage = nil }
        } catch {
            errorBanner = "История не очищена: \(error.localizedDescription)"
        }
    }

    /// op 51 `{chatId, messageId, attachTypes, forward, backward}` — media of a chat, newest first.
    func chatMedia(chatId: Int64, types: [String] = ["PHOTO", "VIDEO"], before messageId: Int64? = nil, count: Int = 60) async -> [MaxMessage] {
        let from = messageId ?? (chats.first { $0.id == chatId }?.lastMessage.flatMap { Int64($0.id) } ?? 0)
        do {
            let resp = try await client.sendAndWait(opcode: 51, payload: .object([
                "chatId": .int(chatId), "messageId": .int(from), "attachTypes": .array(types.map { .string($0) }),
                "forward": .int(0), "backward": .int(Int64(count)),
            ]))
            let list = resp.payload["messages"]?.arrayValue ?? []
            return list.map { parseMessage($0, chatId: chatId) }.sorted { $0.timeMs > $1.timeMs }
        } catch {
            ProtocolLog.add("chat media op=51 failed: \(error.localizedDescription)")
            return []
        }
    }

    /// op 60 `{query, count, type: ALL}` -> `{result: [{chat} | {contact}]}` — channels, groups, bots, users by name.
    func searchPublic(_ query: String) async -> [PublicSearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2,
              let resp = try? await client.sendAndWait(opcode: 60, payload: .object(["query": .string(q), "count": .int(10), "type": .string("ALL")]))
        else { return [] }
        return (resp.payload["result"]?.arrayValue ?? []).compactMap { e in
            if let chat = e["chat"], let id = chat["id"]?.int64Value {
                return PublicSearchHit(id: id, title: chat["title"]?.stringValue ?? "Канал",
                                       avatarURL: chat["baseIconUrl"]?.stringValue ?? chat["baseRawIconUrl"]?.stringValue,
                                       link: chat["link"]?.stringValue, isChannel: chat["type"]?.stringValue == "CHANNEL",
                                       isBot: false, isUser: false)
            }
            if let raw = e["contact"]?["contact"] ?? e["contact"] {
                let c = parseContactValue(raw)
                if contacts[c.id] == nil { contacts[c.id] = c }
                return PublicSearchHit(id: c.id, title: c.name, avatarURL: c.avatarURL, link: c.link,
                                       isChannel: false, isBot: c.isBot == true, isUser: true)
            }
            return nil
        }
    }

    /// op 144 `{chatId}` -> `{commands: [{name, description}]}`.
    func botCommands(chatId: Int64) async -> [BotCommand] {
        guard let resp = try? await client.sendAndWait(opcode: 144, payload: .object(["chatId": .int(chatId)])) else { return [] }
        return (resp.payload["commands"]?.arrayValue ?? []).compactMap { c in
            guard let n = c["name"]?.stringValue, !n.isEmpty else { return nil }
            return BotCommand(name: n.hasPrefix("/") ? String(n.dropFirst()) : n, description: c["description"]?.stringValue)
        }
    }

    /// op 119 `{botId, value}` — stop (true) or resume (false) a bot.
    func suspendBot(botId: Int64, stop: Bool) async {
        do {
            _ = try await client.sendAndWait(opcode: 119, payload: .object(["botId": .int(botId), "value": .bool(stop)]))
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// op 305 `{chatId, messageId, pollId, answerId, from, count}` -> voter user ids.
    func pollVoters(chatId: Int64, messageId: String, pollId: Int64, answerId: Int64) async -> [Int64] {
        guard let mid = Int64(messageId),
              let resp = try? await client.sendAndWait(opcode: 305, payload: .object([
                "chatId": .int(chatId), "messageId": .int(mid), "pollId": .int(pollId), "answerId": .int(answerId),
                "from": .int(0), "count": .int(100),
              ]))
        else { return [] }
        let raw = resp.payload["voters"]?.arrayValue ?? resp.payload["users"]?.arrayValue ?? resp.payload["contacts"]?.arrayValue ?? []
        let ids = raw.compactMap { $0.int64Value ?? $0["id"]?.int64Value ?? $0["userId"]?.int64Value ?? $0["contact"]?["id"]?.int64Value }
        await ensureContacts(ids)
        return ids
    }

    /// op 181 `{chatId, messageId, count}` -> who reacted with what.
    func detailedReactions(chatId: Int64, messageId: String) async -> [ReactionVoter] {
        guard let mid = Int64(messageId),
              let resp = try? await client.sendAndWait(opcode: 181, payload: .object(["chatId": .int(chatId), "messageId": .int(mid), "count": .int(100)]))
        else { return [] }
        var out: [ReactionVoter] = []
        for r in resp.payload["reactions"]?.arrayValue ?? resp.payload["counters"]?.arrayValue ?? [] {
            let emoji = r["reaction"]?["id"]?.stringValue ?? r["reaction"]?.stringValue ?? r["id"]?.stringValue ?? "?"
            for u in r["users"]?.arrayValue ?? r["userIds"]?.arrayValue ?? [] {
                if let id = u.int64Value ?? u["id"]?.int64Value ?? u["userId"]?.int64Value { out.append(ReactionVoter(userId: id, reaction: emoji)) }
            }
            if let id = r["userId"]?.int64Value { out.append(ReactionVoter(userId: id, reaction: emoji)) }
        }
        if out.isEmpty, let keys = resp.payload.objectValue?.keys { ProtocolLog.add("reactions op=181 keys=\(keys.sorted().joined(separator: ","))") }
        await ensureContacts(out.map(\.userId))
        return out
    }

    /// op 84 `{conversationId}` -> `{link}` — invite link to the running call.
    func callInviteLink(conversationId: String) async -> String? {
        guard let resp = try? await client.sendAndWait(opcode: 84, payload: .object(["conversationId": .string(conversationId)])) else { return nil }
        return (resp.payload["link"]?.stringValue ?? resp.payload["joinLink"]?.stringValue).map(Self.conferenceURL)
    }

    /// The server answers with the bare join token; people need the link the official clients share and open.
    nonisolated static func conferenceURL(_ linkOrToken: String) -> String {
        let t = linkOrToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.hasPrefix("http://") || t.hasPrefix("https://") ? t : "https://max.ru/joincall/\(t)"
    }

    /// op 39 `{contactId, from, count}` -> `{total, urls}` — the user's profile photos.
    func profilePhotos(userId: Int64) async -> [String] {
        guard let resp = try? await client.sendAndWait(opcode: 39, payload: .object(["contactId": .int(userId), "from": .int(0), "count": .int(20)])) else { return [] }
        return (resp.payload["urls"]?.arrayValue ?? resp.payload["photos"]?.arrayValue ?? []).compactMap { $0.stringValue ?? $0["baseUrl"]?.stringValue ?? $0["url"]?.stringValue }
    }
}

public extension AppStore {
    /// Ensures the running call has an invite link (op 84) and returns it.
    func fetchCallInviteLink() async -> String? {
        if let l = activeCall.inviteLink { return l }
        let conv = activeCall.conversationId
        guard !conv.isEmpty, let link = await callInviteLink(conversationId: conv) else {
            errorBanner = "Не удалось получить ссылку на звонок"
            return nil
        }
        activeCall.inviteLink = link
        return link
    }
}

public extension AppStore {
    /// op 73 Search.Message `{chatId, query, count, marker}` -> `{result: [{message, highlights}], marker}`.
    /// Encrypted (E2E) messages are not searchable on the server, so the decrypted ones loaded locally are matched too.
    func searchInChat(chatId: Int64, query raw: String, marker: Int64? = nil) async -> (hits: [MessageSearchHit], next: Int64?) {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return ([], nil) }
        var hits: [MessageSearchHit] = []
        var seen = Set<String>()
        if marker == nil {
            let needle = query.lowercased()
            for m in messagesByChat[chatId] ?? [] where m.decrypted?.isEncrypted == true && m.decrypted?.error == nil {
                if m.bodyText.lowercased().contains(needle) {
                    hits.append(MessageSearchHit(chatId: chatId, message: m, snippet: m.bodyText, isLocalE2E: true))
                    seen.insert(m.id)
                }
            }
        }
        var payload: [String: JSONValue] = ["chatId": .int(chatId), "query": .string(query), "count": .int(30)]
        if let marker { payload["marker"] = .int(marker) }
        do {
            let resp = try await client.sendAndWait(opcode: 73, payload: .object(payload))
            for item in resp.payload["result"]?.arrayValue ?? [] {
                guard let raw = item["message"] else { continue }
                let parsed = parseMessage(raw, chatId: chatId)
                guard seen.insert(parsed.id).inserted else { continue }
                let msg = await decryptAndHandleControl(message: parsed, chatId: chatId)
                hits.append(MessageSearchHit(chatId: chatId, message: msg, snippet: msg.displayText, isLocalE2E: false))
            }
            return (hits, resp.payload["marker"]?.int64Value)
        } catch {
            ProtocolLog.add("chat search op=73 failed: \(error.localizedDescription)")
            return (hits, nil)
        }
    }
}

public extension AppStore {
    /// Creates a conference room like the official client: op 76 `{conversationId}` answers with the `joinLink`
    /// (op 84 stays as a fallback for the invite link).
    func createConference() async -> (id: String, link: String)? {
        let id = UUID().uuidString.lowercased()
        do {
            let resp = try await client.sendAndWait(opcode: 76, payload: .object(["conversationId": .string(id)]))
            if let link = resp.payload["joinLink"]?.stringValue ?? resp.payload["link"]?.stringValue, !link.isEmpty {
                return (id, Self.conferenceURL(link))
            }
            if let link = await callInviteLink(conversationId: id) { return (id, link) }
            return (id, "https://max.ru/joincall/\(id)")
        } catch {
            errorBanner = "Не удалось создать звонок: \(error.localizedDescription)"
            return nil
        }
    }
}
