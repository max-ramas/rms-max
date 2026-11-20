// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// Animated emoji. `Assets` ops 27/28 with `type` ANIMOJI / ANIMOJI_SET (shapes taken from the official web client):
/// `{id, updateTime, lottieUrl, lottiePlayUrl, setId, emoji, iconUrl}` and `{id, name, iconUrl, iconLottieUrl, animojiIds}`.
public struct Animoji: Identifiable, Hashable, Codable, Sendable {
    public let id: Int64
    public let emoji: String
    public let lottieUrl: String?
    public let lottiePlayUrl: String?
    public let iconUrl: String?
    public let setId: Int64?

    /// What the player gets: the "play" variant when the server names one.
    public var animationURL: String? { lottiePlayUrl ?? lottieUrl }

    static func parse(_ v: JSONValue) -> Animoji? { Animoji(v) }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.int64Value, let emoji = v["emoji"]?.stringValue else { return nil }
        self.id = id; self.emoji = emoji
        lottieUrl = v["lottieUrl"]?.stringValue; lottiePlayUrl = v["lottiePlayUrl"]?.stringValue
        iconUrl = v["iconUrl"]?.stringValue; setId = v["setId"]?.int64Value
    }
}

public struct AnimojiSet: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let name: String
    public let iconUrl: String?
    public let iconLottieUrl: String?
    public let animojiIds: [Int64]

    static func parse(_ v: JSONValue) -> AnimojiSet? { AnimojiSet(v) }

    init?(_ v: JSONValue) {
        guard let id = v["id"]?.int64Value else { return nil }
        self.id = id
        name = v["name"]?.stringValue ?? "Анимодзи"
        iconUrl = v["iconUrl"]?.stringValue; iconLottieUrl = v["iconLottieUrl"]?.stringValue
        animojiIds = (v["animojiIds"]?.arrayValue ?? []).compactMap(\.int64Value)
    }
}

public extension AppStore {
    /// Packs live in the account's assets: section `SYSTEM` of type `ANIMOJI_SETS` (`animojiSetIds`).
    /// Which `type` the server expects for the section list is not documented, so the known values are tried in turn.
    func loadAnimojiSets() async {
        var setIds: [Int64] = []
        var seen: [String] = []
        for type in ["ANIMOJI_SET", "ANIMOJI", "STICKER", "EMOJI"] where setIds.isEmpty {
            guard let r = try? await client.sendAndWait(opcode: 27, payload: .object(["type": .string(type), "sync": .int(0)])) else { seen.append("\(type):error"); continue }
            let sections = r.payload["sections"]?.arrayValue ?? []
            seen.append("\(type):\(sections.compactMap { $0["type"]?.stringValue }.joined(separator: "+"))")
            for s in sections where s["type"]?.stringValue == "ANIMOJI_SETS" {
                setIds += (s["animojiSetIds"]?.arrayValue ?? []).compactMap(\.int64Value)
            }
        }
        ProtocolLog.add("animoji sections \(seen.joined(separator: " ")) -> \(setIds.count) sets")
        if setIds.isEmpty { await probeAnimojiFallbacks() }
        guard !setIds.isEmpty,
              let r = try? await client.sendAndWait(opcode: 28, payload: .object(["type": .string("ANIMOJI_SET"), "ids": .array(setIds.map { .int($0) })])) else { return }
        let byId = Dictionary((r.payload["animojiSets"]?.arrayValue ?? []).compactMap(AnimojiSet.init).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        animojiSets = setIds.compactMap { byId[$0] }
        if let first = animojiSets.first, let sample = r.payload["animojiSets"]?.arrayValue?.first {
            ProtocolLog.add("animoji set \(first.name): \(first.animojiIds.count) items; fields=\(sample.objectValue?.keys.sorted() ?? [])")
        }
    }

    /// Fetches animoji we have not cached yet (op 28 type ANIMOJI → `animojis`).
    func ensureAnimoji(_ ids: [Int64]) async {
        let missing = ids.filter { animojiCache[$0] == nil }
        guard !missing.isEmpty else { return }
        for chunk in stride(from: 0, to: missing.count, by: 100).map({ Array(missing[$0..<min($0 + 100, missing.count)]) }) {
            guard let r = try? await client.sendAndWait(opcode: 28, payload: .object(["type": .string("ANIMOJI"), "ids": .array(chunk.map { .int($0) })])) else { continue }
            for raw in r.payload["animojis"]?.arrayValue ?? [] {
                if let a = Animoji(raw) { animojiCache[a.id] = a }
            }
        }
    }

    /// Animation for a plain emoji, when one of the loaded packs has it (reactions use this).
    func animoji(forEmoji e: String) -> Animoji? {
        animojiCache.values.first { $0.emoji == e }
    }

    /// ANIMOJI elements for the animoji picked in the composer: each one marks the next occurrence of its emoji in the text.
    nonisolated static func animojiElements(in text: String, picks: [Animoji]) -> [TextElement] {
        let ns = text as NSString
        var cursor = 0
        var out: [TextElement] = []
        for a in picks {
            let r = ns.range(of: a.emoji, options: [], range: NSRange(location: cursor, length: ns.length - cursor))
            guard r.location != NSNotFound else { continue }
            out.append(TextElement(type: "ANIMOJI", from: r.location, length: r.length, entityId: a.id,
                                   animojiLottieUrl: a.lottieUrl, animojiSetId: a.setId.map(String.init)))
            cursor = r.location + r.length
        }
        return out
    }
}

extension AppStore {
    /// The sections op answers nothing for ANIMOJI_SET. Only requests whose shape the official web client uses are repeated:
    /// the REACTION section (op 27) and a section read by id (op 26 `{sectionId}`). Answers are logged once per build (no personal data).
    func probeAnimojiFallbacks() async {
        let key = "rmsmaks.animoji.fallback.\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0")"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let tries: [(UInt16, [String: JSONValue])] = [
            (27, ["type": .string("REACTION"), "sync": .int(0)]),
            (26, ["sectionId": .string("SYSTEM"), "count": .int(50)]),
        ]
        for (op, payload) in tries {
            let label = "\(op) \(payload.keys.sorted().joined(separator: ","))"
            do {
                let r = try await client.sendAndWait(opcode: op, payload: .object(payload))
                ProtocolLog.add("animoji fallback \(label): keys=\(r.payload.objectValue?.keys.sorted() ?? []) \(String(String(describing: r.payload).prefix(500)))")
            } catch { ProtocolLog.add("animoji fallback \(label) failed: \(error.localizedDescription)") }
        }
    }
}
