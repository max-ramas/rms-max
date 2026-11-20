import Foundation

extension AppStore {
    /// Message delivered by the server at `date` (`delayedAttributes.timeToFire`); it waits in the DELAYED list until then.
    public func scheduleMessage(chatId: Int64, text: String, at date: Date, richElements: [TextElement] = []) async -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, date > Date() else { return false }
        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        guard !settings.isActive else { errorBanner = "В зашифрованном чате отложенная отправка недоступна"; return false }
        let f = formatOutgoing(t, original: text, rich: richElements, chatId: chatId)
        do {
            _ = try await client.sendMessage(chatId: chatId, text: f.text, elements: f.elements.map(\.json), fireAt: date)
            return true
        } catch {
            errorBanner = "Не удалось запланировать: \(error.localizedDescription)"
            return false
        }
    }

    public func loadScheduled(chatId: Int64) async -> [MaxMessage] {
        do {
            let resp = try await client.fetchHistory(chatId: chatId, backward: 50, getChat: false, delayed: true)
            return (resp.payload["messages"]?.arrayValue ?? []).map { parseMessage($0, chatId: chatId) }
        } catch {
            errorBanner = error.localizedDescription
            return []
        }
    }

    public func deleteScheduled(chatId: Int64, messageId: String) async {
        guard let id = Int64(messageId) else { return }
        do { _ = try await client.deleteMessages(chatId: chatId, messageIds: [id], forMe: false, delayed: true) }
        catch { errorBanner = error.localizedDescription }
    }
}
