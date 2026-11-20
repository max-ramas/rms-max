// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public extension AppStore {
    /// op 29 `{type: FAVORITE_STICKER_SET, id}` adds a pack to «my stickers».
    func addStickerSet(id: Int64) async -> Bool {
        do {
            let r = try await client.sendAndWait(opcode: 29, payload: .object(["type": .string("FAVORITE_STICKER_SET"), "id": .int(id)]))
            guard r.payload["success"]?.boolValue ?? true else { return false }
            await loadStickerPacks()
            return true
        } catch { errorBanner = "Не удалось добавить набор: \(error.localizedDescription)"; return false }
    }

    /// op 259 `{type: FAVORITE_STICKER_SET, ids:[id]}` removes it.
    func removeStickerSet(id: Int64) async {
        do {
            let r = try await client.sendAndWait(opcode: 259, payload: .object(["type": .string("FAVORITE_STICKER_SET"), "ids": .array([.int(id)])]))
            if r.payload["success"]?.boolValue ?? true { stickerPacks.removeAll { $0.id == "set-\(id)" } }
        } catch { errorBanner = "Не удалось удалить набор: \(error.localizedDescription)" }
    }

    /// Resolves a pack link (op 89) and adds the pack.
    func addStickerSet(link: String) async -> Bool {
        let l = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return false }
        do {
            let r = try await client.sendAndWait(opcode: 89, payload: .object(["link": .string(l)]))
            guard let sid = r.payload["stickerSet"]?["id"]?.int64Value else {
                errorBanner = "По ссылке нет набора стикеров"; return false
            }
            return await addStickerSet(id: sid)
        } catch { errorBanner = "Ссылка не открылась: \(error.localizedDescription)"; return false }
    }

    /// Recents are kept on this device only (we never report sticker use); the server list is cleared too (op 261).
    func clearRecentStickers() async {
        UserDefaults.standard.removeObject(forKey: "rmsmaks.stickers.recent")
        _ = try? await client.sendAndWait(opcode: 261, payload: .object(["type": .string("RECENT"), "ids": .array([])]))
        objectWillChange.send()
    }
}
