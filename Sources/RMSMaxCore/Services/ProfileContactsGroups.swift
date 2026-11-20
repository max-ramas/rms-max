// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public struct GroupMember: Identifiable, Equatable, Sendable {
    public let id: Int64
    public var name: String
    public var isAdmin: Bool
    public var isOwner: Bool
}

/// Profile editing, contacts (add / rename / remove / block) and group administration,
/// with the official client's opcodes.
public extension AppStore {
    // MARK: - Profile (op 16; avatar via op 80 `profile:true` upload)

    func updateProfile(firstName: String, lastName: String, description: String?) async {
        var payload: [String: JSONValue] = ["firstName": .string(firstName)]
        if !lastName.isEmpty { payload["lastName"] = .string(lastName) }
        if let description { payload["description"] = .string(description) }
        await sendProfileUpdate(payload)
    }

    func setProfilePhoto(data: Data, mime: String) async {
        do {
            let token = try await client.uploadPhoto(data: data, mime: mime, profile: true)
            let me = currentAccount?.userId.flatMap { contacts[$0] }
            var payload: [String: JSONValue] = [
                "firstName": .string(me?.firstName ?? currentAccount?.displayName ?? ""),
                "photoToken": .string(token),
                "avatarType": .string("USER_AVATAR"),
            ]
            if let last = me?.lastName, !last.isEmpty { payload["lastName"] = .string(last) }
            await sendProfileUpdate(payload)
        } catch {
            errorBanner = "Фото не загружено: \(error.localizedDescription)"
        }
    }

    private func sendProfileUpdate(_ payload: [String: JSONValue]) async {
        do {
            let resp = try await client.sendAndWait(opcode: 16, payload: .object(payload))
            if let contact = resp.payload["profile"]?["contact"] {
                let c = parseContactValue(contact)
                contacts[c.id] = c
                if var acc = currentAccount {
                    acc.displayName = c.name
                    acc.avatarURL = c.avatarURL ?? acc.avatarURL
                    currentAccount = acc
                }
            }
        } catch {
            errorBanner = "Профиль не обновлён: \(error.localizedDescription)"
        }
    }

    // MARK: - Contacts (op 41 add by phone, op 34 actions, op 36 blacklist)

    /// Mobile protocol (as rumax): op 46 finds the user by phone, op 34 `ADD` saves them with my name for them.
    @discardableResult
    func addContact(phone: String, firstName: String, lastName: String) async -> MaxContact? {
        guard let found = await findUser(phone: phone) else {
            errorBanner = "Пользователь с номером \(phone) не найден в MAX"
            return nil
        }
        var payload: [String: JSONValue] = [
            "contactId": .int(found.id), "action": .string("ADD"),
            "firstName": .string(firstName.isEmpty ? found.firstName : firstName),
        ]
        if !lastName.isEmpty { payload["lastName"] = .string(lastName) }
        do {
            let resp = try await client.sendAndWait(opcode: 34, payload: .object(payload))
            var c = resp.payload["contact"].map(parseContactValue) ?? found
            c.isInContacts = true
            contacts[c.id] = c
            return c
        } catch {
            errorBanner = "Контакт не добавлен: \(error.localizedDescription)"
            return nil
        }
    }

    /// `ADD | REMOVE | BLOCK | UNBLOCK | UPDATE`.
    func contactAction(_ contactId: Int64, action: String, firstName: String? = nil, lastName: String? = nil) async {
        var payload: [String: JSONValue] = ["contactId": .int(contactId), "action": .string(action)]
        if let firstName { payload["firstName"] = .string(firstName) }
        if let lastName, !lastName.isEmpty { payload["lastName"] = .string(lastName) }
        do {
            let resp = try await client.sendAndWait(opcode: 34, payload: .object(payload))
            var c = resp.payload["contact"].map(parseContactValue) ?? contacts[contactId]
            switch action {
            case "BLOCK": c?.isBlocked = true
            case "UNBLOCK": c?.isBlocked = false
            case "REMOVE": c?.isInContacts = false
            case "ADD": c?.isInContacts = true
            default: break
            }
            if let c { contacts[c.id] = c }
            if action == "BLOCK" || action == "UNBLOCK" { await loadBlacklist() }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func loadBlacklist() async {
        do {
            let resp = try await client.sendAndWait(opcode: 36, payload: .object(["status": .string("BLOCKED"), "count": .int(100), "from": .int(0)]))
            blockedContacts = (resp.payload["contacts"]?.arrayValue ?? []).map {
                var c = parseContactValue($0)
                c.isBlocked = true
                contacts[c.id] = c
                return c
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - Groups (op 59 members, 77 membership/admins/requests, 55 settings, 58 leave, 221–223 links)

    func loadMembers(chatId: Int64) async -> [GroupMember] {
        // Dialogs have no member list: op 59 answers «chat not found» for them.
        guard let chat = chats.first(where: { $0.id == chatId }), chat.type != .dialog else { return [] }
        do {
            let resp = try await client.sendAndWait(opcode: 59, payload: .object([
                "type": .string("MEMBER"), "chatId": .int(chatId), "count": .int(500),
            ]))
            return (resp.payload["members"]?.arrayValue ?? []).compactMap { m in
                guard let raw = m["contact"] else { return nil }
                let c = parseContactValue(raw)
                contacts[c.id] = c
                return GroupMember(id: c.id, name: c.name, isAdmin: chat.adminIds.contains(c.id), isOwner: chat.ownerId == c.id)
            }
        } catch {
            errorBanner = error.localizedDescription
            return []
        }
    }

    func loadJoinRequests(chatId: Int64) async -> [MaxContact] {
        let resp = try? await client.sendAndWait(opcode: 59, payload: .object([
            "type": .string("JOIN_REQUEST"), "chatId": .int(chatId), "count": .int(50), "query": .string(""),
        ]))
        return (resp?.payload["members"]?.arrayValue ?? []).compactMap { $0["contact"].map(parseContactValue) }
    }


    /// op 77. `type`: nil (members) | "ADMIN" | "JOIN_REQUEST" | "BLOCKED_MEMBER"; `operation`: add | remove.
    func changeMembers(chatId: Int64, userIds: [Int64], operation: String, type: String? = nil, showHistory: Bool? = nil) async {
        var payload: [String: JSONValue] = [
            "chatId": .int(chatId),
            "userIds": .array(userIds.map { .int($0) }),
            "operation": .string(operation),
        ]
        if let type { payload["type"] = .string(type) }
        if let showHistory { payload["showHistory"] = .bool(showHistory) }
        if type == "ADMIN" {
            await setAdmin(chatId: chatId, userId: userIds.first ?? 0, permissions: operation == "add" ? Self.adminPermissions : nil)
            return
        }
        do {
            let resp = try await client.sendAndWait(opcode: 77, payload: .object(payload))
            if let raw = resp.payload["chat"] { await applyChatUpdate(raw) }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// op 55: title / description / options / photo / private-link reset / owner transfer.
    func updateChat(chatId: Int64, fields: [String: JSONValue]) async {
        var payload = fields
        payload["chatId"] = .int(chatId)
        do {
            let resp = try await client.sendAndWait(opcode: 55, payload: .object(payload))
            if let raw = resp.payload["chat"] { await applyChatUpdate(raw) }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func setChatPhoto(chatId: Int64, data: Data, mime: String) async {
        do {
            let token = try await client.uploadPhoto(data: data, mime: mime)
            await updateChat(chatId: chatId, fields: ["photoToken": .string(token)])
        } catch {
            errorBanner = "Фото не загружено: \(error.localizedDescription)"
        }
    }

    func leaveChat(chatId: Int64) async {
        do {
            _ = try await client.sendAndWait(opcode: 58, payload: .object(["chatId": .int(chatId)]))
            chats.removeAll { $0.id == chatId }
            if selectedChatId == chatId { selectedChatId = nil }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// Mobile protocol: a chat has one private link (`chat.link`); op 55 `{chatId, revokePrivateLink: true}`
    /// issues a new one and invalidates the old (web-only ops 221-223 are unknown to the mobile server).
    func resetInviteLink(chatId: Int64) async {
        await updateChat(chatId: chatId, fields: ["revokePrivateLink": .bool(true)])
    }

    /// Group options via op 55 `options`; both spellings, as the official mobile client sends them.
    func setChatOption(chatId: Int64, key: String, value: Bool) async {
        let camel: [String: String] = [
            "ALL_CAN_PIN_MESSAGE": "allCanPinMessage", "ONLY_OWNER_CAN_CHANGE_ICON_TITLE": "onlyOwnerCanChangeIconTitle",
            "ONLY_ADMIN_CAN_ADD_MEMBER": "onlyAdminCanAddMember", "ONLY_ADMIN_CAN_CALL": "onlyAdminCanCall",
            "MEMBERS_CAN_SEE_PRIVATE_LINK": "membersCanSeePrivateLink",
        ]
        var opts: [String: JSONValue] = [key: .bool(value)]
        if let c = camel[key] { opts[c] = .bool(value) }
        await updateChat(chatId: chatId, fields: ["options": .object(opts)])
    }

    /// Admin rights strings of the mobile protocol.
    static let adminPermissions = ["CHANGE_CHAT_INFO", "DELETE_OTHERS_MESSAGES", "PIN_MESSAGE", "ADD_REMOVE_MEMBERS", "ADD_ADMINS", "CALL"]

    /// op 55 `adminParticipants: {userId: {permissions:[...]}}`; `null` revokes.
    func setAdmin(chatId: Int64, userId: Int64, permissions: [String]?) async {
        let entry: JSONValue = permissions.map { .object(["permissions": .array($0.map { .string($0) })]) } ?? .null
        await updateChat(chatId: chatId, fields: ["adminParticipants": .object([String(userId): entry])])
    }
}

public extension AppStore {
    /// op 64 with a CONTROL `new` attach (as the official client): creates a group (`CHAT`) or channel (`CHANNEL`),
    /// adds it to the list and opens it.
    @discardableResult
    func createChat(title: String, userIds: [Int64], channel: Bool = false) async -> Int64? {
        do {
            let resp = try await client.sendAndWait(opcode: 64, payload: .object([
                "message": .object([
                    "cid": .int(Int64(Date().timeIntervalSince1970 * 1000)),
                    "attaches": .array([.object([
                        "_type": .string("CONTROL"), "event": .string("new"),
                        "chatType": .string(channel ? "CHANNEL" : "CHAT"), "title": .string(title),
                        "userIds": .array(userIds.map { .int($0) }),
                    ])]),
                ]),
                "notify": .bool(true),
            ]))
            guard let raw = resp.payload["chat"] else {
                errorBanner = "Сервер не вернул созданный чат"
                return nil
            }
            await applyChatUpdate(raw)
            let id = raw["id"]?.int64Value
            selectedChatId = id
            return id
        } catch {
            errorBanner = "Не удалось создать: \(error.localizedDescription)"
            return nil
        }
    }
}
