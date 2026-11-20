// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// In-call features of the official calls platform: chat, raised hand, roles and admin tools
/// (mute, remove, promote from the waiting hall, lower hands), recording and call options.
/// Commands and notifications as in the official SDK; ids marked "raw" are composite ("u123").
public extension AppStore {
    // MARK: - Chat

    func sendCallChat(_ text: String) async {
        guard let session = callSession else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        activeCall.chat.append(CallChatMessage(senderName: "Вы", text: body, mine: true))
        do {
            try await session.signaling.send("chat-message", ["message": .string(body)])
        } catch {
            errorBanner = "Сообщение не отправлено: \(error.localizedDescription)"
        }
    }

    func loadCallChatHistory() async {
        guard let session = callSession,
              let resp = try? await session.signaling.send("chat-history", ["count": .int(50)]) else { return }
        let history = (resp["messages"]?.arrayValue ?? []).reversed().compactMap { m -> CallChatMessage? in
            guard let text = m["message"]?.stringValue else { return nil }
            let from = CallParticipantRef(message: m)
            let mine = from != nil && from == session.me
            return CallChatMessage(senderName: mine ? "Вы" : participantName(from), text: text, mine: mine, direct: m["direct"]?.boolValue ?? false)
        }
        if !history.isEmpty { activeCall.chat = Array(history) }
    }

    func markCallChatRead() { activeCall.unreadChat = 0 }

    // MARK: - Hand

    func toggleHand() async {
        guard let session = callSession else { return }
        let raise = !activeCall.handRaised
        activeCall.handRaised = raise
        let params: [String: JSONValue] = ["participantState": .object(["state": .object(["hand": .string(raise ? "1" : "0")])])]
        if (try? await session.signaling.send("change-participant-state", params)) == nil {
            activeCall.handRaised = !raise
        }
    }

    // MARK: - Admin tools

    func adminMute(_ participantId: Int64, media: String = "AUDIO") async {
        guard let session = callSession, let ref = session.participants[participantId] else { return }
        _ = try? await session.signaling.send("mute-participant", [
            "participantId": .string(Self.composite(ref)),
            "muteStates": .object([media: .string("MUTE")]),
            "requestedMedia": .array([]),
        ])
    }

    func adminMuteAll() async {
        guard let session = callSession else { return }
        _ = try? await session.signaling.send("mute-participant", [
            "muteStates": .object(["AUDIO": .string("MUTE")]),
            "requestedMedia": .array([]),
        ])
    }

    func adminRemove(_ participantId: Int64, ban: Bool = false) async {
        guard let session = callSession, let ref = session.participants[participantId] else { return }
        var params = ref.commandFields
        params["ban"] = .bool(ban)
        _ = try? await session.signaling.send("remove-participant", params)
    }

    func adminSetAdmin(_ participantId: Int64, _ makeAdmin: Bool) async {
        guard let session = callSession, let ref = session.participants[participantId] else { return }
        var params: [String: JSONValue] = ["participantId": .string(Self.composite(ref)), "roles": .array([.string("ADMIN")])]
        if !makeAdmin { params["revoke"] = .bool(true) }
        _ = try? await session.signaling.send("grant-roles", params)
    }

    func adminLowerAllHands() async {
        _ = try? await callSession?.signaling.send("put-hands-down")
    }

    func setWaitingHall(_ on: Bool) async {
        guard let session = callSession else { return }
        _ = try? await session.signaling.send("change-options", ["options": .object(["WAITING_HALL": .bool(on)])])
    }

    func loadWaitingHall() async {
        guard let session = callSession,
              let resp = try? await session.signaling.send("get-waiting-hall", ["count": .int(100)]) else { return }
        activeCall.waitingHall = (resp["participants"]?.arrayValue ?? []).compactMap { p in
            guard let ref = CallParticipantRef(participant: p) ?? Self.parseComposite(p["id"]?.stringValue) else { return nil }
            let maxId = p["externalId"]?["id"]?.int64Value
            return CallParticipantInfo(id: ref.id, maxUserId: maxId, name: maxId.flatMap { contacts[$0]?.name } ?? "Гость")
        }
    }

    /// Admit from the waiting hall (nil = everyone).
    func admitFromWaitingHall(_ participantId: Int64?) async {
        guard let session = callSession else { return }
        var params: [String: JSONValue] = [:]
        if let participantId { params["participantId"] = .string("u\(participantId)") }
        _ = try? await session.signaling.send("promote-participant", params)
        if let participantId { activeCall.waitingHall.removeAll { $0.id == participantId } } else { activeCall.waitingHall = [] }
    }

    // MARK: - Recording (stored by the platform, like the official "record call")

    func toggleRecording() async {
        guard let session = callSession else { return }
        if activeCall.recording {
            _ = try? await session.signaling.send("record-stop", ["roomId": .null])
        } else {
            let name = "Запись звонка " + Date().formatted(date: .abbreviated, time: .shortened)
            _ = try? await session.signaling.send("record-start", [
                "movieId": .null, "name": .string(name), "privacy": .string("DIRECT_LINK"),
                "groupId": .null, "roomId": .null, "streamMovie": .bool(false),
            ])
        }
    }

    // MARK: - Notifications

    internal func handleFeatureNotification(_ name: String, _ msg: JSONValue, session: CallSession) {
        switch name {
        case "chat-message":
            guard let text = msg["message"]?.stringValue else { return }
            let from = CallParticipantRef(message: msg)
            if from != nil, from == session.me { return } // our own echo
            activeCall.chat.append(CallChatMessage(senderName: participantName(from), text: text, mine: false, direct: msg["direct"]?.boolValue ?? false))
            activeCall.unreadChat += 1

        case "participant-state-changed":
            applyHand(Self.handState(msg["participantState"]), to: CallParticipantRef(message: msg), session: session)

        case "participants-state-changed":
            for p in msg["participants"]?.arrayValue ?? [] {
                applyHand(Self.handState(p["participantState"]), to: Self.parseComposite(p["id"]?.stringValue), session: session)
            }

        case "roles-changed":
            let roles = (msg["roles"]?.arrayValue ?? []).compactMap(\.stringValue)
            let ref = Self.parseComposite(msg["participantId"]?.stringValue) ?? CallParticipantRef(message: msg)
            if let ref, ref == session.me {
                activeCall.myRoles = roles
            } else if let ref, let i = activeCall.participants.firstIndex(where: { $0.id == ref.id }) {
                activeCall.participants[i].roles = roles
            }

        case "mute-participant":
            // An admin muted everyone or us: obey locally, as the official client does.
            let target = Self.parseComposite(msg["participantId"]?.stringValue)
            guard target == nil || target == session.me else { return }
            let states = msg["muteStates"]?.objectValue ?? [:]
            if let audio = states["AUDIO"]?.stringValue, audio != "UNMUTE", !activeCall.isMuted {
                activeCall.mutedByAdmin = audio == "MUTE_PERMANENT"
                toggleCallMute()
                activeCall.statusMessage = "Администратор выключил вам микрофон"
            } else if states["AUDIO"]?.stringValue == "UNMUTE" {
                activeCall.mutedByAdmin = false
            }
            if let video = states["VIDEO"]?.stringValue, video != "UNMUTE", activeCall.cameraEnabled {
                Task { await toggleCallCamera() }
            }

        case "record-started":
            activeCall.recording = true
        case "record-stopped":
            activeCall.recording = false

        case "options-changed":
            activeCall.options = (msg["options"]?.arrayValue ?? []).compactMap(\.stringValue)

        default:
            break
        }
    }

    /// Roles, options, hands and recording from a `connection` snapshot.
    internal func applyFeatureSnapshot(_ msg: JSONValue, session: CallSession) {
        let conversation = msg["conversation"]
        if let opts = conversation?["options"]?.arrayValue { activeCall.options = opts.compactMap(\.stringValue) }
        if conversation?["recordInfo"] != nil { activeCall.recording = true }
        for p in conversation?["participants"]?.arrayValue ?? [] {
            guard let ref = CallParticipantRef(participant: p) else { continue }
            let roles = (p["roles"]?.arrayValue ?? []).compactMap(\.stringValue)
            if ref == session.me {
                activeCall.myRoles = roles
                activeCall.handRaised = Self.handState(p["participantState"]) ?? false
            } else if let i = activeCall.participants.firstIndex(where: { $0.id == ref.id }) {
                activeCall.participants[i].roles = roles
                activeCall.participants[i].handRaised = Self.handState(p["participantState"]) ?? false
            }
        }
    }

    private func applyHand(_ raised: Bool?, to ref: CallParticipantRef?, session: CallSession) {
        guard let raised, let ref else { return }
        if ref == session.me {
            activeCall.handRaised = raised
        } else if let i = activeCall.participants.firstIndex(where: { $0.id == ref.id }) {
            activeCall.participants[i].handRaised = raised
        }
    }

    private func participantName(_ ref: CallParticipantRef?) -> String {
        guard let ref else { return "Участник" }
        return activeCall.participants.first(where: { $0.id == ref.id })?.name ?? "Участник"
    }

    nonisolated static func handState(_ participantState: JSONValue?) -> Bool? {
        guard let v = participantState?["state"]?["hand"]?.stringValue else { return nil }
        return v == "1"
    }

    nonisolated static func composite(_ ref: CallParticipantRef) -> String {
        (ref.type == "GROUP" ? "g" : "u") + String(ref.id) + (ref.deviceIdx != 0 ? ":d\(ref.deviceIdx)" : "")
    }

    nonisolated static func parseComposite(_ text: String?) -> CallParticipantRef? {
        guard let text else { return nil }
        return SFUStreamDescription(text)?.participant
    }
}
