import Foundation

public struct TwoFactorStatus: Equatable, Sendable {
    public var enabled: Bool
    public var hint: String?
    public var email: String?
}

/// Login password (two-factor protection) of the account, with the official client's flow: a track is created (op 112),
/// the password / hint / email are validated on it (107 / 108 / 109 + 110) and everything is committed with op 111
/// (`expectedCapabilities`: 0 set password, 1 update, 3 hint, 4 email, 5 remove). Shapes follow the official web client.
/// Nothing here runs by itself: every call is the result of the owner pressing a button and typing the password.
@MainActor
public final class TwoFactorFlow: ObservableObject {
    private let store: AppStore
    private var trackId: String?

    public init(store: AppStore) { self.store = store }

    private func send(_ op: UInt16, _ payload: [String: JSONValue]) async throws -> MaxResponse {
        try await store.client.sendAndWait(opcode: op, payload: .object(payload))
    }

    private func track() async throws -> String {
        if let t = trackId { return t }
        let r = try await send(112, ["type": .int(0)])
        guard let t = r.payload["trackId"]?.stringValue, !t.isEmpty else { throw TwoFactorError.noTrack }
        trackId = t
        return t
    }

    /// Op 104 `{trackId}` → `{password: {enabled, hint, email}}`.
    public func status() async throws -> TwoFactorStatus {
        let r = try await send(104, ["trackId": .string(try await track())])
        let p = r.payload["password"]
        return TwoFactorStatus(enabled: p?["enabled"]?.boolValue ?? false, hint: p?["hint"]?.stringValue, email: p?["email"]?.stringValue)
    }

    /// Op 113: the current password, required before changing or removing it.
    public func checkCurrent(_ password: String) async throws {
        _ = try await send(113, ["password": .string(password), "trackId": .string(try await track())])
    }

    /// Ops 107 / 108: the server checks length and rules before anything is saved.
    public func validate(password: String, hint: String) async throws {
        let t = try await track()
        _ = try await send(107, ["trackId": .string(t), "password": .string(password)])
        if !hint.isEmpty { _ = try await send(108, ["trackId": .string(t), "hint": .string(hint)]) }
    }

    /// Op 109 sends a code to the address; returns how many digits it has.
    public func sendEmailCode(_ email: String) async throws -> Int {
        let r = try await send(109, ["trackId": .string(try await track()), "email": .string(email)])
        return Int(r.payload["codeLength"]?.int64Value ?? 0)
    }

    public func confirmEmail(code: String) async throws {
        _ = try await send(110, ["trackId": .string(try await track()), "verifyCode": .string(code)])
    }

    public func enable(password: String, hint: String, withEmail: Bool) async throws {
        var caps: [JSONValue] = [.int(0)]
        if !hint.isEmpty { caps.append(.int(3)) }
        if withEmail { caps.append(.int(4)) }
        var p: [String: JSONValue] = ["expectedCapabilities": .array(caps), "trackId": .string(try await track()), "password": .string(password)]
        if !hint.isEmpty { p["hint"] = .string(hint) }
        _ = try await send(111, p)
    }

    public func change(password: String, hint: String) async throws {
        var caps: [JSONValue] = [.int(1)]
        if !hint.isEmpty { caps.append(.int(3)) }
        var p: [String: JSONValue] = ["expectedCapabilities": .array(caps), "trackId": .string(try await track()), "password": .string(password)]
        if !hint.isEmpty { p["hint"] = .string(hint) }
        _ = try await send(111, p)
    }

    public func remove() async throws {
        _ = try await send(111, ["expectedCapabilities": .array([.int(5)]), "trackId": .string(try await track()), "remove2fa": .bool(true)])
    }
}

public enum TwoFactorError: LocalizedError {
    case noTrack
    public var errorDescription: String? { "Сервер не начал операцию. Попробуйте ещё раз." }
}
