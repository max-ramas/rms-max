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

    @discardableResult
    func addContact(phone: String, firstName: String, lastName: String) async -> MaxContact? {
        var payload: [String: JSONValue] = ["phone": .string(phone)]
        if !firstName.isEmpty { payload["firstName"] = .string(firstName) }
        if !lastName.isEmpty { payload["lastName"] = .string(lastName) }
        do {
            let resp = try await client.sendAndWait(opcode: 41, payload: .object(payload))
            guard let raw = resp.payload["contact"] else {
                errorBanner = "Пользователь с таким номером не найден"
                return nil
            }
            var c = parseContactValue(raw)
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

    /// Group admin permission bits for a chat: members, admins, info, pin, calls, link, delete.
    static let defaultAdminPermissions: Int64 = 2 | 4 | 8 | 16 | 64 | 128 | 1024

    /// op 77. `type`: nil (members) | "ADMIN" | "JOIN_REQUEST" | "BLOCKED_MEMBER"; `operation`: add | remove.
    func changeMembers(chatId: Int64, userIds: [Int64], operation: String, type: String? = nil, showHistory: Bool? = nil) async {
        var payload: [String: JSONValue] = [
            "chatId": .int(chatId),
            "userIds": .array(userIds.map { .int($0) }),
            "operation": .string(operation),
        ]
        if let type { payload["type"] = .string(type) }
        if let showHistory { payload["showHistory"] = .bool(showHistory) }
        if type == "ADMIN" && operation == "add" { payload["permissions"] = .int(Self.defaultAdminPermissions) }
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

    /// Invite links (op 221 list, 222 create, 223 delete).
    func inviteLinks(chatId: Int64) async -> [(id: Int64, url: String, title: String?)] {
        let resp = try? await client.sendAndWait(opcode: 221, payload: .object(["chatId": .object(["type": .int(1), "primaryId": .int(chatId)])]))
        return (resp?.payload["links"]?.arrayValue ?? []).compactMap { l in
            guard let url = l["link"]?.stringValue ?? l["url"]?.stringValue else { return nil }
            return (l["id"]?.int64Value ?? 0, url, l["title"]?.stringValue)
        }
    }

    func createInviteLink(chatId: Int64, title: String) async {
        _ = try? await client.sendAndWait(opcode: 222, payload: .object([
            "chatId": .object(["type": .int(1), "primaryId": .int(chatId)]), "title": .string(title),
        ]))
    }

    func deleteInviteLink(chatId: Int64, linkId: Int64) async {
        _ = try? await client.sendAndWait(opcode: 223, payload: .object([
            "chatId": .object(["type": .int(1), "primaryId": .int(chatId)]), "linkIds": .array([.int(linkId)]),
        ]))
    }
}
