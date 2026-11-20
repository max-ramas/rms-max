import Foundation

public struct StoryOwner: Hashable, Sendable {
    public let type: Int        // 0 user, 1 group chat, 2 channel
    public let id: Int64
    var json: JSONValue { .object(["type": .int(Int64(type)), "ownerId": .int(id)]) }
}

public struct StoryPreview: Identifiable, Hashable, Sendable {
    public var id: StoryOwner { owner }
    public let owner: StoryOwner
    public let total: Int
    public let read: Int
    public var hasUnread: Bool { read < total }
}

public struct Story: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let owner: StoryOwner
    public let time: Int64
    public let imageURL: String?
    public let isVideo: Bool
    public var viewsCount: Int
    public var reactionsCount: Int
    public var myReaction: String?
}

/// Stories: feed (208), owners' stories (210), viewed (214), reactions (213), delete own (218).
/// Publishing is not implemented: the official web client has no publish command to mirror.
public extension AppStore {
    func loadStoryFeed() async {
        guard let resp = try? await client.sendAndWait(opcode: 208, payload: .object(["cursor": .string("0"), "count": .int(30)])) else { return }
        let previews: [StoryPreview] = (resp.payload["storiesPreviews"]?.arrayValue ?? []).compactMap { p in
            guard let owner = Self.storyOwner(p["owner"]) else { return nil }
            return StoryPreview(owner: owner, total: Int(p["totalCount"]?.int64Value ?? 0), read: Int(p["readCount"]?.int64Value ?? 0))
        }.filter { $0.total > 0 }
        await ensureContacts(previews.filter { $0.owner.type == 0 }.map(\.owner.id))
        storyPreviews = previews
    }

    func stories(of owner: StoryOwner) async -> [Story] {
        // op 219 lists one owner's stories (the official profile/story viewer); 210 is the fallback.
        var raw: [JSONValue] = []
        if let resp = try? await client.sendAndWait(opcode: 219, payload: .object(["owner": owner.json, "count": .int(30)])) {
            raw = resp.payload["stories"]?.arrayValue ?? []
        }
        if raw.isEmpty, let resp = try? await client.sendAndWait(opcode: 210, payload: .object(["owners": .array([owner.json])])) {
            raw = (resp.payload["peerStories"]?.arrayValue ?? []).first?["stories"]?.arrayValue ?? []
        }
        if raw.isEmpty { ProtocolLog.add("stories: none returned for owner type=\(owner.type)") }
        return raw.compactMap { s in
            guard let id = s["id"]?.int64Value else { return nil }
            let media = s["media"]
            let type = media?["_type"]?.stringValue ?? ""
            return Story(
                id: id, owner: owner, time: s["time"]?.int64Value ?? 0,
                imageURL: media?["baseUrl"]?.stringValue ?? media?["url"]?.stringValue ?? media?["previewUrl"]?.stringValue
                    ?? media?["thumbnail"]?.stringValue,
                isVideo: type == "VIDEO",
                viewsCount: Int(s["viewsCount"]?.int64Value ?? 0),
                reactionsCount: Int(s["reactionsCount"]?.int64Value ?? 0),
                myReaction: s["reaction"]?["id"]?.stringValue
            )
        }
    }

    func markStoryViewed(_ story: Story) async {
        _ = try? await client.sendAndWait(opcode: 214, payload: .object(["owner": story.owner.json, "storyId": .int(story.id)]))
    }

    /// Emoji reaction (`reactionType 0`); nil removes it.
    @discardableResult
    func reactToStory(_ story: Story, emoji: String?) async -> Bool {
        var payload: [String: JSONValue] = ["owner": story.owner.json, "storyId": .int(story.id)]
        if let emoji { payload["reaction"] = .object(["reactionType": .int(0), "id": .string(emoji)]) }
        let resp = try? await client.sendAndWait(opcode: 213, payload: .object(payload))
        return resp?.payload["success"]?.boolValue ?? false
    }

    func deleteStories(_ ids: [Int64]) async {
        _ = try? await client.sendAndWait(opcode: 218, payload: .object(["storyIds": .array(ids.map { .int($0) })]))
        await loadStoryFeed()
    }

    func storyOwnerName(_ owner: StoryOwner) -> String {
        if owner.type == 0 { return contacts[owner.id]?.name ?? "Пользователь" }
        return chats.first(where: { $0.id == owner.id }).map { resolvedChatTitle($0) } ?? "Канал"
    }

    nonisolated static func storyOwner(_ v: JSONValue?) -> StoryOwner? {
        guard let v, let id = v["ownerId"]?.int64Value else { return nil }
        return StoryOwner(type: Int(v["type"]?.int64Value ?? 0), id: id)
    }
}
