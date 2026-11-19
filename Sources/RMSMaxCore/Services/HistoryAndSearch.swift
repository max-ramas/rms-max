import Foundation

public struct MessageSearchHit: Identifiable, Sendable, Equatable {
    public var id: String { "\(chatId)_\(message.id)" }
    public let chatId: Int64
    public let message: MaxMessage
    /// Text to show in the result row (decrypted for E2E chats).
    public let snippet: String
    /// True when the hit was found locally among decrypted E2E messages.
    public let isLocalE2E: Bool
}

extension AppStore {
    // MARK: - History paging

    /// Loads the next page of older messages for a chat (opcode 49 with `from` = oldest loaded message).
    public func loadOlderMessages(chatId: Int64, pageSize: Int = 50) async {
        guard !historyExhausted.contains(chatId), !loadingOlderHistory.contains(chatId) else { return }
        guard let oldest = messagesByChat[chatId]?.first else { return }
        loadingOlderHistory.insert(chatId)
        defer { loadingOlderHistory.remove(chatId) }
        do {
            let resp = try await client.fetchHistory(chatId: chatId, from: oldest.timeMs, backward: pageSize, forward: 0, getChat: false)
            let fresh = await decodeHistory(resp, chatId: chatId)
            let known = Set((messagesByChat[chatId] ?? []).map(\.id))
            let added = fresh.filter { !known.contains($0.id) && $0.timeMs <= oldest.timeMs }
            if added.isEmpty {
                historyExhausted.insert(chatId)
                return
            }
            var list = messagesByChat[chatId] ?? []
            list.append(contentsOf: added)
            list.sort { $0.timeMs < $1.timeMs }
            messagesByChat[chatId] = list
            if fresh.count < pageSize / 2 { historyExhausted.insert(chatId) }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// Makes sure a specific message is loaded (fetching history around it) and asks the chat view to scroll there.
    public func openMessage(chatId: Int64, message: MaxMessage) async {
        if selectedChatId != chatId {
            await selectChat(chatId)
        }
        if messagesByChat[chatId]?.contains(where: { $0.id == message.id }) != true {
            do {
                let resp = try await client.fetchHistory(chatId: chatId, from: message.timeMs, backward: 30, forward: 30, getChat: false)
                let around = await decodeHistory(resp, chatId: chatId)
                var byId = Dictionary(uniqueKeysWithValues: (messagesByChat[chatId] ?? []).map { ($0.id, $0) })
                for m in around { byId[m.id] = m }
                messagesByChat[chatId] = byId.values.sorted { $0.timeMs < $1.timeMs }
                historyExhausted.remove(chatId)
            } catch {
                errorBanner = error.localizedDescription
            }
        }
        scrollTargetMessageId = message.id
    }

    func decodeHistory(_ resp: MaxResponse, chatId: Int64) async -> [MaxMessage] {
        var result: [MaxMessage] = []
        for raw in resp.payload["messages"]?.arrayValue ?? [] {
            let parsed = parseMessage(raw, chatId: chatId)
            result.append(await decryptAndHandleControl(message: parsed, chatId: chatId))
        }
        return result.sorted { $0.timeMs < $1.timeMs }
    }

    // MARK: - Search

    /// Server search (plain chats) + local search over already decrypted E2E messages, which the server cannot index.
    public func searchMessages(_ rawQuery: String) async {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            messageSearchHits = []
            return
        }
        isSearchingMessages = true
        defer { isSearchingMessages = false }

        var hits: [MessageSearchHit] = []
        var seen = Set<String>()
        let needle = query.lowercased()

        for (chatId, messages) in messagesByChat {
            for m in messages where m.decrypted?.isEncrypted == true && m.decrypted?.error == nil {
                let body = m.bodyText
                guard body.lowercased().contains(needle) else { continue }
                let hit = MessageSearchHit(chatId: chatId, message: m, snippet: body, isLocalE2E: true)
                if seen.insert(hit.id).inserted { hits.append(hit) }
            }
        }

        do {
            let resp = try await client.searchMessages(query: query)
            guard query == rawQuery.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            for item in resp.payload["result"]?.arrayValue ?? [] {
                guard let chatId = item["chatId"]?.int64Value, let raw = item["message"] else { continue }
                let parsed = parseMessage(raw, chatId: chatId)
                let msg = await decryptAndHandleControl(message: parsed, chatId: chatId)
                let hit = MessageSearchHit(chatId: chatId, message: msg, snippet: msg.displayText, isLocalE2E: false)
                if seen.insert(hit.id).inserted { hits.append(hit) }
            }
        } catch {
            // Local E2E hits are still useful when the server search fails.
        }
        messageSearchHits = hits.sorted { $0.message.timeMs > $1.message.timeMs }
    }
}
