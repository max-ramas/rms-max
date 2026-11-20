// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// Bots (inline keyboards, /start), joining chats/channels by link, voice transcription.
public extension AppStore {
    // MARK: - Bots

    enum BotAction {
        case done
        case openURL(URL)
        case copy(String)
        case unsupported(String)
    }

    /// Official handling per button type; CALLBACK/CHAT go to the bot via op 118.
    func pressBotButton(_ button: BotKeyboard.Button, keyboard: BotKeyboard, chatId: Int64, messageId: String? = nil) async -> BotAction {
        switch button.type {
        case "LINK":
            return button.url.flatMap(URL.init(string:)).map(BotAction.openURL) ?? .done
        case "CLIPBOARD":
            return .copy(button.payload ?? "")
        case "MESSAGE":
            await sendTextMessage(chatId: chatId, plaintext: button.text)
            return .done
        case "CALLBACK", "CHAT":
            var payload: [String: JSONValue] = [
                // Mobile protocol (rumax): {chatId, messageId, callbackId, payload}.
                "chatId": .int(chatId),
                "callbackId": .string(keyboard.callbackId),
                "type": .string(button.type),
                "timestamp": .int(Int64(Date().timeIntervalSince1970 * 1000)),
            ]
            if let p = button.payload { payload["payload"] = .string(p) }
            if let mid = messageId.flatMap(Int64.init) { payload["messageId"] = .int(mid) }
            do {
                let resp = try await client.sendAndWait(opcode: 118, payload: .object(payload))
                if let chat = resp.payload["chat"] { await applyChatUpdate(chat) }
                if let msg = resp.payload["message"] {
                    upsertMessage(parseMessage(msg, chatId: chatId), inChat: chatId, isIncomingPush: true)
                }
                if let token = resp.payload["chatAccessToken"]?.stringValue {
                    await joinChat(fields: ["chatAccessToken": .string(token)])
                } else if let link = resp.payload["chat"]?["link"]?.stringValue {
                    await joinChat(fields: ["link": .string(link)])
                }
            } catch {
                errorBanner = "Бот не ответил: \(error.localizedDescription)"
            }
            return .done
        case "REQUEST_GEO_LOCATION":
            return .unsupported("RMS MAKS не передаёт геопозицию ботам")
        case "REQUEST_CONTACT":
            return .unsupported("Отправку своего номера боту RMS MAKS не поддерживает")
        case "OPEN_APP":
            return .unsupported("Мини-приложения не поддерживаются: в них свои трекеры")
        default:
            return .unsupported("Кнопка этого типа не поддерживается")
        }
    }

    /// `/start` for a bot dialog (CONTROL botStarted).
    func startBot(chatId: Int64, payload: String? = nil) async {
        var control: [String: JSONValue] = ["_type": .string("CONTROL"), "event": .string("botStarted")]
        if let payload { control["startPayload"] = .string(payload) }
        do {
            _ = try await client.sendAndWait(opcode: 64, payload: .object([
                "chatId": .int(chatId),
                "message": .object(["cid": .int(-Int64(Date().timeIntervalSince1970 * 1000)), "attaches": .array([.object(control)])]),
            ]))
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Channels / chats by link (op 89 preview, op 57 join)

    struct LinkPreview: Sendable {
        public let title: String
        public let isChannel: Bool
        public let participants: Int?
        public let alreadyMember: Bool
        public let chatId: Int64?
        public let userId: Int64?
    }

    func resolveLink(_ link: String) async -> LinkPreview? {
        let clean = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resp = try? await client.sendAndWait(opcode: 89, payload: .object(["link": .string(clean)])) else { return nil }
        if let chat = resp.payload["chat"] {
            let parsed = parseChat(chat)
            return LinkPreview(
                title: parsed.title, isChannel: parsed.type == .channel, participants: parsed.participantsCount,
                alreadyMember: chats.contains { $0.id == parsed.id }, chatId: parsed.id, userId: nil
            )
        }
        if let user = resp.payload["user"]?["contact"] {
            let c = parseContactValue(user)
            contacts[c.id] = c
            return LinkPreview(title: c.name, isChannel: false, participants: nil, alreadyMember: false, chatId: nil, userId: c.id)
        }
        return nil
    }

    func joinByLink(_ link: String) async {
        await joinChat(fields: ["link": .string(link.trimmingCharacters(in: .whitespacesAndNewlines))])
    }

    private func joinChat(fields: [String: JSONValue]) async {
        do {
            let resp = try await client.sendAndWait(opcode: 57, payload: .object(fields))
            if let raw = resp.payload["chat"] {
                await applyChatUpdate(raw)
                selectedChatId = raw["id"]?.int64Value
            }
        } catch {
            errorBanner = "Не удалось вступить: \(error.localizedDescription)"
        }
    }

    // MARK: - Voice transcription (opt-in; the MAX server does the recognition)

    static let transcriptionSettingKey = "rmsmaks.voice.transcription"

    var transcriptionEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.transcriptionSettingKey)
    }

    /// op 202 `{chatId, messageId, mediaId}` → `{transcription, transcriptionStatus}`; push 293 when ready.
    func requestTranscription(chatId: Int64, messageId: String, mediaId: Int64) async {
        guard transcriptionEnabled, let mid = Int64(messageId) else { return }
        let key = "\(chatId):\(messageId)"
        transcriptions[key] = transcriptions[key] ?? "…"
        do {
            let resp = try await client.sendAndWait(opcode: 202, payload: .object([
                "chatId": .int(chatId), "messageId": .int(mid), "mediaId": .int(mediaId),
            ]))
            applyTranscription(resp.payload, chatId: chatId, messageId: messageId)
        } catch {
            transcriptions[key] = "Не удалось расшифровать"
        }
    }

    internal func applyTranscription(_ p: JSONValue, chatId: Int64? = nil, messageId: String? = nil) {
        guard let cid = chatId ?? p["chatId"]?.int64Value,
              let mid = messageId ?? p["messageId"]?.stringValue else { return }
        let key = "\(cid):\(mid)"
        if let text = p["transcription"]?.stringValue, !text.isEmpty {
            transcriptions[key] = text
        } else if p["transcriptionStatus"]?.int64Value == 3 {
            transcriptions[key] = "Речь не распознана"
        }
    }
}
