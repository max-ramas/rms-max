import Foundation

/// Pinned chats = `favorites` of a folder (op 274); the main list uses the server's "all chats" folder.
public extension AppStore {
    /// Folder whose `favorites` are shown first in the current list.
    var currentPinFolder: ChatFolder? {
        if let id = selectedFolderId, let f = folders.first(where: { $0.id == id }) { return f }
        return serverAllFolder
    }

    func isChatPinned(_ chatId: Int64) -> Bool { currentPinFolder?.favorites.contains(chatId) ?? false }

    /// Pinned chats first (in the order they were pinned), then the rest as given.
    func withPinnedFirst(_ list: [MaxChat]) -> [MaxChat] {
        guard let fav = currentPinFolder?.favorites, !fav.isEmpty else { return list }
        let pinned = fav.compactMap { id in list.first { $0.id == id } }
        let pinnedIds = Set(pinned.map(\.id))
        return pinned + list.filter { !pinnedIds.contains($0.id) }
    }

    func togglePinChat(_ chatId: Int64) async {
        guard var f = currentPinFolder else {
            errorBanner = "Закрепление чатов недоступно: сервер не прислал список папок"
            return
        }
        if let i = f.favorites.firstIndex(of: chatId) { f.favorites.remove(at: i) } else { f.favorites.append(chatId) }
        await saveFolder(f)
    }

    func isChat(_ chatId: Int64, in folder: ChatFolder) -> Bool {
        folder.include.contains(chatId)
    }

    /// Adds or removes a chat from a folder's explicit list.
    func toggleChat(_ chatId: Int64, in folder: ChatFolder) async {
        var f = folder
        if let i = f.include.firstIndex(of: chatId) {
            f.include.remove(at: i)
            f.favorites.removeAll { $0 == chatId }
        } else {
            f.include.append(chatId)
        }
        await saveFolder(f)
    }
}
