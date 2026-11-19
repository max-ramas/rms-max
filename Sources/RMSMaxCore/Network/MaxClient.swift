import Foundation

public enum MaxClientEvent: Sendable {
    case push(MaxResponse)
    case disconnected(String?)
    case log(String)
}

public actor MaxClient {
    private var transport: (any MaxTransport)?
    private var seq: UInt16 = 0
    private var pending: [UInt16: CheckedContinuation<MaxResponse, Error>] = [:]
    private var readerTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?

    private var identity: MaxIdentity?
    private var token: String?
    private var tempToken: String?
    private var userId: Int64?
    private var callsSeed: Int64?
    /// Raw `config` objects from login/login2 (server feature flags such as `calls-endpoint`).
    public private(set) var serverConfig: JSONValue?
    private var interactive = true

    // Strictly disabled by default: zero telemetry sent.
    public private(set) var telemetryMode: String = "disabled"

    private var eventContinuation: AsyncStream<MaxClientEvent>.Continuation?
    public nonisolated let events: AsyncStream<MaxClientEvent>

    public init() {
        var cont: AsyncStream<MaxClientEvent>.Continuation?
        self.events = AsyncStream { c in
            cont = c
        }
        self.eventContinuation = cont
    }

    public func setToken(_ token: String?) {
        self.token = token
    }

    public func currentToken() -> String? { token }
    public func currentTempToken() -> String? { tempToken }
    public func currentUserId() -> Int64? { userId }
    public func isConnected() -> Bool { transport != nil }

    public func setUserId(_ id: Int64) {
        self.userId = id
    }

    public func setPresence(_ online: Bool) {
        self.interactive = online
    }

    public func setTelemetryMode(_ mode: String) {
        self.telemetryMode = (mode == "fake") ? "fake" : "disabled"
    }

    // MARK: - Connect / Disconnect

    @discardableResult
    public func connect(identity: MaxIdentity, useMobileTransport: Bool = true) async throws -> MaxResponse {
        await disconnect()
        self.identity = identity

        let newTransport: any MaxTransport
        if useMobileTransport {
            newTransport = try await MobileTLSTransport.connect()
        } else {
            newTransport = try await WebSocketTransport.connect()
        }
        self.transport = newTransport

        readerTask = Task { [weak self] in
            let stream = newTransport.receiveMessages()
            do {
                for try await resp in stream {
                    await self?.handleIncomingResponse(resp)
                }
                await self?.handleTransportClosed(reason: nil)
            } catch {
                await self?.handleTransportClosed(reason: error.localizedDescription)
            }
        }

        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(MaxConstants.pingIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self else { break }
                guard await self.isConnected() else { break }
                let online = await self.interactive
                do {
                    _ = try await self.sendAndWait(opcode: 1, payload: .object(["interactive": .bool(online)]))
                } catch {
                    await self.handleTransportClosed(reason: error.localizedDescription)
                    break
                }
            }
        }

        let handshakePayload: JSONValue
        if useMobileTransport {
            handshakePayload = .object([
                "clientSessionId": .int(1),
                "mt_instanceid": .string(identity.mtInstance),
                "userAgent": identity.userAgent.toJSONValue(),
                "deviceId": .string(identity.deviceId),
            ])
        } else {
            handshakePayload = .object([
                "deviceId": .string(identity.deviceId),
                "userAgent": identity.userAgent.toJSONValue(),
            ])
        }

        let resp = try await sendAndWait(opcode: 6, payload: handshakePayload)
        if let seed = resp.payload["callsSeed"]?.int64Value {
            self.callsSeed = seed
        }
        return resp
    }

    public func disconnect() async {
        readerTask?.cancel()
        readerTask = nil
        pingTask?.cancel()
        pingTask = nil

        if let transport {
            await transport.close()
        }
        self.transport = nil
        failPendingRequests(with: MaxTransportError.connectionClosed("Disconnected"))
        self.seq = 0
    }

    private func handleIncomingResponse(_ resp: MaxResponse) {
        if let cont = pending.removeValue(forKey: resp.seq) {
            cont.resume(returning: resp)
        } else {
            eventContinuation?.yield(.push(resp))
        }
    }

    private func handleTransportClosed(reason: String?) {
        readerTask?.cancel()
        readerTask = nil
        pingTask?.cancel()
        pingTask = nil
        let wasConnected = transport != nil
        transport = nil
        failPendingRequests(with: MaxTransportError.connectionClosed(reason ?? "EOF"))
        if wasConnected {
            eventContinuation?.yield(.disconnected(reason))
        }
    }

    private func failPendingRequests(with error: Error) {
        let all = pending
        pending.removeAll()
        for (_, cont) in all {
            cont.resume(throwing: error)
        }
    }

    public func sendAndWait(opcode: UInt16, payload: JSONValue, cmd: UInt8 = 0) async throws -> MaxResponse {
        guard let transport else {
            throw MaxTransportError.notConnected
        }
        seq &+= 1
        if seq == 0 { seq = 1 }
        let currentSeq = seq
        let req = MaxRequest(ver: 10, cmd: cmd, seq: currentSeq, opcode: opcode, payload: payload)

        let resp: MaxResponse = try await withThrowingTaskGroup(of: MaxResponse.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    Task { await self.registerPending(seq: currentSeq, continuation: cont, request: req, transport: transport) }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(MaxConstants.requestTimeoutSeconds * 1_000_000_000))
                throw MaxTransportError.requestTimeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        if let errVal = resp.payload["error"], errVal != .null {
            throw MaxTransportError.apiError(resp.payload)
        }
        return resp
    }

    private func registerPending(
        seq: UInt16,
        continuation: CheckedContinuation<MaxResponse, Error>,
        request: MaxRequest,
        transport: any MaxTransport
    ) {
        pending[seq] = continuation
        Task {
            do {
                try await transport.send(request)
            } catch {
                if let cont = self.pending.removeValue(forKey: seq) {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Auth & Session Lifecycle

    public func startAuth(phone: String, resend: Bool = false) async throws -> MaxResponse {
        guard let identity else { throw MaxTransportError.notConnected }
        let isWeb = identity.userAgent.deviceType.caseInsensitiveCompare("web") == .orderedSame
        var payloadObj: [String: JSONValue] = [
            "phone": .string(phone),
            "type": .string(resend ? "RESEND" : "START_AUTH"),
            "language": .string("ru"),
        ]
        if !isWeb {
            guard let seed = callsSeed,
                  let version = ApkBuildFingerprint.resolve(version: identity.userAgent.appVersion),
                  let fp = FingerprintGenerator.generate(
                    versionData: version,
                    deviceId: identity.deviceId,
                    callsSeed: seed,
                    arch: identity.userAgent.arch ?? "arm64-v8a"
                  )
            else {
                throw MaxTransportError.connectionFailed("Отсутствует fingerprint устройства")
            }
            payloadObj["mode"] = .binary(fp)
        }
        let resp = try await sendAndWait(opcode: 17, payload: .object(payloadObj))
        if let temp = resp.payload["token"]?.stringValue {
            self.tempToken = temp
        }
        return resp
    }

    public func checkCode(_ code: String) async throws -> MaxResponse {
        guard let tempToken else {
            throw MaxTransportError.invalidPayload("Отсутствует временный токен")
        }
        let resp = try await sendAndWait(
            opcode: 18,
            payload: .object([
                "token": .string(tempToken),
                "verifyCode": .string(code),
                "authTokenType": .string("CHECK_CODE"),
            ])
        )
        extractTokens(from: resp.payload)
        return resp
    }

    public func checkPassword(_ password: String, trackId: String) async throws -> MaxResponse {
        let resp = try await sendAndWait(
            opcode: 115,
            payload: .object([
                "password": .string(password),
                "trackId": .string(trackId),
            ])
        )
        extractTokens(from: resp.payload)
        return resp
    }

    public func submitRegister(firstName: String, lastName: String?) async throws -> MaxResponse {
        var obj: [String: JSONValue] = [
            "firstName": .string(firstName),
            "tokenType": .string("REGISTER"),
        ]
        if let tempToken { obj["token"] = .string(tempToken) }
        if let lastName, !lastName.isEmpty { obj["lastName"] = .string(lastName) }
        let resp = try await sendAndWait(opcode: 23, payload: .object(obj))
        if let tok = resp.payload["token"]?.stringValue ?? tempToken {
            self.token = tok
        }
        return resp
    }

    // MARK: - Login by QR code / by calling a number (official web client flows)

    /// op 288 → `{trackId, qrLink, expiresAt, pollingInterval, ttl}`; scan the QR in the MAX app
    /// on a phone that is already logged in.
    public func createLoginQR() async throws -> MaxResponse {
        try await sendAndWait(opcode: 288, payload: .null)
    }

    /// op 289 → `{status: {loginAvailable, expiresAt, ttl}}`.
    public func pollLoginQR(trackId: String) async throws -> MaxResponse {
        try await sendAndWait(opcode: 289, payload: .object(["trackId": .string(trackId)]))
    }

    /// op 224 `{source: auth, identifier: phone}` → `{trackId, pollingInterval, ...}` for call-out login.
    public func startCallOutLogin(phone: String) async throws -> MaxResponse {
        try await sendAndWait(opcode: 224, payload: .object(["source": .string("auth"), "identifier": .string(phone)]))
    }

    /// op 294 → `{status 0 wait | 1 number ready (callNumber) | 2 confirmed | 3 expired, callNumber}`.
    public func pollCallOutLogin(trackId: String) async throws -> MaxResponse {
        try await sendAndWait(opcode: 294, payload: .object(["trackId": .string(trackId)]))
    }

    /// op 291: finish a QR / call-out login → `{profile, tokenAttrs, passwordChallenge}`.
    public func completeTrackLogin(trackId: String) async throws -> MaxResponse {
        let resp = try await sendAndWait(opcode: 291, payload: .object(["trackId": .string(trackId)]))
        extractTokens(from: resp.payload)
        return resp
    }

    private func extractTokens(from payload: JSONValue) {
        guard let attrs = payload["tokenAttrs"]?.objectValue else { return }
        if let reg = attrs["REGISTER"]?["token"]?.stringValue {
            self.tempToken = reg
        }
        if let login = attrs["LOGIN"]?["token"]?.stringValue {
            self.token = login
        }
    }

    public func sync(state: SyncState) async throws -> (login: MaxResponse, login2: MaxResponse?, nextState: SyncState) {
        guard let token else { throw MaxTransportError.invalidPayload("Токен входа не задан") }
        guard let identity else { throw MaxTransportError.notConnected }

        var next = state
        let isWeb = identity.userAgent.deviceType.caseInsensitiveCompare("web") == .orderedSame

        var obj: [String: JSONValue] = [
            "userAgent": identity.userAgent.toJSONValue(),
            "interactive": .bool(true),
            "token": .string(token),
            "chatsSync": .int(next.chatsSync),
            "contactsSync": .int(next.contactsSync),
            "presenceSync": .int(next.presenceSync),
            "draftsSync": .int(next.draftsSync),
            "exp": .object(["chatsCountGroups": .binary(Data([0x0a, 0x32]))]),
            "configHash": next.configHash ?? .string("00000000-0000000000000000-00000000-0000000000000000-0000000000000000-0-0000000000000000-00000000"),
        ]

        if !isWeb, let seed = callsSeed,
           let version = ApkBuildFingerprint.resolve(version: identity.userAgent.appVersion),
           let fp = FingerprintGenerator.generate(
            versionData: version,
            deviceId: identity.deviceId,
            callsSeed: seed,
            arch: identity.userAgent.arch ?? "arm64-v8a"
           ) {
            obj["chatCacheFingerprint"] = .binary(fp)
        }

        let loginResp = try await sendAndWait(opcode: 19, payload: .object(obj))
        if let newTok = loginResp.payload["token"]?.stringValue, !newTok.isEmpty {
            self.token = newTok
        }
        if let t = loginResp.payload["time"]?.int64Value {
            next.chatsSync = t
            next.contactsSync = t
            next.draftsSync = t
            next.presenceSync = t
        }
        if let hash = loginResp.payload["config"]?["hash"] {
            next.configHash = hash
        }
        if let cfg = loginResp.payload["config"] { serverConfig = cfg }

        var login2Resp: MaxResponse?
        if let flags = loginResp.payload["login2Flags"]?.objectValue {
            let cfg = flags["configEnabled"]?.boolValue ?? false
            let cnt = flags["contactEnabled"]?.boolValue ?? false
            let prof = flags["profileEnabled"]?.boolValue ?? false
            if cfg || cnt || prof {
                let l2 = try await sendAndWait(
                    opcode: 8,
                    payload: .object([
                        "needProfile": .bool(prof),
                        "contactsSync": .int(cnt ? next.contactsSync : -1),
                        "configHash": next.configHash ?? .null,
                    ])
                )
                if let h2 = l2.payload["config"]?["hash"] {
                    next.configHash = h2
                }
                if let cfg = l2.payload["config"] { serverConfig = cfg }
                login2Resp = l2
            }
        }

        return (loginResp, login2Resp, next)
    }

    // MARK: - Chats & Messaging

    public func getChats(_ chatIds: [Int64]) async throws -> MaxResponse {
        try await sendAndWait(opcode: 48, payload: .object(["chatIds": .array(chatIds.map { .int($0) })]))
    }

    public func fetchHistory(chatId: Int64, from: Int64? = nil, backward: Int = 50, forward: Int = 0, getChat: Bool = true) async throws -> MaxResponse {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return try await sendAndWait(
            opcode: 49,
            payload: .object([
                "chatId": .int(chatId),
                "forward": .int(Int64(forward)),
                "backward": .int(Int64(backward)),
                "backwardTime": .int(0),
                "forwardTime": .int(0),
                "getChat": .bool(getChat),
                "from": .int(from ?? nowMs),
                "itemType": .string("ALL"),
                "getMessages": .bool(true),
                "interactive": .bool(true),
            ])
        )
    }

    /// opcode 68: server-side full-text search over the account's messages.
    public func searchMessages(query: String, count: Int = 30, marker: String? = nil) async throws -> MaxResponse {
        var obj: [String: JSONValue] = ["query": .string(query), "count": .int(Int64(count))]
        if let marker { obj["marker"] = .string(marker) }
        return try await sendAndWait(opcode: 68, payload: .object(obj))
    }

    public func sendMessage(
        chatId: Int64,
        text: String,
        replyTo: Int64? = nil,
        attaches: [JSONValue] = [],
        notify: Bool = true
    ) async throws -> MaxResponse {
        let cid = -Int64(Date().timeIntervalSince1970 * 1000)
        var msgObj: [String: JSONValue] = [
            "cid": .int(cid),
            "elements": .array([]),
            "attaches": .array(attaches),
        ]
        if !text.isEmpty {
            msgObj["text"] = .string(text)
        }
        if let replyTo {
            msgObj["link"] = .object(["type": .string("REPLY"), "messageId": .int(replyTo)])
        }
        return try await sendAndWait(
            opcode: 64,
            payload: .object([
                "chatId": .int(chatId),
                "message": .object(msgObj),
                "notify": .bool(notify),
            ])
        )
    }

    public func readMessage(chatId: Int64, messageId: Int64, markMs: Int64? = nil) async throws -> MaxResponse {
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        return try await sendAndWait(
            opcode: 50,
            payload: .object([
                "type": .string("READ_MESSAGE"),
                "chatId": .int(chatId),
                "messageId": .int(messageId),
                "mark": .int(markMs ?? nowMs),
            ])
        )
    }

    public func editMessage(chatId: Int64, messageId: Int64, text: String) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 67,
            payload: .object([
                "chatId": .int(chatId),
                "messageId": .int(messageId),
                "text": .string(text),
                "elements": .array([]),
            ])
        )
    }

    public func deleteMessages(chatId: Int64, messageIds: [Int64], forMe: Bool) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 66,
            payload: .object([
                "chatId": .int(chatId),
                "messageIds": .array(messageIds.map { .int($0) }),
                "forMe": .bool(forMe),
                "itemType": .string("REGULAR"),
            ])
        )
    }

    public func addReaction(chatId: Int64, messageId: Int64, emoji: String) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 178,
            payload: .object([
                "chatId": .int(chatId),
                "messageId": .int(messageId),
                "reaction": .object([
                    "reactionType": .string("EMOJI"),
                    "id": .string(emoji),
                ]),
            ])
        )
    }

    public func removeReaction(chatId: Int64, messageId: Int64) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 179,
            payload: .object([
                "chatId": .int(chatId),
                "messageId": .int(messageId),
            ])
        )
    }

    public func createGroup(title: String, userIds: [Int64]) async throws -> MaxResponse {
        let cid = Int64(Date().timeIntervalSince1970 * 1000)
        return try await sendAndWait(
            opcode: 64,
            payload: .object([
                "message": .object([
                    "cid": .int(cid),
                    "attaches": .array([
                        .object([
                            "_type": .string("CONTROL"),
                            "event": .string("new"),
                            "chatType": .string("CHAT"),
                            "title": .string(title),
                            "userIds": .array(userIds.map { .int($0) }),
                        ]),
                    ]),
                ]),
                "notify": .bool(true),
            ])
        )
    }

    public func leaveGroup(chatId: Int64) async throws -> MaxResponse {
        try await sendAndWait(opcode: 58, payload: .object(["chatId": .int(chatId)]))
    }

    public func setChatMute(chatId: Int64, dontDisturbUntil: Int64) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 22,
            payload: .object([
                "settings": .object([
                    "chats": .object([
                        String(chatId): .object(["dontDisturbUntil": .int(dontDisturbUntil)]),
                    ]),
                ]),
            ])
        )
    }

    public func fetchContacts(_ userIds: [Int64]) async throws -> MaxResponse {
        try await sendAndWait(opcode: 32, payload: .object(["contactIds": .array(userIds.map { .int($0) })]))
    }

    public func getByPhone(_ phone: String) async throws -> MaxResponse {
        try await sendAndWait(opcode: 46, payload: .object(["phone": .string(phone)]))
    }

    public func joinGroup(link: String) async throws -> MaxResponse {
        try await sendAndWait(opcode: 57, payload: .object(["link": .string(link)]))
    }

    // MARK: - Sessions, Profile, 2FA, Files & Calls

    public func getSessions() async throws -> MaxResponse {
        try await sendAndWait(opcode: 96, payload: .object([:]))
    }

    public func closeAllSessions() async throws -> MaxResponse {
        try await sendAndWait(opcode: 97, payload: .object([:]))
    }

    public func logout() async throws {
        _ = try? await sendAndWait(opcode: 20, payload: .object([:]))
        await disconnect()
    }

    public func updateProfile(firstName: String, lastName: String, description: String?) async throws -> MaxResponse {
        var obj: [String: JSONValue] = [
            "firstName": .string(firstName),
            "lastName": .string(lastName),
        ]
        if let description { obj["description"] = .string(description) }
        return try await sendAndWait(opcode: 16, payload: .object(obj))
    }

    public func fetch2FAStatus() async throws -> (trackId: String, payload: JSONValue) {
        let trackResp = try await sendAndWait(opcode: 112, payload: .object(["type": .int(0)]))
        let trackId = trackResp.payload["trackId"]?.stringValue ?? ""
        let status = try await sendAndWait(opcode: 104, payload: .object(["trackId": .string(trackId)]))
        return (trackId, status.payload)
    }

    public func configure2FA(password: String, hint: String?, trackId: String) async throws -> MaxResponse {
        var obj: [String: JSONValue] = [
            "trackId": .string(trackId),
            "password": .string(password),
        ]
        if let hint { obj["hint"] = .string(hint) }
        return try await sendAndWait(opcode: 111, payload: .object(obj))
    }

    public func getFileUploadURL(profile: Bool = false) async throws -> MaxResponse {
        try await sendAndWait(opcode: 87, payload: .object(["count": .int(1), "profile": .bool(profile)]))
    }

    public func getPhotoUploadURL(profile: Bool = false) async throws -> MaxResponse {
        try await sendAndWait(opcode: 80, payload: .object(["count": .int(1), "profile": .bool(profile)]))
    }

    public func getFileDownloadInfo(chatId: Int64, messageId: Int64, fileId: Int64) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 88,
            payload: .object([
                "chatId": .int(chatId),
                "messageId": .int(messageId),
                "fileId": .int(fileId),
            ])
        )
    }

    /// Max opcode 78: registers an outgoing call — 1:1 (`calleeIds`) or a group chat call (`chatId`).
    /// The reply carries `internalCallerParams` (signaling endpoint + STUN/TURN) for the calls platform.
    public func startOutgoingCall(calleeId: Int64?, chatId: Int64? = nil, isVideo: Bool, conversationId: String, internalParams: String) async throws -> MaxResponse {
        var payload: [String: JSONValue] = [
            "conversationId": .string(conversationId),
            "internalParams": .string(internalParams),
            "isVideo": .bool(isVideo),
        ]
        if let calleeId { payload["calleeIds"] = .array([.int(calleeId)]) }
        if let chatId { payload["chatId"] = .int(chatId) }
        return try await sendAndWait(opcode: 78, payload: .object(payload))
    }

    /// Max opcode 166 (SDK fast join): join a call by its link → `{internalParams, conversationId}`.
    public func joinCallByLink(_ joinLink: String, isVideo: Bool, internalParams: String) async throws -> MaxResponse {
        try await sendAndWait(
            opcode: 166,
            payload: .object([
                "joinLink": .string(joinLink),
                "isVideo": .bool(isVideo),
                "internalParams": .string(internalParams),
            ])
        )
    }

    /// Max opcode 158: short-lived auth token for the calls platform.
    public func callsToken() async throws -> String {
        let resp = try await sendAndWait(opcode: 158, payload: .null)
        guard let token = resp.payload["token"]?.stringValue, !token.isEmpty else {
            throw MaxTransportError.apiError(resp.payload)
        }
        return token
    }

    /// Searches the server config for a string value (keys like `calls-endpoint` may be nested).
    public func serverConfigString(_ key: String) -> String? {
        func find(_ v: JSONValue?) -> String? {
            switch v {
            case .object(let o)?:
                if let s = o[key]?.stringValue { return s }
                for child in o.values { if let s = find(child) { return s } }
                return nil
            case .array(let a)?:
                for child in a { if let s = find(child) { return s } }
                return nil
            default:
                return nil
            }
        }
        return find(serverConfig)
    }



    public func getCalls() async throws -> MaxResponse {
        try await sendAndWait(opcode: 79, payload: .object(["forward": .bool(false), "count": .int(50)]))
    }

}
