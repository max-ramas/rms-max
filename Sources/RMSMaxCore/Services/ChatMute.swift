// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public extension AppStore {
    private var mutesKey: String { "rmsmaks.mutes.\(currentAccount?.id ?? 0)" }

    private func storedMutes() -> [Int64: Int64] {
        (UserDefaults.standard.dictionary(forKey: mutesKey) as? [String: Int] ?? [:])
            .reduce(into: [:]) { if let id = Int64($1.key) { $0[id] = Int64($1.value) } }
    }

    /// Local copy of the mute state: the server config is the truth, but if a login answer ever lacks it, nothing is forgotten.
    func rememberMute(chatId: Int64, until: Int64) {
        var m = storedMutes()
        if until == 0 { m[chatId] = nil } else { m[chatId] = until }
        UserDefaults.standard.set(m.reduce(into: [String: Int]()) { $0[String($1.key)] = Int($1.value) }, forKey: mutesKey)
    }

    func applyStoredMutes() {
        for (id, until) in storedMutes() {
            guard let i = chats.firstIndex(where: { $0.id == id }), chats[i].dontDisturbUntil == 0 else { continue }
            if until == -1 || until > Int64(Date().timeIntervalSince1970 * 1000) { chats[i].dontDisturbUntil = until }
        }
    }

    /// `config.chats = {"<chatId>": {dontDisturbUntil}}` (login) or the same shape inside push 134.
    /// -1 = muted forever, 0 = on, otherwise a unix time in ms until which the chat is muted.
    func applyConfigMutes(_ config: JSONValue?) {
        guard let map = config?["chats"]?.objectValue else { return }
        for (key, val) in map {
            guard let id = Int64(key), let i = chats.firstIndex(where: { $0.id == id }) else { continue }
            if let until = val["dontDisturbUntil"]?.int64Value {
                if chats[i].dontDisturbUntil != until { chats[i].dontDisturbUntil = until }
                rememberMute(chatId: id, until: until)
            }
        }
    }
}
