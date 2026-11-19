import Foundation

/// Pin, forward, edit and delete-for-everyone — the official client's opcodes.
public extension AppStore {
    /// Typed chat id used by newer opcodes (`{type, primaryId}`: 0 dialog, 1 chat, 2 channel).
    nonisolated static func typedChatId(_ chat: MaxChat) -> JSONValue {
        let type: Int64
        switch chat.type {
        case .chat: type = 1
        case .channel: type = 2
        default: type = 0
        }
        return .object(["type": .int(type), "primaryId": .int(chat.id)])
    }

    /// Max opcode 242: `{chatId(typed), action 0 pin | 1 unpin | 2 unpin all, messageIds, forMe, notify}`.
    func setPinned(chatId: Int64, messageId: String, pinned: Bool, notify: Bool = true) async {
        guard let chat = chats.first(where: { $0.id == chatId }), let mid = Int64(messageId) else { return }
        var payload: [String: JSONValue] = [
            "chatId": Self.typedChatId(chat),
            "action": .int(pinned ? 0 : 1),
            "messageIds": .array([.int(mid)]),
            "notify": .bool(notify),
        ]
        if pinned { payload["forMe"] = .bool(false) }
        do {
            let resp = try await client.sendAndWait(opcode: 242, payload: .object(payload))
            applyPinnedState(resp.payload["pinnedMessagesState"], chatId: chatId, fallback: pinned ? messageId : nil)
        } catch {
            errorBanner = "Не удалось закрепить: \(error.localizedDescription)"
        }
    }

    /// Push 243 / reply of 242 — the newest pinned message of a chat.
    func applyPinnedState(_ state: JSONValue?, chatId: Int64? = nil, fallback: String? = nil) {
        let id = chatId ?? state?["chatId"]?["primaryId"]?.int64Value
        guard let id, let i = chats.firstIndex(where: { $0.id == id }) else { return }
        if let state {
            let total = state["totalPinnedMessagesCount"]?.int64Value ?? 0
            chats[i].pinnedMessageId = total > 0 ? state["lastPinnedMessageId"]?.stringValue : nil
        } else {
            chats[i].pinnedMessageId = fallback
        }
    }

    /// Forward. Plain messages use the server-side FORWARD link (keeps the original author like
    /// the official client); E2E messages are re-sent as their decrypted content, so the target
    /// chat can read them (and they get re-encrypted if that chat is E2E too).
    func forward(_ message: MaxMessage, to targetChatId: Int64) async {
        if message.decrypted != nil {
            await sendTextMessage(chatId: targetChatId, plaintext: message.bodyText)
            return
        }
        guard let mid = Int64(message.id) else { return }
        let cid = -Int64(Date().timeIntervalSince1970 * 1000)
        do {
            _ = try await client.sendAndWait(opcode: 64, payload: .object([
                "chatId": .int(targetChatId),
                "message": .object([
                    "cid": .int(cid),
                    "link": .object(["type": .string("FORWARD"), "messageId": .int(mid), "chatId": .int(message.chatId)]),
                    "attaches": .array([]),
                ]),
                "notify": .bool(true),
            ]))
        } catch {
            errorBanner = "Не удалось переслать: \(error.localizedDescription)"
        }
    }

    /// Max opcode 67. Encrypted messages are edited by sending the new text encrypted again.
    func editMessage(chatId: Int64, messageId: String, newText: String) async {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let mid = Int64(messageId) else { return }
        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        do {
            let wire: String
            if settings.isActive {
                let key = settings.session.flatMap { Data(hexString: $0.sharedSecretHex) }
                let packed = try E2EProtocol.packMessage(payload: .text(text), sessionKey: key, password: settings.password, chatId: chatId)
                wire = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
            } else {
                wire = text
            }
            _ = try await client.editMessage(chatId: chatId, messageId: mid, text: wire)
            if let i = messagesByChat[chatId]?.firstIndex(where: { $0.id == messageId }) {
                messagesByChat[chatId]?[i].edited = true
                if messagesByChat[chatId]?[i].decrypted != nil {
                    messagesByChat[chatId]?[i].decrypted?.text = text
                } else {
                    messagesByChat[chatId]?[i].text = text
                }
            }
        } catch {
            errorBanner = "Не удалось изменить: \(error.localizedDescription)"
        }
    }
}
