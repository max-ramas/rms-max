// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// Links the official clients open: `https://max.ru/<path>` and `max://max.ru/<path>` (same path in both).
public enum MaxDeepLink: Equatable, Sendable {
    case joinCall(token: String)
    case joinChat(hash: String)
    case user(link: String)
    case stickerSet(link: String)
    case message(chatId: Int64, messageId: String?)
    case other(String)

    public static func parse(_ url: URL) -> MaxDeepLink? {
        var parts: [String]
        switch url.scheme?.lowercased() {
        case "max":
            // max://max.ru/joincall/T  or  max://joincall/T
            parts = url.pathComponents.filter { $0 != "/" }
            if let host = url.host, host.lowercased() != "max.ru" { parts.insert(host, at: 0) }
        case "http", "https":
            guard let host = url.host?.lowercased(), host == "max.ru" || host.hasSuffix(".max.ru") else { return nil }
            parts = url.pathComponents.filter { $0 != "/" }
        default:
            return nil
        }
        guard let kind = parts.first else { return nil }
        let rest = parts.dropFirst()
        switch kind {
        case "joincall": return rest.first.map { .joinCall(token: $0) }
        case "join": return rest.first.map { .joinChat(hash: $0) }
        case "u": return rest.first.map { .user(link: $0) }
        case "stickerset": return rest.first.map { .stickerSet(link: $0) }
        case "c":
            guard let id = rest.first.flatMap({ Int64($0) }) else { return nil }
            return .message(chatId: id, messageId: rest.dropFirst().first)
        default: return .other(url.absoluteString)
        }
    }

    /// The https form of the link, which the link-resolving op understands.
    public var webURL: String {
        switch self {
        case .joinCall(let t): return "https://max.ru/joincall/\(t)"
        case .joinChat(let h): return "https://max.ru/join/\(h)"
        case .user(let l): return "https://max.ru/u/\(l)"
        case .stickerSet(let l): return "https://max.ru/stickerset/\(l)"
        case .message(let c, let m): return "https://max.ru/c/\(c)" + (m.map { "/\($0)" } ?? "")
        case .other(let s): return s
        }
    }
}
