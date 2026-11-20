import Foundation

public struct Sticker: Identifiable, Hashable, Codable, Sendable {
    public let id: Int64
    public let url: String          // static WebP (STATIC) or first frame source
    public let previewUrl: String?
    public let width: Int
    public let height: Int
    public let lottieUrl: String?
    public let kind: String         // STATIC | LIVE | LOTTIE

    /// What we can draw without a Lottie/WebM player: the static image or the first frame.
    public var displayURL: String { kind == "STATIC" ? url : (previewUrl ?? url) }
}

public struct StickerPack: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var stickerIds: [Int64]
    public var iconUrl: String?
}

public struct ComplaintReason: Identifiable, Hashable, Sendable {
    public let id: Int
    public let title: String
}

/// Complaint target types (official `typeId`).
public enum ComplaintTarget: Int, Sendable {
    case chat = 1, channel = 2, dialogMessage = 3, chatMessage = 4, channelMessage = 5, userProfile = 6, botProfile = 7, story = 9
}

/// Sticker packs (ops 26/27/28) and complaints (ops 161/162).
/// Privacy: sticker usage is never reported — "recent" lives only on this device.
public extension AppStore {
    // MARK: - Stickers

    func loadStickerPacks() async {
        do {
            let resp = try await client.sendAndWait(opcode: 27, payload: .object(["type": .string("STICKER"), "sync": .int(0)]))
            var packs: [StickerPack] = []
            var setIds: [Int64] = []
            for section in resp.payload["sections"]?.arrayValue ?? [] {
                let id = section["id"]?.stringValue ?? UUID().uuidString
                let title = section["title"]?.stringValue ?? "Стикеры"
                switch section["type"]?.stringValue {
                case "STICKERS":
                    let ids = (section["stickers"]?.arrayValue ?? []).compactMap(\.int64Value)
                    if !ids.isEmpty { packs.append(StickerPack(id: id, title: title, stickerIds: ids)) }
                case "STICKER_SETS":
                    setIds += (section["stickerSets"]?.arrayValue ?? []).compactMap(\.int64Value)
                default:
                    break
                }
            }
            if !setIds.isEmpty {
                let sets = try await client.sendAndWait(opcode: 28, payload: .object([
                    "type": .string("STICKER_SET"), "ids": .array(Array(setIds.prefix(100)).map { .int($0) }),
                ]))
                for set in sets.payload["stickerSets"]?.arrayValue ?? [] {
                    guard let sid = set["id"]?.int64Value else { continue }
                    let ids = (set["stickers"]?.arrayValue ?? []).compactMap { $0.int64Value ?? $0["id"]?.int64Value }
                    guard !ids.isEmpty else { continue }
                    packs.append(StickerPack(
                        id: "set-\(sid)",
                        title: set["name"]?.stringValue ?? set["title"]?.stringValue ?? "Набор",
                        stickerIds: ids,
                        iconUrl: set["iconUrl"]?.stringValue
                    ))
                }
            }
            stickerPacks = packs
        } catch {
            errorBanner = "Стикеры не загрузились: \(error.localizedDescription)"
        }
    }

    /// Fetches sticker metadata we have not cached yet (op 28 type STICKER).
    func ensureStickers(_ ids: [Int64]) async {
        let missing = ids.filter { stickerCache[$0] == nil }
        guard !missing.isEmpty else { return }
        for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
            guard let resp = try? await client.sendAndWait(opcode: 28, payload: .object([
                "type": .string("STICKER"), "ids": .array(chunk.map { .int($0) }),
            ])) else { continue }
            for raw in resp.payload["stickers"]?.arrayValue ?? [] {
                if let s = Self.parseSticker(raw) { stickerCache[s.id] = s }
            }
        }
    }

    func searchStickers(_ query: String) async -> [Sticker] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              let resp = try? await client.sendAndWait(opcode: 26, payload: .object([
                "type": .string("STICKER"), "query": .string(q), "count": .int(60),
              ]))
        else { return [] }
        let ids = (resp.payload["stickers"]?.arrayValue ?? []).compactMap(\.int64Value)
        await ensureStickers(ids)
        return ids.compactMap { stickerCache[$0] }
    }

    func sendSticker(_ sticker: Sticker, chatId: Int64, replyTo: String? = nil) async {
        var attach: [String: JSONValue] = [
            "_type": .string("STICKER"),
            "stickerId": .int(sticker.id),
            "width": .int(Int64(sticker.width)),
            "height": .int(Int64(sticker.height)),
            "url": .string(sticker.url),
        ]
        if let l = sticker.lottieUrl { attach["lottieUrl"] = .string(l) }
        do {
            let resp = try await client.sendMessage(chatId: chatId, text: "", replyTo: replyTo.flatMap { Int64($0) }, attaches: [.object(attach)])
            if let msg = resp.payload["message"] { upsertMessage(parseMessage(msg, chatId: chatId), inChat: chatId, isIncomingPush: false) }
            rememberRecentSticker(sticker)
        } catch {
            errorBanner = "Стикер не отправлен: \(error.localizedDescription)"
        }
    }

    /// Local-only recents (never sent to the server).
    var recentStickers: [Sticker] {
        guard let data = UserDefaults.standard.data(forKey: "rmsmaks.stickers.recent"),
              let list = try? JSONDecoder().decode([Sticker].self, from: data) else { return [] }
        return list
    }

    private func rememberRecentSticker(_ s: Sticker) {
        var list = recentStickers.filter { $0.id != s.id }
        list.insert(s, at: 0)
        if let data = try? JSONEncoder().encode(Array(list.prefix(30))) {
            UserDefaults.standard.set(data, forKey: "rmsmaks.stickers.recent")
        }
        objectWillChange.send()
    }

    nonisolated static func parseSticker(_ v: JSONValue) -> Sticker? {
        guard let id = v["id"]?.int64Value ?? v["stickerId"]?.int64Value, let url = v["url"]?.stringValue else { return nil }
        return Sticker(
            id: id,
            url: url,
            previewUrl: v["previewUrl"]?.stringValue ?? v["firstUrl"]?.stringValue,
            width: Int(v["width"]?.int64Value ?? 256),
            height: Int(v["height"]?.int64Value ?? 256),
            lottieUrl: v["lottieUrl"]?.stringValue,
            kind: v["type"]?.stringValue ?? v["stickerType"]?.stringValue ?? "STATIC"
        )
    }

    // MARK: - Complaints

    /// op 162 `{complainSync: 0}` → reasons per target type.
    func complaintReasons(for target: ComplaintTarget) async -> [ComplaintReason] {
        if complaintReasonCache.isEmpty,
           let resp = try? await client.sendAndWait(opcode: 162, payload: .object(["complainSync": .int(0)])) {
            for group in resp.payload["complains"]?.arrayValue ?? [] {
                guard let type = group["typeId"]?.int64Value else { continue }
                complaintReasonCache[Int(type)] = (group["reasons"]?.arrayValue ?? []).compactMap { r in
                    guard let id = r["reasonId"]?.int64Value, let title = r["reasonTitle"]?.stringValue else { return nil }
                    return ComplaintReason(id: Int(id), title: title)
                }
            }
        }
        return complaintReasonCache[target.rawValue] ?? []
    }

    /// op 161 `{typeId, ids, reasonId, parentId}` — `parentId` is the chat for message complaints.
    @discardableResult
    func sendComplaint(target: ComplaintTarget, ids: [Int64], reasonId: Int, parentId: Int64? = nil) async -> Bool {
        var payload: [String: JSONValue] = [
            "typeId": .int(Int64(target.rawValue)),
            "ids": .array(ids.map { .int($0) }),
            "reasonId": .int(Int64(reasonId)),
        ]
        if let parentId { payload["parentId"] = .int(parentId) }
        do {
            _ = try await client.sendAndWait(opcode: 161, payload: .object(payload))
            return true
        } catch {
            errorBanner = "Жалоба не отправлена: \(error.localizedDescription)"
            return false
        }
    }

    func complaintTarget(forMessageIn chat: MaxChat) -> ComplaintTarget {
        switch chat.type {
        case .chat: return .chatMessage
        case .channel: return .channelMessage
        default: return .dialogMessage
        }
    }
}
