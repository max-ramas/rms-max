import Foundation

/// One entry of the server-side call history (official schema: historyId, callId, callerId,
/// chatId, callType, hangupType, joinLink, time, durationMs, groupCallType).
public struct CallHistoryItem: Identifiable, Equatable, Sendable {
    public let id: Int64            // historyId
    public let callId: String
    public let callName: String?
    public let callerId: Int64
    public let chatId: Int64
    public let isVideo: Bool
    public let hangupType: String   // CANCELED | REJECTED | HUNGUP | MISSED
    public let joinLink: String?
    public let time: Int64
    public let durationMs: Int64
    public let isGroup: Bool

    public init?(_ v: JSONValue) {
        guard let id = v["historyId"]?.int64Value ?? v["id"]?.int64Value,
              let chatId = v["chatId"]?.int64Value ?? v["peerId"]?.int64Value ?? v["callerId"]?.int64Value else { return nil }
        self.id = id
        callId = v["callId"]?.stringValue ?? ""
        callName = v["callName"]?.stringValue
        callerId = v["callerId"]?.int64Value ?? 0
        self.chatId = chatId
        isVideo = v["callType"]?.stringValue == "VIDEO" || v["isVideo"]?.boolValue == true
        hangupType = v["hangupType"]?.stringValue ?? "HUNGUP"
        joinLink = v["joinLink"]?.stringValue
        time = v["time"]?.int64Value ?? 0
        durationMs = v["durationMs"]?.int64Value ?? v["duration"]?.int64Value ?? 0
        isGroup = v["groupCallType"] != nil
    }

    public var isMissed: Bool { hangupType == "MISSED" }
}

public extension AppStore {
    /// Mobile protocol (as rumax): op 79 `{forward: false, count}` -> `{history: [...]}`.
    /// (163 `callHistorySync` is the web client's command.) Field names of unknown shapes go to the diagnostics log.
    func loadCallHistory() async {
        do {
            // Desktop identity: 163 Calls.History.Get {callHistorySync} (official desktop); Android: 79 (rumax).
            let resp = isDesktopSession
                ? try await client.sendAndWait(opcode: 163, payload: .object(["callHistorySync": .int(0)]))
                : try await client.sendAndWait(opcode: 79, payload: .object(["forward": .bool(false), "count": .int(100)]))
            if isDesktopSession { callHistorySync = resp.payload["callHistorySync"]?.int64Value ?? callHistorySync }
            let list = resp.payload["history"]?.arrayValue ?? resp.payload["callHistoryItems"]?.arrayValue
                ?? resp.payload["calls"]?.arrayValue ?? resp.payload["items"]?.arrayValue ?? []
            let parsed = list.compactMap(CallHistoryItem.init)
            if parsed.count < list.count, let first = list.first?.objectValue {
                ProtocolLog.add("call history: \(list.count - parsed.count) items not parsed; keys=\(first.keys.sorted().joined(separator: ","))")
            }
            if list.isEmpty, let keys = resp.payload.objectValue?.keys {
                ProtocolLog.add("call history empty; payload keys=\(keys.sorted().joined(separator: ","))")
            }
            callHistory = parsed.sorted { $0.time > $1.time }
        } catch {
            errorBanner = "История звонков: \(error.localizedDescription)"
        }
    }

    /// Max opcode 164.
    func deleteCallHistory(_ ids: [Int64]) async {
        let backup = callHistory
        callHistory.removeAll { ids.contains($0.id) }
        do {
            _ = try await client.sendAndWait(opcode: 164, payload: .object(["historyIds": .array(ids.map { .int($0) })]))
        } catch {
            callHistory = backup
            errorBanner = error.localizedDescription
        }
    }

    /// Push 165 `{action: ADD|REMOVE, callHistorySync, prevCallHistorySync, callHistoryItems, historyIds}`.
    func applyCallHistoryPush(_ p: JSONValue) async {
        if let prev = p["prevCallHistorySync"]?.int64Value, prev != 0, prev != callHistorySync {
            await loadCallHistory() // we missed an update — resync
            return
        }
        callHistorySync = p["callHistorySync"]?.int64Value ?? callHistorySync
        switch p["action"]?.stringValue {
        case "ADD":
            let new = (p["callHistoryItems"]?.arrayValue ?? []).compactMap(CallHistoryItem.init)
            var byId = Dictionary(uniqueKeysWithValues: callHistory.map { ($0.id, $0) })
            for item in new { byId[item.id] = item }
            callHistory = byId.values.sorted { $0.time > $1.time }
        case "REMOVE":
            let ids = Set((p["historyIds"]?.arrayValue ?? []).compactMap(\.int64Value))
            callHistory.removeAll { ids.contains($0.id) }
        default:
            break
        }
    }

    /// Call back from history: 1:1 → new call to that person; group → join its link if still live.
    func callBack(_ item: CallHistoryItem, video: Bool) async {
        if item.isGroup, let link = item.joinLink {
            await joinConferenceByLink(link, isVideo: video, secure: false)
            return
        }
        let me = currentAccount?.userId
        let peer = item.callerId == me ? chats.first(where: { $0.id == item.chatId }).flatMap { dialogPeerId(for: $0) } : item.callerId
        await startCall(chatId: item.chatId, peerId: peer, isVideo: video, secure: false)
    }
}
