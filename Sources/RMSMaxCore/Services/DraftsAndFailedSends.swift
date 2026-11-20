// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// A message that could not be sent: kept on the device (text or the file itself) until the user retries or deletes it.
public struct FailedSend: Identifiable, Sendable {
    public struct Attachment: Sendable {
        public var data: Data
        public var fileName: String
        public var mime: String
        public var width: Int?
        public var height: Int?
        public var durationMs: Int?
        public var wave: [UInt8]?
        public var isVideoMessage = false
    }

    public let id = UUID()
    public let chatId: Int64
    public var text: String
    public var replyToId: String?
    public var attachment: Attachment?
    public var error: String
    public let date = Date()

    public var preview: String {
        if let a = attachment { return text.isEmpty ? (a.isVideoMessage ? "Видеосообщение" : (a.wave != nil ? "Голосовое сообщение" : a.fileName)) : text }
        return text
    }
}

/// Drafts live only on the device (the official client keeps them locally too) and are stored per account.
public extension AppStore {
    private var draftsKey: String { "rmsmaks.drafts.\(currentAccount?.id ?? 0)" }

    func loadDrafts() {
        drafts = (UserDefaults.standard.dictionary(forKey: draftsKey) as? [String: String] ?? [:])
            .reduce(into: [:]) { if let id = Int64($1.key), !$1.value.isEmpty { $0[id] = $1.value } }
    }

    func setDraft(chatId: Int64, text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text
        if t.isEmpty { guard drafts[chatId] != nil else { return }; drafts[chatId] = nil } else { drafts[chatId] = t }
        UserDefaults.standard.set(drafts.reduce(into: [String: String]()) { $0[String($1.key)] = $1.value }, forKey: draftsKey)
    }

    // MARK: - Failed sends

    func recordFailedSend(chatId: Int64, text: String, replyToId: String?, attachment: FailedSend.Attachment?, error: Error) {
        let item = FailedSend(chatId: chatId, text: text, replyToId: replyToId, attachment: attachment, error: error.localizedDescription)
        failedSends[chatId, default: []].append(item)
    }

    /// Retries the saved message: the entry is removed first and re-added by the send itself if it fails again.
    func retryFailedSend(_ item: FailedSend) async {
        failedSends[item.chatId]?.removeAll { $0.id == item.id }
        if failedSends[item.chatId]?.isEmpty == true { failedSends[item.chatId] = nil }
        if let a = item.attachment, a.isVideoMessage {
            await sendVideoMessage(chatId: item.chatId, data: a.data, durationMs: a.durationMs ?? 0, width: a.width ?? 480, height: a.height ?? 480)
        } else if let a = item.attachment {
            await sendAttachment(chatId: item.chatId, data: a.data, fileName: a.fileName, mime: a.mime, caption: item.text,
                                 width: a.width, height: a.height, durationMs: a.durationMs, wave: a.wave)
        } else {
            await sendTextMessage(chatId: item.chatId, plaintext: item.text, replyToId: item.replyToId)
        }
    }

    func discardFailedSend(_ item: FailedSend) {
        failedSends[item.chatId]?.removeAll { $0.id == item.id }
        if failedSends[item.chatId]?.isEmpty == true { failedSends[item.chatId] = nil }
    }
}
