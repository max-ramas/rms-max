import Foundation

extension AppStore {
    /// New poll as an attachment: `{_type: POLL, title, settings (bit 1 anonymous, 2 multiple, 4 revote), answers:[{text}]}`.
    public func sendPoll(chatId: Int64, title: String, options: [String], anonymous: Bool, multiple: Bool, revote: Bool) async -> Bool {
        let answers = options.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let q = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, (2...10).contains(answers.count) else { return false }
        let settings = (anonymous ? 1 : 0) | (multiple ? 2 : 0) | (revote ? 4 : 0)
        let attach: JSONValue = .object([
            "_type": .string("POLL"), "title": .string(q), "settings": .int(Int64(settings)),
            "answers": .array(answers.map { .object(["text": .string($0)]) }),
        ])
        do {
            let resp = try await client.sendMessage(chatId: chatId, text: "", attaches: [attach])
            if let msg = resp.payload["message"] { upsertMessage(parseMessage(msg, chatId: chatId), inChat: chatId, isIncomingPush: false) }
            return true
        } catch {
            errorBanner = "Опрос не создан: \(error.localizedDescription)"
            return false
        }
    }
}
