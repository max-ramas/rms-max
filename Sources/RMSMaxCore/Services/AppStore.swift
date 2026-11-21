// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import Network
import LocalAuthentication
import Combine

public enum AuthStep: Sendable, Equatable {
    case phoneInput
    case codeInput(phone: String)
    case password2FA(trackId: String, hint: String?)
    /// Scan this QR in the MAX app on a logged-in phone.
    case qrLogin(link: String)
    /// Call this number from your phone to log in.
    case callOutLogin(phone: String, callNumber: String?)
    case registration
    case authenticated
}

/// Thread-safe last NWPath status for the network monitor callback.
final class PathStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status: NWPath.Status = .satisfied
    func swap(_ new: NWPath.Status) -> NWPath.Status {
        lock.lock(); defer { lock.unlock() }
        let old = status
        status = new
        return old
    }
}

@MainActor
public final class AppStore: ObservableObject {
    @Published public var accounts: [MaxAccount] = []
    @Published public var currentAccount: MaxAccount?
    @Published public var authStep: AuthStep = .phoneInput {
        didSet {
            // Ask for notification permission only once the user is signed in, not on the login screen.
            if case .authenticated = authStep, !(oldValue == .authenticated) {
                Task { await NotificationService.shared.requestAuthorization() }
            }
        }
    }
    @Published public var useMobileTransport = true
    @Published public var isConnected = false
    @Published public var isBusy = false
    @Published public var isLocked = false
    @Published public var errorBanner: String?

    @Published public var chats: [MaxChat] = []
    @Published public var contacts: [Int64: MaxContact] = [:]
    /// Account privacy settings (`config.user`): SEARCH_BY_PHONE, INCOMING_CALL, CHATS_INVITE, PHONE_NUMBER_PRIVACY, HIDDEN, CONTENT_LEVEL_ACCESS.
    @Published public var userSettings: [String: JSONValue] = [:]
    /// Set when the server rejected the chat-media request: it is not repeated until the next launch.
    var chatMediaDisabled = false
    /// Animated emoji (Lottie): packs of the SYSTEM section and every animoji fetched so far.
    @Published public internal(set) var animojiSets: [AnimojiSet] = []
    @Published public internal(set) var animojiCache: [Int64: Animoji] = [:]
    @Published public var messagesByChat: [Int64: [MaxMessage]] = [:]
    @Published public var chatSettingsByChat: [Int64: ChatE2ESettings] = [:]
    @Published public var pendingE2ERequests: [Int64: PendingE2ERequest] = [:]
    @Published public var selectedChatId: Int64?
    /// Chats whose history has been paged back to the very first message.
    @Published public var historyExhausted: Set<Int64> = []
    @Published public var loadingOlderHistory: Set<Int64> = []
    /// Message the chat view should scroll to (set when opening a search hit).
    @Published public var scrollTargetMessageId: String?
    @Published public var messageSearchHits: [MessageSearchHit] = []
    @Published public var isSearchingMessages = false

    @Published public var sessions: [MaxSessionInfo] = []
    @Published public var activeCall = ActiveCallState() {
        didSet { CallSounds.shared.update(old: oldValue, new: activeCall) }
    }
    /// A max:// or max.ru link the system handed to the app; the window shows the matching sheet and clears it.
    @Published public var incomingURL: URL?
    @Published public var customBlockedDomains: [String] = TrackerBlocker.defaultBlockedDomains
    @Published public var telemetryMode: String = "disabled"

    public let client = MaxClient()
    public let callEncryption = CallEncryptionSession()
    var callSession: CallSession?
    var reconnectTask: Task<Void, Never>?
    var reconnectAttempt = 0
    var networkMonitor: NWPathMonitor?
    @Published public internal(set) var callLocalVideo: CallVideoTrack?
    /// Remote video per participant (calls-platform id).
    @Published public internal(set) var callRemoteVideos: [Int64: CallVideoTrack] = [:]
    @Published public internal(set) var callHistory: [CallHistoryItem] = []
    @Published public internal(set) var blockedContacts: [MaxContact] = []
    @Published public internal(set) var stickerPacks: [StickerPack] = []
    @Published public internal(set) var folders: [ChatFolder] = []
    @Published public internal(set) var storyPreviews: [StoryPreview] = []
    /// Who is typing right now: chatId -> userId -> kind (TEXT | AUDIO | PHOTO | VIDEO | VIDEO_MSG | FILE | STICKER).
    @Published public internal(set) var typingByChat: [Int64: [Int64: String]] = [:]
    /// All pinned messages of a chat, newest first (op 241); the chat itself only carries the newest one.
    @Published public internal(set) var pinnedByChat: [Int64: [MaxMessage]] = [:]
    /// Views / forwards of channel posts (op 74), keyed "chatId_messageId".
    @Published public internal(set) var postStats: [String: PostStats] = [:]
    /// Per-chat drafts and messages that failed to send (device-local).
    @Published public internal(set) var drafts: [Int64: String] = [:]
    @Published public internal(set) var failedSends: [Int64: [FailedSend]] = [:]
    /// Comments of channel posts (op 49 with `postId`), keyed "chatId_postId".
    @Published public internal(set) var commentsByPost: [String: [MaxMessage]] = [:]
    /// Attachments whose media is on the device already (triggers views that wait for a prefetch).
    @Published public internal(set) var mediaReady: Set<String> = []
    var prefetchInFlight: Set<String> = []
    let prefetchGate = PrefetchGate(limit: 3)
    /// Mobile data / hotspot: auto-download is restricted to voice messages unless the user allows more.
    var networkIsMetered = false
    /// Reactions a chat allows (`op 258`): nil = not loaded yet.
    @Published public internal(set) var chatReactions: [Int64: ChatReactions] = [:]
    var typingTokens: [String: Int] = [:]
    var lastTypingSent: [Int64: Date] = [:]
    static let sendTypingKey = "rmsmaks.privacy.sendTyping"
    @Published public internal(set) var availableUpdate: AvailableUpdate?
    @Published public internal(set) var updateStatus: String?
    @Published public internal(set) var isInstallingUpdate = false
    /// Set by a menu / tray "check for updates" when a newer version is found: the main window shows the update dialog.
    @Published public var updatePromptShown = false
    /// userId -> presence (op 35, push 132, login `presence`).
    @Published public internal(set) var presence: [Int64: ContactPresence] = [:]
    /// Voice transcriptions by "chatId:messageId".
    @Published public internal(set) var transcriptions: [String: String] = [:]
    @Published public var selectedFolderId: String? = nil
    /// The server's own "all chats" folder: it holds the pinned chats of the main list (`favorites`).
    @Published public internal(set) var serverAllFolder: ChatFolder?
    @Published public internal(set) var stickerCache: [Int64: Sticker] = [:]
    var complaintReasonCache: [Int: [ComplaintReason]] = [:]
    var callHistorySync: Int64 = 0
    private let store = SecureStore.shared
    private var eventTask: Task<Void, Never>?
    private var handledGroupControlKeys: Set<String> = []
    private var syncState = SyncState()

    public init() {
        Task { await self.bootstrap() }
    }

    // MARK: - Bootstrap & Biometric Lock

    public func bootstrap() async {
        wireCallKit()
        startNetworkMonitor()
        Task { await self.autoCheckForUpdates() }
        // The system notification prompt can stay unanswered for a long time; never block startup on it,
        // otherwise a late bootstrap overwrites an auth step the user has already advanced.
        NotificationService.shared.install { [weak self] chatId in
            guard let self else { return }
            Task { await self.selectChat(chatId) }
        }
        let (loadedAccounts, currentId) = await store.loadAccounts()
        self.accounts = loadedAccounts
        if let selected = loadedAccounts.first(where: { $0.id == currentId }) ?? loadedAccounts.first {
            self.currentAccount = selected
            self.telemetryMode = selected.telemetryMode
            self.useMobileTransport = selected.useMobileTransport
            if selected.biometricLockEnabled {
                self.isLocked = true
            }
            self.authStep = .authenticated
            loadDrafts()
            await startEventListener()
            await connectAndSyncAccount(selected)
            Task { await self.prepareCalls(); await self.loadFolders(); await self.loadStoryFeed() } // calls-platform id up front, so the first incoming call works
        }
        // No saved account: keep whatever auth step the user is already on.
    }

    public func authenticateBiometrics() async {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            isLocked = false
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Разблокировать RMS MAKS"
            )
            if ok {
                isLocked = false
            }
        } catch {
            errorBanner = "Не удалось пройти проверку биометрии"
        }
    }

    // MARK: - Auth Flow

    public func requestPhoneCode(phone: String) async {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }

        do {
            let reauth = reauthAccountId.flatMap { id in accounts.first { $0.id == id } }
            // Re-login keeps a desktop identity; an old Android one is replaced by the desktop client identity.
            let identity = (reauth?.identity.isDesktop == true ? reauth?.identity : nil) ?? (useMobileTransport ? MaxIdentity.generateDesktop() : MaxIdentity.generateWeb())
            await client.disconnect()
            _ = try await client.connect(identity: identity, useMobileTransport: reauth?.useMobileTransport ?? useMobileTransport)
            isConnected = true
            let resp = try await client.startAuth(phone: trimmed)
            self.pendingIdentity = identity
            self.pendingPhone = trimmed
            self.authCodeLength = resp.payload["codeLength"]?.int64Value.map(Int.init)
            authStep = .codeInput(phone: trimmed)
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func resendPhoneCode() async {
        guard let phone = pendingPhone else { return }
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }
        do {
            let resp = try await client.startAuth(phone: phone, resend: true)
            self.authCodeLength = resp.payload["codeLength"]?.int64Value.map(Int.init) ?? authCodeLength
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    @Published public var authCodeLength: Int?
    private var pendingIdentity: MaxIdentity?
    private var pendingPhone: String?
    /// The account whose session MAX revoked (`login.token`): the next successful login updates it in place
    /// (same local id, device identity, chats cache and E2E keys) instead of adding a new account.
    @Published public internal(set) var reauthAccountId: UInt64?
    /// Prefill for the phone field after a revoked session.
    /// True when the current session presents as the official desktop client (desktop opcode set available).
    public var isDesktopSession: Bool { currentAccount?.identity.isDesktop ?? false }
    public var reauthPhone: String? { reauthAccountId.flatMap { id in accounts.first { $0.id == id }?.phone } }

    public func verifyCode(_ code: String) async {
        let clean = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }

        do {
            let resp = try await client.checkCode(clean)
            if let pwdChallenge = resp.payload["passwordChallenge"], pwdChallenge != .null {
                let trackId = pwdChallenge["trackId"]?.stringValue ?? resp.payload["trackId"]?.stringValue ?? ""
                let hint = pwdChallenge["hint"]?.stringValue
                authStep = .password2FA(trackId: trackId, hint: hint)
                return
            }
            if await client.currentToken() != nil {
                try await finishLoginWithCurrentClient()
            } else if resp.payload["tokenAttrs"]?["REGISTER"] != nil {
                authStep = .registration
            } else {
                errorBanner = "Сервер не вернул токен входа. Запросите код ещё раз."
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: QR and call-out login

    private var trackLoginTask: Task<Void, Never>?

    public func cancelTrackLogin() {
        trackLoginTask?.cancel()
        trackLoginTask = nil
        authStep = .phoneInput
    }

    public func startQRLogin() async {
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }
        do {
            let identity = pendingIdentity ?? (useMobileTransport ? MaxIdentity.generateDesktop() : MaxIdentity.generateWeb())
            if !(await client.isConnected()) {
                _ = try await client.connect(identity: identity, useMobileTransport: useMobileTransport)
            }
            pendingIdentity = identity
            isConnected = true
            let resp = try await client.createLoginQR()
            guard let trackId = resp.payload["trackId"]?.stringValue, let link = resp.payload["qrLink"]?.stringValue else {
                errorBanner = "Сервер не выдал QR-код"
                return
            }
            authStep = .qrLogin(link: link)
            let interval = max(1.0, Double(resp.payload["pollingInterval"]?.int64Value ?? 3000) / 1000)
            let ttl = Double(resp.payload["ttl"]?.int64Value ?? 120_000) / 1000
            trackLoginTask?.cancel()
            trackLoginTask = Task { [weak self] in
                let deadline = Date().addingTimeInterval(ttl)
                while !Task.isCancelled, Date() < deadline {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self, case .qrLogin = self.authStep else { return }
                    guard let poll = try? await self.client.pollLoginQR(trackId: trackId) else { continue }
                    if poll.payload["status"]?["loginAvailable"]?.boolValue == true {
                        await self.finishTrackLogin(trackId: trackId)
                        return
                    }
                }
                guard let self, case .qrLogin = self.authStep, !Task.isCancelled else { return }
                await self.startQRLogin() // expired: show a fresh code
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func startCallOutLogin(phone: String) async {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }
        do {
            let identity = pendingIdentity ?? (useMobileTransport ? MaxIdentity.generateDesktop() : MaxIdentity.generateWeb())
            if !(await client.isConnected()) {
                _ = try await client.connect(identity: identity, useMobileTransport: useMobileTransport)
            }
            pendingIdentity = identity
            pendingPhone = trimmed
            isConnected = true
            let resp = try await client.startCallOutLogin(phone: trimmed)
            guard let trackId = resp.payload["trackId"]?.stringValue else {
                errorBanner = "Вход звонком сейчас недоступен — используйте код из SMS"
                return
            }
            authStep = .callOutLogin(phone: trimmed, callNumber: resp.payload["callNumber"]?.stringValue)
            let interval = max(1.0, Double(resp.payload["pollingInterval"]?.int64Value ?? 5000) / 1000)
            trackLoginTask?.cancel()
            trackLoginTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    guard let self, case .callOutLogin = self.authStep else { return }
                    guard let poll = try? await self.client.pollCallOutLogin(trackId: trackId) else { continue }
                    switch poll.payload["status"]?.int64Value {
                    case 1:
                        if let number = poll.payload["callNumber"]?.stringValue {
                            self.authStep = .callOutLogin(phone: trimmed, callNumber: number)
                        }
                    case 2:
                        await self.finishTrackLogin(trackId: trackId)
                        return
                    case 3:
                        self.errorBanner = "Время ожидания звонка истекло. Попробуйте ещё раз."
                        self.authStep = .phoneInput
                        return
                    default:
                        break
                    }
                }
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func finishTrackLogin(trackId: String) async {
        do {
            let resp = try await client.completeTrackLogin(trackId: trackId)
            if let challenge = resp.payload["passwordChallenge"], challenge != .null {
                authStep = .password2FA(trackId: challenge["trackId"]?.stringValue ?? trackId, hint: challenge["hint"]?.stringValue)
                return
            }
            if await client.currentToken() != nil {
                try await finishLoginWithCurrentClient()
            } else if resp.payload["tokenAttrs"]?["REGISTER"] != nil {
                authStep = .registration
            } else {
                errorBanner = "Вход не подтверждён"
                authStep = .phoneInput
            }
        } catch {
            errorBanner = error.localizedDescription
            authStep = .phoneInput
        }
    }

    public func verify2FAPassword(_ password: String, trackId: String) async {
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }

        do {
            _ = try await client.checkPassword(password, trackId: trackId)
            try await finishLoginWithCurrentClient()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func completeRegistration(firstName: String, lastName: String?) async {
        isBusy = true
        errorBanner = nil
        defer { isBusy = false }

        do {
            _ = try await client.submitRegister(firstName: firstName, lastName: lastName)
            try await finishLoginWithCurrentClient()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func finishLoginWithCurrentClient() async throws {
        guard let token = await client.currentToken(), !token.isEmpty else {
            throw MaxTransportError.invalidPayload("Токен авторизации не получен")
        }
        let identity = pendingIdentity ?? (useMobileTransport ? MaxIdentity.generateDesktop() : MaxIdentity.generateWeb())
        let acc: MaxAccount
        if let rid = reauthAccountId, let i = accounts.firstIndex(where: { $0.id == rid }) {
            accounts[i].token = token
            accounts[i].identity = identity
            if let p = pendingPhone { accounts[i].phone = p }
            acc = accounts[i]
            ProtocolLog.add("re-login: session of the existing account restored")
        } else {
            acc = MaxAccount(
                id: UInt64.random(in: 10_000_000...99_999_999),
                phone: pendingPhone,
                token: token,
                identity: identity,
                useMobileTransport: useMobileTransport,
                telemetryMode: "disabled"
            )
            accounts.append(acc)
        }
        reauthAccountId = nil
        currentAccount = acc
        try await store.saveAccounts(accounts, currentAccountId: acc.id)
        pendingIdentity = nil
        pendingPhone = nil
        authStep = .authenticated
        loadDrafts()
        await startEventListener()
        await connectAndSyncAccount(acc)
        Task { await self.prepareCalls(); await self.loadFolders(); await self.loadStoryFeed() } // calls-platform id up front, so the first incoming call works
    }

    // MARK: - Sync & Event Loop

    public func connectAndSyncAccount(_ account: MaxAccount, silent: Bool = false) async {
        isBusy = true
        defer { isBusy = false }

        do {
            await client.setToken(account.token)
            await client.setTelemetryMode(account.telemetryMode)
            if let uid = account.userId {
                await client.setUserId(uid)
            }
            if !(await client.isConnected()) {
                _ = try await client.connect(identity: account.identity, useMobileTransport: account.useMobileTransport)
            }
            isConnected = true
            // We keep no local copy of chats/contacts, so every login asks for the FULL state
            // (sync markers -1). Incremental markers made the server return only changes → empty list.
            let savedSync = await store.loadSyncState(accountId: account.id)
            // No saved config hash: with a known hash the server omits `config` when it is unchanged, and the per-chat mute
            // settings live in that config — they would be lost after every reconnect/restart.
            let request = SyncState()
            let (loginResp, login2Resp, nextSync) = try await client.sync(state: request)
            self.syncState = nextSync
            try? await store.saveSyncState(nextSync, accountId: account.id)

            let profilePayload = login2Resp?.payload ?? loginResp.payload
            if let contactVal = profilePayload["profile"]?["contact"] {
                let me = parseContact(contactVal)
                contacts[me.id] = me
                await client.setUserId(me.id)
                updateCurrentAccount { acc in
                    acc.userId = me.id
                    acc.displayName = me.name
                    acc.phone = me.phone ?? acc.phone
                    acc.avatarURL = me.avatarURL
                }
            }

            if let contactsArr = (login2Resp?.payload["contacts"] ?? loginResp.payload["contacts"])?.arrayValue {
                for raw in contactsArr {
                    var c = parseContactValue(raw)
                    c.isInContacts = true // the login payload lists exactly the user's address book
                    contacts[c.id] = c
                }
            }

            applyPresenceMap(loginResp.payload["presence"])
            applyPresenceMap(login2Resp?.payload["presence"])

            let rawChats = loginResp.payload["chats"]?.arrayValue ?? []
            var parsed: [MaxChat] = []
            for raw in rawChats {
                let chat = parseChat(raw)
                parsed.append(chat)
                await loadAndApplySettings(chatId: chat.id)
            }
            if parsed.isEmpty && !chats.isEmpty {
                ProtocolLog.add("login returned 0 chats; keeping \(chats.count) known chats")
            } else {
                // Keep chats we knew that the reply did not mention (e.g. a partial answer), newest first.
                let ids = Set(parsed.map(\.id))
                chats = (parsed + chats.filter { !ids.contains($0.id) }).sorted { $0.lastEventTime > $1.lastEventTime }
            }
            // Mute lives in the account config (`config.chats[id].dontDisturbUntil`), not in the chat object.
            applyStoredMutes()
            applyConfigMutes(await client.serverConfig)
            applyUserSettings(await client.serverConfig)
            Task { await self.loadAnimojiSets() }
            reconnectAttempt = 0
            ProtocolLog.add("synced: \(chats.count) chats, \(contacts.count) contacts")
            Task {
            await self.ensureContacts(for: self.chats)
            if self.isDesktopSession { await self.loadPresence(Array(self.chats.compactMap { self.dialogPeerId(for: $0) }.prefix(200))) }
        }
            if let open = selectedChatId { Task { await self.loadMessages(chatId: open) } }
        } catch {
            isConnected = false
            ProtocolLog.add("sync failed: \(error.localizedDescription)")
            if Self.isSessionRevoked(error) {
                sessionRevoked(account)
                return
            }
            if !silent { errorBanner = error.localizedDescription }
            if silent || currentAccount != nil { scheduleReconnect() }
        }
    }

    /// MAX answered login with `login.token` (session ended from another device, expired or revoked):
    /// retrying is pointless and looks like abuse — stop, keep all local data, ask the user to log in again.
    nonisolated static func isSessionRevoked(_ error: Error) -> Bool {
        if case MaxTransportError.apiError(let v) = error {
            let code = v["error"]?.stringValue ?? ""
            return code == "login.token" || code.hasPrefix("login.token")
        }
        return false
    }

    func sessionRevoked(_ account: MaxAccount) {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectAttempt = 0
        reauthAccountId = account.id
        isConnected = false
        Task { await client.disconnect() }
        ProtocolLog.add("session revoked by server (login.token): reconnects stopped, waiting for re-login")
        authStep = .phoneInput
        errorBanner = "MAX завершил сессию этого устройства (выход на другом устройстве или истёк срок). Войдите снова — переписка, контакты и ключи шифрования на этом устройстве сохранятся."
    }

    /// Moves an Android-identity session to the desktop client identity: ends the old session on the server (op 20)
    /// and asks for a login code; the local account (chats cache, E2E keys) is kept and updated in place.
    public func switchToDesktopClient() async {
        guard let acc = currentAccount, !acc.identity.isDesktop else { return }
        try? await client.logout()
        sessionRevoked(acc)
        errorBanner = "Войдите снова — RMS MAKS теперь будет представляться серверу как MAX для компьютера. Переписка и ключи шифрования на этом устройстве сохранятся."
    }

    // MARK: - Reconnect

    /// Back-off reconnect after the socket drops (1 s, 2 s, 5 s, 10 s, then every 30 s) and at once
    /// when the network comes back. Re-runs login so pushes resume.
    func scheduleReconnect() {
        guard reconnectTask == nil, let account = currentAccount, authStep == .authenticated else { return }
        let delays: [UInt64] = [1, 2, 5, 10, 30]
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.reconnectTask = nil
            guard !self.isConnected else { return }
            ProtocolLog.add("reconnect attempt \(self.reconnectAttempt)")
            await self.client.disconnect()
            await self.connectAndSyncAccount(account, silent: true)
        }
    }

    func startNetworkMonitor() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let lastStatus = PathStatusBox()
        monitor.pathUpdateHandler = { [weak self] path in
            let metered = path.isExpensive || path.isConstrained
            Task { @MainActor in self?.networkIsMetered = metered }
            // React only when the network comes back (unsatisfied -> satisfied), not on every path update:
            // macOS reports updates often, and each one used to reset the back-off to 1 s.
            let wasDown = lastStatus.swap(path.status) != .satisfied
            guard path.status == .satisfied, wasDown else { return }
            Task { @MainActor in
                guard let self, !self.isConnected, self.authStep == .authenticated else { return }
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                self.reconnectAttempt = 0
                self.scheduleReconnect()
            }
        }
        monitor.start(queue: DispatchQueue(label: "rms.maks.net"))
        networkMonitor = monitor
    }

    /// op 32 for people we only know by id: dialog peers, message senders, story owners.
    public func ensureContacts(_ ids: [Int64], refresh: Bool = false) async {
        let missing = Array(Set(ids.filter { $0 > 0 && (refresh || contacts[$0] == nil) }))
        guard !missing.isEmpty else { return }
        for start in stride(from: 0, to: missing.count, by: 100) {
            let chunk = Array(missing[start..<min(start + 100, missing.count)])
            guard let resp = try? await client.getContacts(chunk) else { continue }
            for raw in resp.payload["contacts"]?.arrayValue ?? [] {
                var c = parseContactValue(raw)
                if let old = contacts[c.id] {
                    c.isInContacts = c.isInContacts ?? old.isInContacts
                    if raw["status"] == nil { c.isBlocked = old.isBlocked }
                }
                contacts[c.id] = c
            }
        }
    }

    func ensureContacts(for chats: [MaxChat]) async {
        await ensureContacts(chats.compactMap { dialogPeerId(for: $0) })
    }

    private func startEventListener() async {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            let stream = self.client.events
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .push(let resp):
                    await self.handleServerPush(resp)
                case .disconnected:
                    self.isConnected = false
                    self.scheduleReconnect()
                case .log:
                    break
                }
            }
        }
    }

    private func handleServerPush(_ resp: MaxResponse) async {
        switch resp.opcode {
        case 128:
            guard let msgVal = resp.payload["message"],
                  let chatId = resp.payload["chatId"]?.int64Value ?? msgVal["chatId"]?.int64Value
            else { return }
            let msg = parseMessage(msgVal, chatId: chatId)
            if msg.deleted {
                var list = messagesByChat[chatId] ?? []
                list.removeAll { $0.id == msg.id }
                messagesByChat[chatId] = list
                return
            }

            let decryptedMsg = await decryptAndHandleControl(message: msg, chatId: chatId)
            upsertMessage(decryptedMsg, inChat: chatId, isIncomingPush: true)

            if decryptedMsg.senderId != currentAccount?.userId {
                await sendIncomingNotification(for: decryptedMsg, chatId: chatId)
            }
        case OKCalls.Opcode.incomingCallPush:
            await handleIncomingCallPush(resp.payload)
        case 132:
            applyPresencePush(resp.payload)
        case 135:
            if let chat = resp.payload["chat"] { await applyChatUpdate(chat) }
        case 165:
            await applyCallHistoryPush(resp.payload)
        case 243:
            applyPinnedState(resp.payload["pinnedMessagesState"])
        case 277:
            applyFolders(resp.payload)
        case 293:
            applyTranscription(resp.payload)
        case 134:
            applyUserSettings(resp.payload["config"])
            applyConfigMutes(resp.payload["config"]) // config change: partial {chats:{id:{dontDisturbUntil}}}
        case 129:
            applyTypingPush(resp.payload)
        case 130:
            applyReadMarkPush(resp.payload)
        default:
            break
        }
    }

    private func sendIncomingNotification(for msg: MaxMessage, chatId: Int64) async {
        // Skip only when the user is actually looking at this chat; a background window must still notify.
        guard !(selectedChatId == chatId && NotificationService.shared.appIsActive) else { NotificationService.shared.logSkip("chat is open and the app is active"); return }
        guard let chat = chats.first(where: { $0.id == chatId }) else { NotificationService.shared.logSkip("chat \(chatId) is not in the list"); return }
        guard !chat.isMuted else { NotificationService.shared.logSkip("chat is muted"); return }

        let title = resolvedChatTitle(chat)
        let senderName = contacts[msg.senderId]?.name
        let plainText = stripHTMLTags(msg.displayText)
        let preview = plainText.isEmpty ? "Новое сообщение" : plainText
        await NotificationService.shared.notifyIncomingMessage(
            chatId: chatId,
            messageId: msg.id,
            title: title,
            body: preview,
            senderName: senderName,
            isGroup: chat.type == .chat
        )
    }

    // MARK: - Chat Selection & Messaging

    public func selectChat(_ chatId: Int64?) async {
        selectedChatId = chatId
        guard let chatId else { return }
        NotificationService.shared.clearChatNotifications(chatId: chatId)
        await loadAndApplySettings(chatId: chatId)
        await loadMessages(chatId: chatId)
    }

    public func loadMessages(chatId: Int64) async {
        do {
            let resp = try await client.fetchHistory(chatId: chatId, backward: 50)
            let rawMsgs = resp.payload["messages"]?.arrayValue ?? []
            var resolved: [MaxMessage] = []
            for raw in rawMsgs {
                let parsed = parseMessage(raw, chatId: chatId)
                let processed = await decryptAndHandleControl(message: parsed, chatId: chatId)
                resolved.append(processed)
            }
            resolved.sort { $0.timeMs < $1.timeMs }
            messagesByChat[chatId] = resolved
            Task { await self.ensureContacts(resolved.map(\.senderId)) }
            Task { await self.loadPinned(chatId: chatId) }
            Task { await self.loadPostStats(chatId: chatId, messages: resolved) }
            Task { await self.refreshCommentCounts(chatId: chatId, messages: resolved) }
            self.prefetchMedia(resolved)
            Task { await self.loadChatReactions(chatId: chatId) }
            if let last = resolved.last, let msgId = Int64(last.id) {
                _ = try? await client.readMessage(chatId: chatId, messageId: msgId, markMs: last.timeMs)
                if let idx = chats.firstIndex(where: { $0.id == chatId }) {
                    chats[idx].newMessages = 0
                }
            }
        } catch {
            // While reconnecting the chat reloads by itself after sync; don't nag with a dialog.
            if isConnected { errorBanner = error.localizedDescription }
        }
    }

    public func sendTextMessage(chatId: Int64, plaintext: String, replyToId: String? = nil, animojis: [Animoji] = [], richElements: [TextElement] = []) async {
        let trimmed = plaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let wireText: String
        // Markdown-style markers become MAX formatting ranges; encrypted chats carry plain text only.
        let formatted = settings.isActive ? (text: trimmed, elements: [TextElement]()) : formatOutgoing(trimmed, original: plaintext, rich: richElements, chatId: chatId)
        do {
            if settings.isActive {
                let sKey = settings.session.flatMap { Data(hexString: $0.sharedSecretHex) }
                let packed = try E2EProtocol.packMessage(
                    payload: .text(trimmed),
                    sessionKey: sKey,
                    password: settings.password,
                    chatId: chatId
                )
                wireText = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
            } else {
                wireText = formatted.text
            }

            let replyInt = replyToId.flatMap { Int64($0) }
            let resp = try await client.sendMessage(chatId: chatId, text: wireText, replyTo: replyInt,
                                                    elements: settings.isActive ? [] : (formatted.elements + Self.animojiElements(in: formatted.text, picks: animojis)).map(\.json))
            if let msgVal = resp.payload["message"] {
                var parsed = parseMessage(msgVal, chatId: chatId)
                if settings.isActive {
                    parsed.decrypted = DecryptedMessageState(
                        text: trimmed,
                        obfuscation: settings.obfuscation ?? "zh",
                        isEncrypted: true,
                        media: nil,
                        isHandshakeRequest: false,
                        isHandshakeAccept: false,
                        isGroupAnnounce: false,
                        isGroupKeyWrap: false,
                        handshakeDataHex: nil,
                        error: nil
                    )
                }
                upsertMessage(parsed, inChat: chatId, isIncomingPush: false)
            }
        } catch {
            recordFailedSend(chatId: chatId, text: trimmed, replyToId: replyToId, attachment: nil, error: error)
        }
    }

    /// One reaction per person: the same emoji again removes it (op 179), another one replaces it (op 178).
    public func toggleReaction(chatId: Int64, messageId: String, emoji: String) async {
        guard let mid = Int64(messageId), let idx = messagesByChat[chatId]?.firstIndex(where: { $0.id == messageId }) else { return }
        let mine = messagesByChat[chatId]?[idx].myReaction
        do {
            if mine == emoji {
                _ = try await client.removeReaction(chatId: chatId, messageId: mid)
                adjustReaction(chatId: chatId, messageId: messageId, remove: emoji, add: nil)
            } else {
                _ = try await client.addReaction(chatId: chatId, messageId: mid, emoji: emoji)
                adjustReaction(chatId: chatId, messageId: messageId, remove: mine, add: emoji)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    func adjustReaction(chatId: Int64, messageId: String, remove: String?, add: String?) {
        guard var list = messagesByChat[chatId], let i = list.firstIndex(where: { $0.id == messageId }) else { return }
        if let remove, let r = list[i].reactions.firstIndex(where: { $0.reaction == remove }) {
            let c = list[i].reactions[r].count - 1
            if c <= 0 { list[i].reactions.remove(at: r) } else { list[i].reactions[r] = MaxReactionCount(reaction: remove, count: c) }
        }
        if let add {
            if let r = list[i].reactions.firstIndex(where: { $0.reaction == add }) {
                list[i].reactions[r] = MaxReactionCount(reaction: add, count: list[i].reactions[r].count + 1)
            } else {
                list[i].reactions.append(MaxReactionCount(reaction: add, count: 1))
            }
        }
        list[i].myReaction = add
        messagesByChat[chatId] = list
    }

    public func deleteMessage(chatId: Int64, messageId: String, forEveryone: Bool) async {
        guard let mid = Int64(messageId) else { return }
        do {
            _ = try await client.deleteMessages(chatId: chatId, messageIds: [mid], forMe: !forEveryone)
            messagesByChat[chatId]?.removeAll { $0.id == messageId }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    // MARK: - 1:1 & Group E2E Controls

    public func toggleChatE2E(chatId: Int64) async {
        guard let accId = currentAccount?.id else { return }
        var settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let chat = chats.first(where: { $0.id == chatId })

        if settings.session != nil {
            do {
                let disableSignal = #"{"e2e_control":"disable","timestamp":\#(Int64(Date().timeIntervalSince1970 * 1000))}"#
                _ = try await client.sendMessage(chatId: chatId, text: disableSignal)
                archiveSession(&settings, untilMs: Int64(Date().timeIntervalSince1970 * 1000))
                settings.session = nil
                settings.pending = nil
                chatSettingsByChat[chatId] = settings
                try await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
            } catch {
                errorBanner = error.localizedDescription
            }
            return
        }

        if chat?.type == .chat {
            await initOrRotateGroupE2E(chatId: chatId, forceRotate: false)
        } else {
            do {
                let bundle = AsymmetricCrypto.generateKeypairBundle()
                let ts = Int64(Date().timeIntervalSince1970 * 1000)
                settings.pending = bundle.toHexStruct(timestamp: ts)
                chatSettingsByChat[chatId] = settings
                try await store.saveChatSettings(settings, accountId: accId, chatId: chatId)

                let hs = try AsymmetricCrypto.createHandshakeInit(edSk: bundle.edSk, edPk: bundle.edPk, xPk: bundle.xPk, timestamp: ts)
                let packed = try E2EProtocol.packMessage(payload: .handshake(hs))
                let text = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
                _ = try await client.sendMessage(chatId: chatId, text: text)
            } catch {
                errorBanner = error.localizedDescription
            }
        }
    }

    public func initOrRotateGroupE2E(chatId: Int64, forceRotate: Bool) async {
        guard let accId = currentAccount?.id else { return }
        var settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let ts = Int64(Date().timeIntervalSince1970 * 1000)

        do {
            let groupBundle = ensureGroupIdentity(&settings)
            let groupSecret: Data
            if forceRotate || settings.session == nil {
                groupSecret = SymmetricCrypto.randomBytes(32)
                archiveSession(&settings, untilMs: ts)
                let fp = EmojiFingerprint.generate(sharedSecret: groupSecret)
                settings.session = E2ESessionInfo(
                    sharedSecretHex: groupSecret.hexString,
                    fingerprint: fp,
                    establishedAt: ts,
                    isGroup: true,
                    createdBySelf: true
                )
            } else {
                groupSecret = Data(hexString: settings.session!.sharedSecretHex) ?? SymmetricCrypto.randomBytes(32)
            }

            chatSettingsByChat[chatId] = settings
            try await store.saveChatSettings(settings, accountId: accId, chatId: chatId)

            let announcePacket = try AsymmetricCrypto.createGroupKeyAnnounce(
                edSk: groupBundle.edSk,
                edPk: groupBundle.edPk,
                xPk: groupBundle.xPk,
                timestamp: ts
            )
            let announcePacked = try E2EProtocol.packMessage(payload: .handshake(announcePacket))
            let announceText = Obfuscation.encodeEncryptedBytes(announcePacked, mode: settings.obfuscation)
            _ = try await client.sendMessage(chatId: chatId, text: announceText)

            let recipientPks = collectRecipientPKs(settings: settings, myXPk: groupBundle.xPk)
            if recipientPks.count > 1 {
                let wrapPacket = try AsymmetricCrypto.createGroupKeyWrap(
                    senderEdSk: groupBundle.edSk,
                    senderEdPk: groupBundle.edPk,
                    senderXSk: groupBundle.xSk,
                    senderXPk: groupBundle.xPk,
                    groupSecret: groupSecret,
                    recipientXPks: recipientPks,
                    timestamp: ts
                )
                let wrapPacked = try E2EProtocol.packMessage(payload: .handshake(wrapPacket))
                let wrapText = Obfuscation.encodeEncryptedBytes(wrapPacked, mode: settings.obfuscation)
                _ = try await client.sendMessage(chatId: chatId, text: wrapText, notify: false)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func respondToPendingE2E(chatId: Int64, accept: Bool) async {
        guard let req = pendingE2ERequests[chatId], let accId = currentAccount?.id else { return }
        pendingE2ERequests.removeValue(forKey: chatId)

        var settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        guard accept else {
            settings.rejectedHandshakes.append(req.messageId)
            chatSettingsByChat[chatId] = settings
            try? await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
            return
        }

        do {
            let ts = Int64(Date().timeIntervalSince1970 * 1000)
            if req.isGroup {
                let groupBundle = ensureGroupIdentity(&settings)
                settings.handledHandshakes.append(req.messageId)
                chatSettingsByChat[chatId] = settings
                try await store.saveChatSettings(settings, accountId: accId, chatId: chatId)

                let announce = try AsymmetricCrypto.createGroupKeyAnnounce(
                    edSk: groupBundle.edSk,
                    edPk: groupBundle.edPk,
                    xPk: groupBundle.xPk,
                    timestamp: ts
                )
                let packed = try E2EProtocol.packMessage(payload: .handshake(announce))
                let text = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
                _ = try await client.sendMessage(chatId: chatId, text: text)
            } else if let hsData = Data(hexString: req.handshakeDataHex) {
                let parsed = try AsymmetricCrypto.parseAndVerifyHandshake(hsData)
                let myBundle = AsymmetricCrypto.generateKeypairBundle()
                let shared = try AsymmetricCrypto.computeSharedSecret(myXSk: myBundle.xSk, peerXPk: parsed.xPk)
                let fp = EmojiFingerprint.generate(sharedSecret: shared)
                archiveSession(&settings, untilMs: ts)
                settings.session = E2ESessionInfo(
                    sharedSecretHex: shared.hexString,
                    fingerprint: fp,
                    peerEdPkHex: parsed.edPk.hexString,
                    peerXPkHex: parsed.xPk.hexString,
                    myEdSkHex: myBundle.edSk.hexString,
                    myEdPkHex: myBundle.edPk.hexString,
                    establishedAt: ts,
                    isGroup: false,
                    createdBySelf: false
                )
                settings.handledHandshakes.append(req.messageId)
                chatSettingsByChat[chatId] = settings
                try await store.saveChatSettings(settings, accountId: accId, chatId: chatId)

                let acceptPkt = try AsymmetricCrypto.createHandshakeAccept(
                    edSk: myBundle.edSk,
                    edPk: myBundle.edPk,
                    xPk: myBundle.xPk,
                    timestamp: ts
                )
                let packed = try E2EProtocol.packMessage(payload: .handshake(acceptPkt))
                let text = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
                _ = try await client.sendMessage(chatId: chatId, text: text)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func updateChatPassword(chatId: Int64, password: String) async {
        guard let accId = currentAccount?.id else { return }
        var settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let clean = password.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.password = clean.isEmpty ? nil : clean
        chatSettingsByChat[chatId] = settings
        try? await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
    }

    func decryptAndHandleControl(message: MaxMessage, chatId: Int64) async -> MaxMessage {
        var msg = message
        guard let decoded = Obfuscation.decodeEncryptedBytes(from: msg.text) else {
            return msg
        }

        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let keys = settings.allSessionSecrets
        var payload: E2EPayload?
        var lastError: String?

        for k in keys {
            if let p = try? E2EProtocol.unpackMessage(bytes: decoded.bytes, sessionKey: k, password: settings.password) {
                payload = p
                break
            }
        }
        if payload == nil {
            do {
                payload = try E2EProtocol.unpackMessage(bytes: decoded.bytes, sessionKey: nil, password: settings.password)
            } catch {
                lastError = error.localizedDescription
            }
        }

        guard let payload else {
            msg.decrypted = DecryptedMessageState(
                text: "Ошибка расшифровки: \(lastError ?? "неизвестно")",
                obfuscation: decoded.mode,
                isEncrypted: true,
                media: nil,
                isHandshakeRequest: false,
                isHandshakeAccept: false,
                isGroupAnnounce: false,
                isGroupKeyWrap: false,
                handshakeDataHex: nil,
                error: lastError
            )
            return msg
        }

        switch payload {
        case .text(let plain):
            msg.decrypted = DecryptedMessageState(
                text: plain,
                obfuscation: decoded.mode,
                isEncrypted: true,
                media: nil,
                isHandshakeRequest: false,
                isHandshakeAccept: false,
                isGroupAnnounce: false,
                isGroupKeyWrap: false,
                handshakeDataHex: nil,
                error: nil
            )
        case .media(let caption, let media):
            msg.decrypted = DecryptedMessageState(
                text: caption,
                obfuscation: decoded.mode,
                isEncrypted: true,
                media: media,
                isHandshakeRequest: false,
                isHandshakeAccept: false,
                isGroupAnnounce: false,
                isGroupKeyWrap: false,
                handshakeDataHex: nil,
                error: nil
            )
        case .handshake(let hsBytes):
            await processDecodedHandshake(
                hsBytes: hsBytes,
                obfMode: decoded.mode,
                message: &msg,
                chatId: chatId
            )
        }
        return msg
    }

    private func processDecodedHandshake(
        hsBytes: Data,
        obfMode: String,
        message: inout MaxMessage,
        chatId: Int64
    ) async {
        let isFromMe = message.senderId == currentAccount?.userId
        guard let accId = currentAccount?.id else { return }
        var settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()

        if hsBytes.first == AsymmetricCrypto.groupKeyWrap {
            let myIdentity = settings.groupIdentity ?? settings.pending
            let myXSk = myIdentity.flatMap { Data(hexString: $0.xSkHex) }
            let myXPk = myIdentity.flatMap { Data(hexString: $0.xPkHex) }
            do {
                let (parsed, unwrapped) = try AsymmetricCrypto.parseAndUnwrapGroupKey(hsBytes, myXSk: myXSk, myXPk: myXPk)
                settings.groupMembers[String(message.senderId)] = GroupMemberKeyInfo(
                    edPkHex: parsed.senderEdPk.hexString,
                    xPkHex: parsed.senderXPk.hexString,
                    updatedAt: parsed.timestamp
                )
                if let groupSecret = unwrapped, !settings.allSessionSecrets.contains(groupSecret) {
                    archiveSession(&settings, untilMs: parsed.timestamp)
                    let fp = EmojiFingerprint.generate(sharedSecret: groupSecret)
                    settings.session = E2ESessionInfo(
                        sharedSecretHex: groupSecret.hexString,
                        fingerprint: fp,
                        establishedAt: parsed.timestamp,
                        isGroup: true,
                        createdBySelf: false
                    )
                    settings.pending = nil
                    pendingE2ERequests.removeValue(forKey: chatId)
                }
                chatSettingsByChat[chatId] = settings
                try? await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
                message.decrypted = DecryptedMessageState(
                    text: "Обновлён групповой ключ шифрования",
                    obfuscation: obfMode,
                    isEncrypted: true,
                    media: nil,
                    isHandshakeRequest: false,
                    isHandshakeAccept: false,
                    isGroupAnnounce: false,
                    isGroupKeyWrap: true,
                    handshakeDataHex: hsBytes.hexString,
                    error: nil
                )
            } catch {
                message.decrypted = DecryptedMessageState(
                    text: "Ошибка проверки группового ключа",
                    obfuscation: obfMode,
                    isEncrypted: true,
                    media: nil,
                    isHandshakeRequest: false,
                    isHandshakeAccept: false,
                    isGroupAnnounce: false,
                    isGroupKeyWrap: false,
                    handshakeDataHex: nil,
                    error: error.localizedDescription
                )
            }
            return
        }

        do {
            let parsed = try AsymmetricCrypto.parseAndVerifyHandshake(hsBytes)
            let isInit = parsed.subtype == AsymmetricCrypto.handshakeInit
            let isAnnounce = parsed.subtype == AsymmetricCrypto.groupKeyAnnounce
            let isAccept = parsed.subtype == AsymmetricCrypto.handshakeAccept

            if isAnnounce && !isFromMe {
                settings.groupMembers[String(message.senderId)] = GroupMemberKeyInfo(
                    edPkHex: parsed.edPk.hexString,
                    xPkHex: parsed.xPk.hexString,
                    updatedAt: parsed.timestamp
                )
                let ctrlKey = "\(chatId):\(message.id)"
                if let activeHex = settings.session?.sharedSecretHex,
                   let activeSecret = Data(hexString: activeHex),
                   !handledGroupControlKeys.contains(ctrlKey),
                   !settings.handledHandshakes.contains(message.id) {
                    let groupBundle = ensureGroupIdentity(&settings)
                    if parsed.xPk != groupBundle.xPk {
                        handledGroupControlKeys.insert(ctrlKey)
                        settings.handledHandshakes.append(message.id)
                        let pks = collectRecipientPKs(settings: settings, myXPk: groupBundle.xPk)
                        if let wrap = try? AsymmetricCrypto.createGroupKeyWrap(
                            senderEdSk: groupBundle.edSk,
                            senderEdPk: groupBundle.edPk,
                            senderXSk: groupBundle.xSk,
                            senderXPk: groupBundle.xPk,
                            groupSecret: activeSecret,
                            recipientXPks: pks,
                            timestamp: Int64(Date().timeIntervalSince1970 * 1000)
                        ), let packed = try? E2EProtocol.packMessage(payload: .handshake(wrap)) {
                            let wrapText = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
                            Task { _ = try? await self.client.sendMessage(chatId: chatId, text: wrapText, notify: false) }
                        }
                    }
                } else if settings.session == nil,
                          !settings.rejectedHandshakes.contains(message.id),
                          !settings.handledHandshakes.contains(message.id) {
                    pendingE2ERequests[chatId] = PendingE2ERequest(
                        chatId: chatId,
                        messageId: message.id,
                        handshakeDataHex: hsBytes.hexString,
                        isGroup: true
                    )
                }
                chatSettingsByChat[chatId] = settings
                try? await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
            } else if isAccept && !isFromMe, let pending = settings.pending, let myXSk = Data(hexString: pending.xSkHex) {
                let shared = try AsymmetricCrypto.computeSharedSecret(myXSk: myXSk, peerXPk: parsed.xPk)
                let fp = EmojiFingerprint.generate(sharedSecret: shared)
                archiveSession(&settings, untilMs: parsed.timestamp)
                settings.session = E2ESessionInfo(
                    sharedSecretHex: shared.hexString,
                    fingerprint: fp,
                    peerEdPkHex: parsed.edPk.hexString,
                    peerXPkHex: parsed.xPk.hexString,
                    establishedAt: parsed.timestamp,
                    isGroup: false,
                    createdBySelf: true
                )
                settings.pending = nil
                chatSettingsByChat[chatId] = settings
                try? await store.saveChatSettings(settings, accountId: accId, chatId: chatId)
            } else if isInit && !isFromMe,
                      !settings.rejectedHandshakes.contains(message.id),
                      !settings.handledHandshakes.contains(message.id) {
                pendingE2ERequests[chatId] = PendingE2ERequest(
                    chatId: chatId,
                    messageId: message.id,
                    handshakeDataHex: hsBytes.hexString,
                    isGroup: false
                )
            }

            let notice: String
            if isInit { notice = "Запрос на секретный чат" }
            else if isAnnounce { notice = "Участник готов к групповому шифрованию" }
            else { notice = "Секретный чат установлен" }

            message.decrypted = DecryptedMessageState(
                text: notice,
                obfuscation: obfMode,
                isEncrypted: true,
                media: nil,
                isHandshakeRequest: isInit,
                isHandshakeAccept: isAccept,
                isGroupAnnounce: isAnnounce,
                isGroupKeyWrap: false,
                handshakeDataHex: hsBytes.hexString,
                error: nil
            )
        } catch {
            message.decrypted = DecryptedMessageState(
                text: "Ошибка проверки рукопожатия",
                obfuscation: obfMode,
                isEncrypted: true,
                media: nil,
                isHandshakeRequest: false,
                isHandshakeAccept: false,
                isGroupAnnounce: false,
                isGroupKeyWrap: false,
                handshakeDataHex: nil,
                error: error.localizedDescription
            )
        }
    }

    // MARK: - Calls

    /// Routes answer/hang-up/mute from the iOS system call screen to the current call.
    private func wireCallKit() {
        let bridge = CallKitBridge.shared
        bridge.onAnswer = { [weak self] id in
            guard let self, self.callSession?.conversationId == id else { return }
            Task { await self.acceptIncomingCall(withVideo: false) }
        }
        bridge.onEnd = { [weak self] id in
            guard let self, self.callSession?.conversationId == id else { return }
            Task {
                if self.activeCall.isIncoming && self.activeCall.phase == .ringing {
                    await self.declineIncomingCall()
                } else {
                    await self.hangupCall()
                }
            }
        }
        bridge.onMute = { [weak self] id, muted in
            guard let self, self.callSession?.conversationId == id, self.activeCall.isMuted != muted else { return }
            self.toggleCallMute()
        }
    }
    // 1:1 calls live in CallService.swift (OK Calls signaling + WebRTC, official-client compatible).
    // Conference links: joining by link uses the same platform and arrives with group calls.


    // MARK: - Settings & Account Actions

    public func refreshSessions() async {
        do {
            let resp = try await client.getSessions()
            let arr = resp.payload["sessions"]?.arrayValue ?? []
            sessions = arr.map { item in
                MaxSessionInfo(
                    client: item["client"]?.stringValue ?? "Клиент",
                    location: item["location"]?.stringValue ?? "",
                    time: item["time"]?.int64Value ?? 0,
                    current: item["current"]?.boolValue ?? false,
                    info: item["info"]?.stringValue ?? ""
                )
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func closeOtherSessions() async {
        do {
            _ = try await client.closeAllSessions()
            await refreshSessions()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    public func toggleBiometrics(_ enabled: Bool) {
        updateCurrentAccount { $0.biometricLockEnabled = enabled }
    }

    public func logout() async {
        try? await client.logout()
        if let cur = currentAccount {
            accounts.removeAll { $0.id == cur.id }
            try? await store.saveAccounts(accounts, currentAccountId: accounts.first?.id)
        }
        currentAccount = accounts.first
        chats = []
        messagesByChat = [:]
        isConnected = false
        authStep = .phoneInput
    }

    // MARK: - Helpers

    public func resolvedChatTitle(_ chat: MaxChat) -> String {
        if chat.type == .dialog, let myId = currentAccount?.userId {
            let peerId = chat.participants.keys.first(where: { $0 != myId })
                ?? (chat.id ^ myId)
            if let contact = contacts[peerId], !contact.name.isEmpty {
                return contact.name
            }
        }
        return chat.title.isEmpty ? "Чат #\(chat.id)" : chat.title
    }

    public func dialogPeerId(for chat: MaxChat) -> Int64? {
        guard chat.type == .dialog, let myId = currentAccount?.userId else { return nil }
        return chat.participants.keys.first(where: { $0 != myId }) ?? (chat.id ^ myId)
    }

    private func loadAndApplySettings(chatId: Int64) async {
        guard let accId = currentAccount?.id else { return }
        if chatSettingsByChat[chatId] == nil {
            let s = await store.loadChatSettings(accountId: accId, chatId: chatId)
            chatSettingsByChat[chatId] = s
        }
    }

    private func ensureGroupIdentity(_ settings: inout ChatE2ESettings) -> KeypairBundle {
        if let existing = settings.groupIdentity,
           let edSk = Data(hexString: existing.edSkHex),
           let edPk = Data(hexString: existing.edPkHex),
           let xSk = Data(hexString: existing.xSkHex),
           let xPk = Data(hexString: existing.xPkHex) {
            return KeypairBundle(edSk: edSk, edPk: edPk, xSk: xSk, xPk: xPk)
        }
        let fresh = AsymmetricCrypto.generateKeypairBundle()
        settings.groupIdentity = fresh.toHexStruct(timestamp: Int64(Date().timeIntervalSince1970 * 1000))
        return fresh
    }

    private func collectRecipientPKs(settings: ChatE2ESettings, myXPk: Data) -> [Data] {
        var result: [Data] = []
        for info in settings.groupMembers.values {
            if let pk = Data(hexString: info.xPkHex), pk.count == 32, pk != myXPk, !result.contains(pk) {
                result.append(pk)
            }
        }
        if !result.contains(myXPk) {
            result.append(myXPk)
        }
        return result
    }

    private func archiveSession(_ settings: inout ChatE2ESettings, untilMs: Int64) {
        guard let cur = settings.session else { return }
        if !settings.archivedKeys.contains(where: { $0.sharedSecretHex == cur.sharedSecretHex }) {
            settings.archivedKeys.append(ArchivedSessionKey(
                sharedSecretHex: cur.sharedSecretHex,
                fingerprint: cur.fingerprint,
                messageFrom: cur.establishedAt,
                messageUntil: untilMs
            ))
        }
    }

    private func updateCurrentAccount(_ mutate: (inout MaxAccount) -> Void) {
        guard var cur = currentAccount else { return }
        mutate(&cur)
        currentAccount = cur
        if let idx = accounts.firstIndex(where: { $0.id == cur.id }) {
            accounts[idx] = cur
        }
        Task { try? await store.saveAccounts(accounts, currentAccountId: cur.id) }
    }

    func upsertMessage(_ msg: MaxMessage, inChat chatId: Int64, isIncomingPush: Bool) {
        var list = messagesByChat[chatId] ?? []
        if let idx = list.firstIndex(where: { $0.id == msg.id }) {
            list[idx] = msg
        } else {
            list.append(msg)
            list.sort { $0.timeMs < $1.timeMs }
        }
        messagesByChat[chatId] = list
        if isIncomingPush { prefetchMedia([msg]) }

        if let idx = chats.firstIndex(where: { $0.id == chatId }) {
            chats[idx].lastMessage = msg
            chats[idx].lastEventTime = max(chats[idx].lastEventTime, msg.timeMs)
            if isIncomingPush && selectedChatId != chatId && msg.senderId != currentAccount?.userId {
                chats[idx].newMessages += 1
            }
            chats.sort { $0.lastEventTime > $1.lastEventTime }
        }
    }

    private func stripHTMLTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    // MARK: - Wire JSON Parsers

    /// Bot dialogs get a "/start" button.
    public func isBotDialog(_ chat: MaxChat) -> Bool {
        guard chat.type == .dialog else { return false }
        return chat.hasBots || (dialogPeerId(for: chat).flatMap { contacts[$0]?.isBot } ?? false)
    }

    /// Contact parser for other files (adds block status from the `status` field).
    func parseContactValue(_ v: JSONValue) -> MaxContact {
        var c = parseContact(v)
        if let st = v["status"]?.stringValue { c.isBlocked = st == "BLOCKED" }
        c.isBot = (v["options"]?.arrayValue ?? []).contains { $0.stringValue == "BOT" }
        return c
    }

    private func parseContact(_ v: JSONValue) -> MaxContact {
        let id = v["id"]?.int64Value ?? 0
        // `names`: CUSTOM = how I renamed the contact, ONEME = the user's own profile name. CUSTOM wins.
        let names = v["names"]?.arrayValue ?? []
        let entry = names.first { $0["type"]?.stringValue == "CUSTOM" }
            ?? names.first { $0["type"]?.stringValue == "ONEME" }
            ?? names.first
        let firstName = (entry?["firstName"]?.stringValue ?? v["firstName"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let lastName = (entry?["lastName"]?.stringValue ?? v["lastName"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let joined = [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
        let combinedName = joined.isEmpty ? (entry?["name"]?.stringValue ?? v["name"]?.stringValue ?? "") : joined
        let own = names.first { $0["type"]?.stringValue == "ONEME" }
        let ownName = own.map { o in
            [o["firstName"]?.stringValue, o["lastName"]?.stringValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        }
        var contact = MaxContact(
            id: id,
            name: combinedName.isEmpty ? "Контакт #\(id)" : combinedName,
            firstName: firstName,
            lastName: lastName,
            phone: v["phone"]?.stringValue,
            avatarURL: v["baseUrl"]?.stringValue ?? v["baseRawUrl"]?.stringValue ?? v["baseIconUrl"]?.stringValue,
            description: v["description"]?.stringValue,
            isOnline: false,
            lastSeenMs: nil,
            link: v["link"]?.stringValue,
            registrationTime: v["registrationTime"]?.int64Value,
            gender: v["gender"]?.stringValue
        )
        if let ownName, !ownName.isEmpty, ownName != contact.name { contact.profileName = ownName }
        return contact
    }

    func parseChat(_ v: JSONValue) -> MaxChat {
        let id = v["id"]?.int64Value ?? 0
        let typeStr = v["type"]?.stringValue ?? "DIALOG"
        let type = ChatType(rawValue: typeStr) ?? .unknown
        var parts: [Int64: Int64] = [:]
        if let pObj = v["participants"]?.objectValue {
            for (k, val) in pObj {
                if let pid = Int64(k) {
                    parts[pid] = val.int64Value ?? 0
                }
            }
        }
        let lastMsg = v["lastMessage"].map { parseMessage($0, chatId: id) }
        var chat = MaxChat(
            id: id,
            type: type,
            title: v["title"]?.stringValue ?? "",
            avatarURL: v["baseIconUrl"]?.stringValue ?? v["baseUrl"]?.stringValue,
            lastEventTime: v["lastEventTime"]?.int64Value ?? lastMsg?.timeMs ?? 0,
            newMessages: Int(v["newMessages"]?.int64Value ?? 0),
            dontDisturbUntil: v["dontDisturbUntil"]?.int64Value ?? 0,
            participants: parts,
            lastMessage: lastMsg,
            pinnedMessageId: v["pinnedMessage"]?["id"]?.stringValue
        )
        chat.activeCall = Self.parseActiveCall(v["videoConversation"])
        chat.ownerId = v["owner"]?.int64Value
        chat.adminIds = (v["admins"]?.arrayValue ?? []).compactMap(\.int64Value)
            + (v["adminParticipants"]?.objectValue?.keys.compactMap { Int64($0) } ?? [])
        chat.link = v["link"]?.stringValue
        chat.chatDescription = v["description"]?.stringValue
        chat.participantsCount = v["participantsCount"]?.int64Value.map(Int.init)
        chat.pendingJoinRequests = Int(v["pendingJoinRequestsCount"]?.int64Value ?? 0)
        chat.hasBots = v["hasBots"]?.boolValue ?? false
        if let opts = v["options"]?.objectValue {
            chat.options = opts.compactMapValues(\.boolValue)
        }
        return chat
    }

    /// `chat.videoConversation` — the group call currently running in the chat, if any.
    nonisolated static func parseActiveCall(_ v: JSONValue?) -> ChatActiveCall? {
        guard let v, let conv = v["conversationId"]?.stringValue, let link = v["joinLink"]?.stringValue, !link.isEmpty else { return nil }
        return ChatActiveCall(
            conversationId: conv,
            joinLink: link,
            startedAt: v["startedAt"]?.int64Value,
            participantsCount: v["approxParticipantsCount"]?.int64Value.map(Int.init),
            isVideo: v["callType"]?.stringValue == "VIDEO" || v["type"]?.stringValue == "VIDEO"
        )
    }

    /// Push 135 (chat updated) — keeps titles, counters and the running group call fresh.
    func applyChatUpdate(_ raw: JSONValue) async {
        let updated = parseChat(raw)
        guard updated.id != 0 else { return }
        let previous = chats.first(where: { $0.id == updated.id })
        if let i = chats.firstIndex(where: { $0.id == updated.id }) {
            var merged = updated
            if merged.lastMessage == nil { merged.lastMessage = chats[i].lastMessage }
            chats[i] = merged
        } else {
            chats.append(updated)
        }
        chats.sort { $0.lastEventTime > $1.lastEventTime }
        // A group call just started in a chat we are not calling from: tell the user.
        if let call = updated.activeCall, previous?.activeCall?.conversationId != call.conversationId,
           callSession?.conversationId != call.conversationId, updated.type == .chat, !updated.isMuted {
            await NotificationService.shared.notifyIncomingCall(
                callerName: "Групповой звонок: \(resolvedChatTitle(updated))",
                isVideo: call.isVideo,
                conversationId: call.conversationId
            )
        }
    }

    nonisolated static func decodeWave(_ v: JSONValue?) -> [UInt8]? {
        switch v {
        case .binary(let d)?: return [UInt8](d)
        case .array(let arr)?: return arr.compactMap { $0.int64Value.map { UInt8(clamping: $0) } }
        default: return nil
        }
    }

    func parseMessage(_ v: JSONValue, chatId: Int64) -> MaxMessage {
        let id = v["id"]?.stringValue ?? String(v["id"]?.int64Value ?? 0)
        let sender = v["sender"]?.int64Value ?? v["from"]?.int64Value ?? 0
        let text = v["text"]?.stringValue ?? ""
        let timeMs = v["time"]?.int64Value ?? Int64(Date().timeIntervalSince1970 * 1000)
        let status = v["status"]?.stringValue ?? ""
        let deleted = status == "REMOVED"
        let edited = status == "EDITED" || (v["edited"]?.boolValue ?? false)
        let replyId = v["link"]?["type"]?.stringValue == "FORWARD" ? nil : v["link"]?["messageId"]?.stringValue

        // A forward carries the original text and attachments in `link.message`.
        let link = v["link"]
        let isForward = link?["type"]?.stringValue == "FORWARD"
        let source = isForward ? (link?["message"] ?? v) : v
        let bodyText = text.isEmpty && isForward ? (source["text"]?.stringValue ?? "") : text
        let attaches = Self.parseAttaches(source["attaches"] ?? source["attachments"] ?? v["attaches"], messageId: id)
        let forwardedFrom = isForward ? (source["sender"]?.int64Value ?? link?["chatId"]?.int64Value) : nil

        var reactions: [MaxReactionCount] = []
        if let counters = v["reactionInfo"]?["counters"]?.arrayValue {
            for c in counters {
                if let r = c["reaction"]?.stringValue {
                    reactions.append(MaxReactionCount(reaction: r, count: Int(c["count"]?.int64Value ?? 1)))
                }
            }
        }

        return MaxMessage(
            id: id,
            chatId: chatId,
            senderId: sender,
            text: bodyText,
            timeMs: timeMs,
            edited: edited,
            deleted: deleted,
            replyToMessageId: replyId,
            attaches: attaches,
            reactions: reactions,
            decrypted: nil,
            forwardedFromId: forwardedFrom,
            commentsCount: v["commentsInfo"]?["totalCount"]?.int64Value.map(Int.init),
            myReaction: v["reactionInfo"]?["yourReaction"]?.stringValue,
            elements: (v["elements"]?.arrayValue ?? []).compactMap(TextElement.init)
        )
    }

    nonisolated static let knownControlEvents: Set<String> = [
        "new", "add", "remove", "leave", "joinByLink", "title", "icon", "pin", "botStarted", "system", "hello", "privacyWarning", "sendContact",
    ]

    nonisolated static func parseAttaches(_ raw: JSONValue?, messageId id: String) -> [MaxAttachment] {
        (raw?.arrayValue ?? []).enumerated().map { idx, a in
            let type = a["_type"]?.stringValue ?? a["type"]?.stringValue ?? "FILE"
            var att = MaxAttachment(
                id: a["id"]?.stringValue ?? "\(id)_\(idx)",
                type: type,
                title: a["name"]?.stringValue ?? a["title"]?.stringValue,
                url: a["baseUrl"]?.stringValue ?? a["url"]?.stringValue,
                fileId: a["fileId"]?.int64Value,
                photoId: a["photoId"]?.int64Value,
                videoId: a["videoId"]?.int64Value ?? a["audioId"]?.int64Value,
                width: a["width"]?.int64Value.map(Int.init),
                height: a["height"]?.int64Value.map(Int.init),
                durationMs: a["duration"]?.doubleValue,
                mime: a["mime"]?.stringValue,
                size: a["size"]?.uint64Value,
                token: a["token"]?.stringValue,
                wave: decodeWave(a["wave"]),
                poll: type == "POLL" ? MaxPoll.parse(a) : nil,
                keyboard: type == "INLINE_KEYBOARD" ? BotKeyboard.parse(a) : nil
            )
            att.videoType = a["videoType"]?.int64Value.map(Int.init)
            switch type {
            case "SHARE":
                if let url = a["url"]?.stringValue, !url.isEmpty {
                    let img = a["image"]
                    att.share = LinkShare(url: url, title: a["title"]?.stringValue, description: a["description"]?.stringValue,
                                          host: a["host"]?.stringValue,
                                          imageURL: img?["baseUrl"]?.stringValue ?? img?["url"]?.stringValue ?? img?["previewUrl"]?.stringValue)
                }
            case "CONTROL":
                att.control = ControlEvent(event: a["event"]?.stringValue ?? "",
                                           userIds: (a["userIds"]?.arrayValue ?? []).compactMap(\.int64Value) + [a["userId"]?.int64Value].compactMap { $0 },
                                           title: a["title"]?.stringValue,
                                           message: a["message"]?.stringValue ?? a["shortMessage"]?.stringValue,
                                           kind: a["type"]?.stringValue)
                if !Self.knownControlEvents.contains(att.control?.event ?? "") {
                    ProtocolLog.add("unknown CONTROL event=\(att.control?.event ?? "?")")
                }
            case "CALL":
                att.call = CallAttach(isVideo: a["callType"]?.stringValue == "VIDEO" || a["type"]?.stringValue == "VIDEO",
                                      hangupType: a["hangupType"]?.stringValue ?? "HUNGUP",
                                      durationMs: Int(a["duration"]?.int64Value ?? 0), joinLink: a["joinLink"]?.stringValue)
            case "CONTACT":
                att.contactId = a["contactId"]?.int64Value
            case "LOCATION":
                att.latitude = a["latitude"]?.doubleValue
                att.longitude = a["longitude"]?.doubleValue
            default: break
            }
            return att
        }
    }
}
