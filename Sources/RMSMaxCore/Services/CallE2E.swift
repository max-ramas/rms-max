// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import CryptoKit

/// End-to-end encrypted calls between two RMS MAKS clients.
///
/// * Key: HKDF-SHA256 over the chat's E2E session secret (the one our encrypted messages already
///   use), salted with the conversation id → a fresh 256-bit media key per call.
/// * Negotiation: each side announces `{"rms":{"e2e":1,"kc":"<key check>"}}` through the platform's
///   `custom-data` relay. Encryption turns on only when the peer announced the same key check —
///   an official client never answers, so calls with it stay plain and keep working.
/// * DIRECT topology only (the SFU mixes audio, which needs plaintext).
public extension AppStore {
    nonisolated static func callMediaKey(sessionSecret: Data, conversationId: String) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: sessionSecret),
            salt: Data("rms-max-call:\(conversationId)".utf8),
            info: Data("frame-key-v1".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Short public check value both sides compare (does not reveal the key).
    nonisolated static func callKeyCheck(_ key: Data) -> String {
        Data(SHA256.hash(data: key + Data("rms-max-call-check".utf8))).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The media key for this call, if the dialog has an active RMS E2E session.
    internal func callE2EKey(_ session: CallSession) -> Data? {
        guard !session.isGroup, let chatId = activeCall.chatId,
              let secretHex = chatSettingsByChat[chatId]?.session?.sharedSecretHex,
              let secret = Data(hexString: secretHex), secret.count == 32
        else { return nil }
        return Self.callMediaKey(sessionSecret: secret, conversationId: session.conversationId)
    }

    internal func announceE2E(_ session: CallSession) {
        guard session.topology == "DIRECT", let key = callE2EKey(session), let remote = session.remote else { return }
        var params = remote.commandFields
        params["data"] = .object(["rms": .object(["e2e": .int(1), "kc": .string(Self.callKeyCheck(key))])])
        activeCall.secureStatus = .pending
        Task { _ = try? await session.signaling.send("custom-data", params, needResponse: false) }
    }

    /// `custom-data` from the peer. Returns true when it was ours.
    internal func handleE2ECustomData(_ msg: JSONValue, session: CallSession) -> Bool {
        guard let rms = msg["data"]?["rms"] else { return false }
        guard rms["e2e"]?.int64Value == 1, let theirs = rms["kc"]?.stringValue,
              session.topology == "DIRECT", let key = callE2EKey(session), let engine = session.direct
        else { return true }
        if theirs == Self.callKeyCheck(key) {
            if !engine.isEncrypted {
                engine.enableE2E(key: key, salt: Data(session.conversationId.utf8))
                announceE2E(session) // make sure the peer heard us too
            }
            activeCall.secureStatus = .active
            activeCall.fingerprint = EmojiFingerprint.generate(sharedSecret: key)
        } else {
            activeCall.secureStatus = .unsupported
            activeCall.statusMessage = "Ключи E2E не совпали — звонок без сквозного шифрования"
        }
        return true
    }

    /// Leaving DIRECT (fallback to the SFU) drops E2E: say so instead of silently degrading.
    internal func dropE2EForServerTopology(_ session: CallSession) {
        guard activeCall.secureStatus == .active || activeCall.secureStatus == .pending else { return }
        activeCall.secureStatus = .plain
        activeCall.fingerprint = nil
        activeCall.statusMessage = "Через сервер звонков сквозное шифрование недоступно"
    }
}
