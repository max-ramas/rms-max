// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import Security

public actor SecureStore {
    public static let shared = SecureStore()

    private let baseDirectory: URL
    private let keychainService = "dev.rms.maks.masterkey"
    private let keychainAccount = "storage-key-v1"
    private var cachedMasterKey: Data?

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.baseDirectory = appSupport.appendingPathComponent("RMSMaks", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.baseDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Master Encryption Key (Keychain primary + sealed fallback for CLI test binaries)

    private func masterKey() -> Data {
        if let cachedMasterKey { return cachedMasterKey }

        if let kcKey = readKeychainKey(), kcKey.count == 32 {
            cachedMasterKey = kcKey
            return kcKey
        }

        let newKey = SymmetricCrypto.randomBytes(32)
        if saveKeychainKey(newKey) {
            cachedMasterKey = newKey
            return newKey
        }

        let fallbackURL = baseDirectory.appendingPathComponent(".local_master.key")
        if let existing = try? Data(contentsOf: fallbackURL), existing.count == 32 {
            cachedMasterKey = existing
            return existing
        }
        try? newKey.write(to: fallbackURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fallbackURL.path)
        cachedMasterKey = newKey
        return newKey
    }

    private func readKeychainKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    private func saveKeychainKey(_ key: Data) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    private func saveEncryptedJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let plain = try JSONEncoder().encode(value)
        let key = masterKey()
        let nonce = SymmetricCrypto.randomBytes(12)
        let ct = try SymmetricCrypto.encrypt(key: key, nonce: nonce, plaintext: plain)
        let envelope = Data("RMSX1".utf8) + nonce + ct
        try envelope.write(to: url, options: [.atomic])
    }

    private func loadEncryptedJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let raw = try? Data(contentsOf: url) else { return nil }
        let magic = Data("RMSX1".utf8)
        if raw.starts(with: magic), raw.count >= magic.count + 12 + 16 {
            let body = raw.dropFirst(magic.count)
            let nonce = Data(body.prefix(12))
            let ct = Data(body.dropFirst(12))
            if let plain = try? SymmetricCrypto.decrypt(key: masterKey(), nonce: nonce, ciphertextAndTag: ct),
               let decoded = try? JSONDecoder().decode(T.self, from: plain) {
                return decoded
            }
        }
        return try? JSONDecoder().decode(T.self, from: raw)
    }

    // MARK: - Accounts

    private struct AccountsState: Codable {
        var currentAccountId: UInt64?
        var accounts: [MaxAccount]
    }

    private var accountsFileURL: URL {
        baseDirectory.appendingPathComponent("accounts.enc")
    }

    public func loadAccounts() -> ([MaxAccount], UInt64?) {
        guard let state = loadEncryptedJSON(AccountsState.self, from: accountsFileURL) else {
            return ([], nil)
        }
        return (state.accounts, state.currentAccountId)
    }

    public func saveAccounts(_ accounts: [MaxAccount], currentAccountId: UInt64?) throws {
        try saveEncryptedJSON(AccountsState(currentAccountId: currentAccountId, accounts: accounts), to: accountsFileURL)
    }

    // MARK: - Sync State

    private func accountDir(_ accountId: UInt64) -> URL {
        baseDirectory.appendingPathComponent("account_\(accountId)", isDirectory: true)
    }

    public func loadSyncState(accountId: UInt64) -> SyncState {
        let url = accountDir(accountId).appendingPathComponent("sync_state.enc")
        return loadEncryptedJSON(SyncState.self, from: url) ?? SyncState()
    }

    public func saveSyncState(_ syncState: SyncState, accountId: UInt64) throws {
        let url = accountDir(accountId).appendingPathComponent("sync_state.enc")
        try saveEncryptedJSON(syncState, to: url)
    }

    // MARK: - Per-Chat E2E Settings

    public func loadChatSettings(accountId: UInt64, chatId: Int64) -> ChatE2ESettings {
        let url = accountDir(accountId).appendingPathComponent("chats/\(chatId)_e2e.enc")
        return loadEncryptedJSON(ChatE2ESettings.self, from: url) ?? ChatE2ESettings()
    }

    public func saveChatSettings(_ settings: ChatE2ESettings, accountId: UInt64, chatId: Int64) throws {
        var merged = settings
        let existing = loadChatSettings(accountId: accountId, chatId: chatId)
        if merged.groupIdentity == nil, let gi = existing.groupIdentity {
            merged.groupIdentity = gi
        }
        if merged.groupMembers.isEmpty, !existing.groupMembers.isEmpty {
            merged.groupMembers = existing.groupMembers
        }
        if merged.archivedKeys.isEmpty, !existing.archivedKeys.isEmpty {
            merged.archivedKeys = existing.archivedKeys
        }
        let url = accountDir(accountId).appendingPathComponent("chats/\(chatId)_e2e.enc")
        try saveEncryptedJSON(merged, to: url)
    }

    public func wipeAllData() {
        try? FileManager.default.removeItem(at: baseDirectory)
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Tracker Blocklist Rules (zero telemetry leakage)

public enum TrackerBlocker {
    public static let defaultBlockedDomains: [String] = [
        "sdk-api.apptracer.ru",
        "apptracer.ru",
        "mytracker.com",
        "tracker-api.my.com",
        "top-fwz1.mail.ru",
        "trk.mail.ru",
        "ad.mail.ru",
        "mc.yandex.ru",
        "an.yandex.ru",
        "stat.oneme.ru",
    ]

    public static func webKitRuleListJSON(extraBlockedDomains: [String] = []) -> String {
        let domains = Array(Set(defaultBlockedDomains + extraBlockedDomains)).sorted()
        let rules: [[String: Any]] = domains.map { domain in
            [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": ["*\(domain)", domain],
                ],
                "action": ["type": "block"],
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.prettyPrinted]),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    public static func isBlocked(url: URL, customDomains: [String] = []) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        for blocked in defaultBlockedDomains + customDomains {
            let d = blocked.lowercased()
            if host == d || host.hasSuffix(".\(d)") {
                return true
            }
        }
        return false
    }
}
