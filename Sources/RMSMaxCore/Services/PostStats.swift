// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public struct PostStats: Equatable, Sendable {
    public var views: Int
    public var forwards: Int
}

public extension AppStore {
    /// op 74 Chat.MsgGetStat `{chatId, messageIds, readOnly: true}` -> `{stats: {messageId: {views, forwards}}}` — channel posts only.
    func loadPostStats(chatId: Int64, messages: [MaxMessage]) async {
        guard chats.first(where: { $0.id == chatId })?.type == .channel else { return }
        let ids = messages.suffix(60).compactMap { Int64($0.id) }
        guard !ids.isEmpty else { return }
        guard let resp = try? await client.sendAndWait(opcode: 74, payload: .object([
            "chatId": .int(chatId), "messageIds": .array(ids.map { .int($0) }), "readOnly": .bool(true),
        ])) else { return }
        for (key, val) in resp.payload["stats"]?.objectValue ?? [:] {
            postStats["\(chatId)_\(key)"] = PostStats(views: Int(val["views"]?.int64Value ?? 0), forwards: Int(val["forwards"]?.int64Value ?? 0))
        }
    }

    /// 1 200 -> «1,2 тыс.»
    static func compactCount(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1f млн", Double(n) / 1_000_000)
            : n >= 10_000 ? "\(n / 1000) тыс."
            : n >= 1000 ? String(format: "%.1f тыс.", Double(n) / 1000)
            : "\(n)"
    }
}
