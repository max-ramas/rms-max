import Foundation

/// Online status as the official client gets it: `{status: 1 = online, seen: unix seconds}`.
public struct ContactPresence: Equatable, Sendable {
    public var isOnline: Bool
    public var seen: Date?

    public init(isOnline: Bool, seen: Date?) {
        self.isOnline = isOnline
        self.seen = seen
    }

    init?(_ v: JSONValue?) {
        guard let v, v.objectValue != nil else { return nil }
        let status = v["status"]?.int64Value ?? 0
        let seen = v["seen"]?.int64Value
        self.init(isOnline: status == 1, seen: seen.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0 > 10_000_000_000 ? $0 / 1000 : $0)) : nil })
    }

    /// «в сети», «был(а) 5 мин назад», «был(а) 12.11.2026».
    public var label: String {
        if isOnline { return "в сети" }
        guard let seen else { return "был(а) давно" }
        let ago = Date().timeIntervalSince(seen)
        if ago < 60 { return "был(а) только что" }
        if ago < 3600 { return "был(а) \(Int(ago / 60)) мин назад" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = Calendar.current.isDateInToday(seen) ? "'был(а) в' HH:mm" : "'был(а)' dd.MM.yyyy"
        return f.string(from: seen)
    }
}

public extension AppStore {
    /// `presence` map of a login / op 35 response keyed by user id.
    func applyPresenceMap(_ v: JSONValue?) {
        guard let obj = v?.objectValue else { return }
        for (k, val) in obj {
            if let id = Int64(k), let p = ContactPresence(val) { presence[id] = p }
        }
    }

    /// Push 132: `{userId, presence:{status, seen}}`.
    func applyPresencePush(_ payload: JSONValue) {
        guard let id = payload["userId"]?.int64Value,
              let p = ContactPresence(payload["presence"] ?? payload) else { return }
        presence[id] = p
    }

    /// Mobile protocol has no presence query (op 35 is web-only): presence comes with login and push 132,
    /// and with contacts (op 32 `presence`). Refreshes the contacts to pick it up.
    func loadPresence(_ ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        if isDesktopSession {
            // Desktop identity: 35 Contact.Presence {contactIds} -> {presence:{id:{status,seen}}}.
            if let resp = try? await client.sendAndWait(opcode: 35, payload: .object(["contactIds": .array(ids.prefix(200).map { .int($0) })])) {
                applyPresenceMap(resp.payload["presence"])
                return
            }
        }
        if let resp = try? await client.getContacts(Array(ids.prefix(100))) {
            applyPresenceMap(resp.payload["presence"])
            for raw in resp.payload["contacts"]?.arrayValue ?? [] {
                if let id = raw["id"]?.int64Value, let p = ContactPresence(raw["presence"]) { presence[id] = p }
            }
        }
    }

    /// op 46 `{phone}`: the MAX user with this number, without adding them to contacts.
    func findUser(phone: String) async -> MaxContact? {
        let digits = phone.filter(\.isNumber)
        guard digits.count >= 10 else {
            errorBanner = "Введите номер полностью, например +79001234567"
            return nil
        }
        do {
            let resp = try await client.sendAndWait(opcode: 46, payload: .object(["phone": .string(digits)]))
            guard let raw = resp.payload["contact"] else { return nil }
            let c = parseContactValue(raw)
            var merged = c
            merged.isInContacts = contacts[c.id]?.isInContacts
            contacts[c.id] = merged
            return merged
        } catch {
            ProtocolLog.add("find by phone failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Opens (or creates locally) the 1:1 dialog with a user. Dialog id = myId XOR userId, as in the official client.
    func openDialog(with userId: Int64) {
        guard let me = currentAccount?.userId else { return }
        let dialogId = me ^ userId
        if !chats.contains(where: { $0.id == dialogId }) {
            let chat = MaxChat(id: dialogId, type: .dialog, title: contacts[userId]?.name ?? "", avatarURL: nil,
                               lastEventTime: Int64(Date().timeIntervalSince1970 * 1000), newMessages: 0,
                               dontDisturbUntil: 0, participants: [me: 0, userId: 0], lastMessage: nil, pinnedMessageId: nil)
            chats.insert(chat, at: 0)
        }
        selectedChatId = dialogId
    }

    /// Avatar for a chat row: the peer's photo for dialogs, the chat icon otherwise.
    func avatarURL(for chat: MaxChat) -> String? {
        if chat.type == .dialog, let pid = dialogPeerId(for: chat) { return contacts[pid]?.avatarURL ?? chat.avatarURL }
        return chat.avatarURL
    }
}
