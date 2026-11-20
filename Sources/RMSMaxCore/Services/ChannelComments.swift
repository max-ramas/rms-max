import Foundation

/// Comments under channel posts. The official client addresses a post's comment thread by the channel id plus `postId`:
/// op 49 `{chatId, postId, from, backward, getMessages}`, op 64 `{chatId, postId, message}`, op 91 `{chatId, postIds}` -> counters.
public extension AppStore {
    func commentsKey(_ chatId: Int64, _ postId: String) -> String { "\(chatId)_\(postId)" }

    @discardableResult
    func loadComments(chatId: Int64, postId: String) async -> Bool {
        guard let pid = Int64(postId) else { return false }
        do {
            let resp = try await client.sendAndWait(opcode: 49, payload: .object([
                "chatId": .int(chatId), "postId": .int(pid),
                "from": .int(Int64(Date().timeIntervalSince1970 * 1000) + 60_000),
                "forward": .int(0), "backward": .int(100),
                "getMessages": .bool(true), "interactive": .bool(true),
            ]))
            let list = (resp.payload["messages"]?.arrayValue ?? []).map { parseMessage($0, chatId: chatId) }.sorted { $0.timeMs < $1.timeMs }
            commentsByPost[commentsKey(chatId, postId)] = list
            await ensureContacts(list.map(\.senderId))
            return true
        } catch {
            ProtocolLog.add("comments load op=49 post=\(postId) failed: \(error.localizedDescription)")
            return false
        }
    }

    func sendComment(chatId: Int64, postId: String, text: String) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let pid = Int64(postId) else { return false }
        do {
            _ = try await client.sendAndWait(opcode: 64, payload: .object([
                "chatId": .int(chatId), "postId": .int(pid),
                "message": .object([
                    "cid": .int(-Int64(Date().timeIntervalSince1970 * 1000)),
                    "text": .string(t), "elements": .array([]), "attaches": .array([]),
                ]),
                "notify": .bool(true),
            ]))
            await loadComments(chatId: chatId, postId: postId)
            if let i = messagesByChat[chatId]?.firstIndex(where: { $0.id == postId }) {
                messagesByChat[chatId]?[i].commentsCount = (messagesByChat[chatId]?[i].commentsCount ?? 0) + 1
            }
            return true
        } catch {
            errorBanner = "Комментарий не отправлен: \(error.localizedDescription)"
            return false
        }
    }

    /// op 91: fresh comment counters for visible posts.
    func refreshCommentCounts(chatId: Int64, messages: [MaxMessage]) async {
        guard chats.first(where: { $0.id == chatId })?.type == .channel else { return }
        let ids = messages.filter { $0.commentsCount != nil }.suffix(40).compactMap { Int64($0.id) }
        guard !ids.isEmpty,
              let resp = try? await client.sendAndWait(opcode: 91, payload: .object(["chatId": .int(chatId), "postIds": .array(ids.map { .int($0) })]))
        else { return }
        for u in resp.payload["commentsInfoUpdates"]?.arrayValue ?? [] {
            guard let pid = u["postId"]?.int64Value, let total = u["commentsInfo"]?["totalCount"]?.int64Value,
                  let i = messagesByChat[chatId]?.firstIndex(where: { $0.id == String(pid) }) else { continue }
            messagesByChat[chatId]?[i].commentsCount = Int(total)
        }
    }
}

public extension AppStore {
    /// 1 комментарий, 2–4 комментария, 5+ комментариев.
    static func commentsWord(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        if m100 >= 11 && m100 <= 14 { return "комментариев" }
        switch m10 {
        case 1: return "комментарий"
        case 2...4: return "комментария"
        default: return "комментариев"
        }
    }
}
