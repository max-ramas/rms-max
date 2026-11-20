import Foundation

extension AppStore {
    func applyUserSettings(_ config: JSONValue?) {
        guard let obj = config?["user"]?.objectValue else { return }
        for (k, v) in obj { userSettings[k] = v }
    }

    /// Choice settings (ALL / CONTACTS / NOBODY).
    public func privacyChoice(_ key: String, default def: String = "ALL") -> String { userSettings[key]?.stringValue ?? def }
    public func privacyFlag(_ key: String) -> Bool { userSettings[key]?.boolValue ?? false }

    /// op 22 `{settings:{user:{KEY: value}}}`; the local value changes at once and rolls back when the server refuses.
    public func setPrivacy(_ key: String, to value: JSONValue) async {
        let old = userSettings[key]
        userSettings[key] = value
        do {
            let resp = try await client.sendAndWait(opcode: 22, payload: .object(["settings": .object(["user": .object([key: value])])]))
            applyUserSettings(resp.payload["config"])
        } catch {
            userSettings[key] = old
            errorBanner = "Не удалось изменить настройку: \(error.localizedDescription)"
        }
    }
}
