// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public struct ChatReactions: Equatable, Sendable {
    public var isActive: Bool
    /// Reactions the chat allows; empty = the standard set.
    public var ids: [String]
}

public extension AppStore {
    /// The standard set shown first, like Telegram's bar.
    static let defaultReactions = ["❤️", "👍", "🔥", "😂", "😮", "😢", "🎉", "👏", "🤔", "👎", "💯", "🙏"]

    /// op 258 Reactions.GetChatReactions `{chatIds}` -> `{chatReactionsSettings: [{chatId, isActive, reactionIds}]}`.
    func loadChatReactions(chatId: Int64) async {
        guard let resp = try? await client.sendAndWait(opcode: 258, payload: .object(["chatIds": .array([.int(chatId)])])) else { return }
        if !UserDefaults.standard.bool(forKey: "rmsmaks.reactions.logged.39") {
            UserDefaults.standard.set(true, forKey: "rmsmaks.reactions.logged.39")
            ProtocolLog.add("reactions 258 raw: \(String(String(describing: resp.payload).prefix(900)))")
        }
        for item in resp.payload["chatReactionsSettings"]?.arrayValue ?? [] {
            let id = item["chatId"]?.int64Value ?? chatId
            let ids = (item["reactionIds"]?.arrayValue ?? []).compactMap(\.stringValue)
            chatReactions[id] = ChatReactions(isActive: item["isActive"]?.boolValue ?? true, ids: ids)
        }
    }

    /// What the reaction picker offers in this chat. Only plain emoji ids are used; animated reaction ids stay with the server.
    func availableReactions(chatId: Int64) -> [String] {
        guard let s = chatReactions[chatId] else { return Self.defaultReactions }
        guard s.isActive else { return [] }
        let emoji = s.ids.filter { $0.unicodeScalars.contains { $0.value > 0x2000 } && $0.count <= 8 }
        return emoji.isEmpty ? Self.defaultReactions : emoji
    }
}

extension AppStore {
    /// People who can be @-mentioned in a chat: its members whose names are known.
    func mentionCandidates(chatId: Int64) -> [MentionCandidate] {
        guard let chat = chats.first(where: { $0.id == chatId }) else { return [] }
        let myId = currentAccount?.userId
        return chat.participants.keys.compactMap { id in
            guard id != myId, let c = contacts[id], !c.name.isEmpty else { return nil }
            return MentionCandidate(id: id, name: c.name)
        }
    }
}
