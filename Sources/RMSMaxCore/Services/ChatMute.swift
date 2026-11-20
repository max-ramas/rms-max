import Foundation

public extension AppStore {
    /// `config.chats = {"<chatId>": {dontDisturbUntil}}` (login) or the same shape inside push 134.
    /// -1 = muted forever, 0 = on, otherwise a unix time in ms until which the chat is muted.
    func applyConfigMutes(_ config: JSONValue?) {
        guard let map = config?["chats"]?.objectValue else { return }
        for (key, val) in map {
            guard let id = Int64(key), let i = chats.firstIndex(where: { $0.id == id }) else { continue }
            if let until = val["dontDisturbUntil"]?.int64Value, chats[i].dontDisturbUntil != until {
                chats[i].dontDisturbUntil = until
            }
        }
    }
}
