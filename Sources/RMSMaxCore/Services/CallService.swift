import Foundation
import CoreGraphics
import AVFoundation
import Network

/// One call over the OK Calls platform, compatible with the official Max clients.
///
/// Topologies (SDK `Transport`):
///  • DIRECT — peer-to-peer (ICE may still relay via the platform's TURN, which covers most CGNAT).
///    The caller ("master") offers; the callee answers after `accept-call`.
///  • SERVER — one connection to the platform's SFU: `allocate-consumer` → server offer in
///    `producer-updated` → our answer in `accept-producer`. Used for group calls, calls joined by
///    link, and as the fallback when DIRECT cannot connect: the master sends
///    `switch-topology {topology: SERVER}` after 5 s without media (or 20 s of failed ICE restart),
///    the server confirms with `topology-changed` to everyone.
/// No statistics, perf reports or log uploads are ever sent.
@MainActor
final class CallSession {
    enum Kind { case outgoing, incoming, join }

    let conversationId: String
    let kind: Kind
    let isGroup: Bool
    let signaling: OKCallSignaling
    var params: CallConnectParams

    var topology = "DIRECT"
    var direct: WebRTCCallEngine?
    var server: WebRTCCallEngine?
    var engine: WebRTCCallEngine? { topology == "SERVER" ? server : direct }

    var me: CallParticipantRef?
    var myPeerId: JSONValue?
    /// Remote participants keyed by calls-platform id.
    var participants: [Int64: CallParticipantRef] = [:]
    var remote: CallParticipantRef? // the peer of a DIRECT call

    var pendingOffer: (type: String, sdp: String)?
    var localOffer: String?
    var gotAnswer = false
    var accepted = false          // the call is answered (by us, or — outgoing — by the peer)
    var mediaConnected = false
    var isMaster: Bool { kind == .outgoing }

    var serverSessionId = ""
    let sfu = SFUNotificationDecoder()
    var slotOwner: [String: Int64] = [:]      // SFU stream id ("pat-N") → participant
    var slotTrack: [String: CallVideoTrack] = [:]
    var requestedLayouts: [String: String] = [:]

    var eventsTask: Task<Void, Never>?
    var ringTimeout: Task<Void, Never>?
    var connectWatch: Task<Void, Never>?
    var iceRestartWatch: Task<Void, Never>?
    var pathMonitor: NWPathMonitor?
    var serverLimits = WebRTCCallEngine.VideoLimits()
    var adaptTask: Task<Void, Never>?
    var lastPathKey: String?
    var ended = false

    init(conversationId: String, kind: Kind, isGroup: Bool, params: CallConnectParams, log: @escaping @Sendable (String) -> Void) {
        self.conversationId = conversationId
        self.kind = kind
        self.isGroup = isGroup
        self.params = params
        self.signaling = OKCallSignaling(log: log)
    }

    func cancelTimers() {
        ringTimeout?.cancel()
        connectWatch?.cancel()
        iceRestartWatch?.cancel()
        pathMonitor?.cancel()
        pathMonitor = nil
        adaptTask?.cancel()
    }
}

public extension AppStore {
    // MARK: - Starting calls

    func startCall(chatId: Int64, peerId: Int64?, isVideo: Bool, secure: Bool) async {
        guard callSession == nil, activeCall.phase == .idle || activeCall.phase == .ended else {
            errorBanner = "Уже идёт звонок"
            return
        }
        let chat = chats.first(where: { $0.id == chatId })
        let isGroup = chat?.type == .chat || peerId == nil
        var state = ActiveCallState()
        state.phase = .connecting
        state.chatId = chatId
        state.peerId = peerId
        state.isGroup = isGroup
        state.peerName = chat.map { resolvedChatTitle($0) } ?? peerId.flatMap { contacts[$0]?.name } ?? "Звонок"
        state.isVideo = isVideo
        activeCall = state
        BackgroundKeepAlive.shared.stop()
        guard await prepareDevices(video: isVideo) else { return }

        let conversationId = UUID().uuidString.lowercased()
        activeCall.conversationId = conversationId
        do {
            let resp = try await client.startOutgoingCall(
                calleeId: isGroup ? nil : peerId,
                chatId: isGroup ? chatId : nil,
                isVideo: isVideo,
                conversationId: conversationId,
                internalParams: CallParamsCodec.internalParams(deviceId: Self.callsDeviceId)
            )
            if !isGroup, let rejected = resp.payload["rejectedParticipants"]?.arrayValue?.first {
                endCall(message: Self.describeHangup(rejected["errorCode"]?.stringValue ?? rejected["status"]?.stringValue))
                return
            }
            guard let raw = resp.payload["internalCallerParams"]?.stringValue else {
                endCall(message: "Сервер не вернул параметры звонка")
                return
            }
            let params = try CallParamsCodec.parseInternalCallerParams(raw)
            if let uid = CallParamsCodec.userId(inEndpoint: params.endpoint) { cachedCallsUserId = uid }
            let session = CallSession(conversationId: conversationId, kind: .outgoing, isGroup: isGroup, params: params, log: Self.callLog)
            callSession = session
            CallKitBridge.shared.reportOutgoing(conversationId, to: activeCall.peerName, isVideo: isVideo)
            try await connect(session, type: .start)
        } catch {
            endCall(message: error.localizedDescription)
        }
    }

    /// Joins a running call (group/conference) by its link, like the official "join by link".
    func joinConferenceByLink(_ link: String, isVideo: Bool, secure: Bool) async {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        guard !token.isEmpty else { return }
        guard callSession == nil else { errorBanner = "Уже идёт звонок"; return }
        var state = ActiveCallState()
        state.phase = .connecting
        state.isGroup = true
        state.peerName = "Конференция"
        state.isVideo = isVideo
        activeCall = state
        guard await prepareDevices(video: isVideo) else { return }
        do {
            let resp = try await client.joinCallByLink(token, isVideo: isVideo, internalParams: CallParamsCodec.internalParams(deviceId: Self.callsDeviceId))
            guard let raw = resp.payload["internalParams"]?.stringValue ?? resp.payload["internalCallerParams"]?.stringValue,
                  let conversationId = resp.payload["conversationId"]?.stringValue
            else {
                endCall(message: "Ссылка недействительна или звонок завершён")
                return
            }
            let params = try CallParamsCodec.parseInternalCallerParams(raw)
            activeCall.conversationId = conversationId
            activeCall.inviteLink = trimmed
            let session = CallSession(conversationId: conversationId, kind: .join, isGroup: true, params: params, log: Self.callLog)
            callSession = session
            CallKitBridge.shared.reportOutgoing(conversationId, to: "Конференция", isVideo: isVideo)
            try await connect(session, type: .join)
        } catch {
            endCall(message: error.localizedDescription)
        }
    }

    func acceptIncomingCall(withVideo: Bool = false) async {
        guard let session = callSession, session.kind == .incoming, !session.accepted else { return }
        guard await Self.requestMicrophone() else {
            await hangupCall(reason: "REJECTED")
            errorBanner = "Нет доступа к микрофону"
            return
        }
        if withVideo { activeCall.cameraEnabled = await Self.requestCamera() }
        session.accepted = true
        session.ringTimeout?.cancel()
        NotificationService.shared.clearCallNotifications()
        CallKitBridge.shared.reportConnecting(session.conversationId)
        activeCall.phase = .connecting
        do {
            try await session.signaling.send("accept-call", ["mediaSettings": currentMediaSettings])
            try await openTransport(session)
        } catch {
            endCall(message: error.localizedDescription)
        }
    }

    func declineIncomingCall() async {
        await hangupCall(reason: "REJECTED")
    }

    func hangupCall() async {
        guard let session = callSession else {
            activeCall = ActiveCallState()
            return
        }
        let reason = session.accepted || session.mediaConnected || session.kind == .join ? "HUNGUP" : "CANCELED"
        await hangupCall(reason: reason)
    }

    // MARK: - In-call controls

    func toggleCallMute() {
        guard let session = callSession else { return }
        activeCall.isMuted.toggle()
        session.direct?.setMicrophoneEnabled(!activeCall.isMuted)
        session.server?.setMicrophoneEnabled(!activeCall.isMuted)
        CallKitBridge.shared.reportMuted(session.conversationId, activeCall.isMuted)
        announceMediaSettings(session)
    }

    /// Camera on/off mid-call — the video track already exists, so this is a track toggle plus a
    /// `change-media-settings`, exactly how the official client does it (no renegotiation).
    func toggleCallCamera() async {
        guard let session = callSession, let engine = session.engine else { return }
        let want = !activeCall.cameraEnabled
        if want, !(await Self.requestCamera()) {
            errorBanner = "Нет доступа к камере. Разрешите его в настройках системы."
            return
        }
        let ok = await engine.setCameraEnabled(want)
        guard callSession === session else { return }
        activeCall.cameraEnabled = want && ok
        if want && !ok { errorBanner = "Не удалось включить камеру" }
        callLocalVideo = activeCall.cameraEnabled ? engine.localVideoTrack : nil
        announceMediaSettings(session)
    }

    func switchCallCamera() async {
        await callSession?.engine?.switchCamera()
    }

    // MARK: - Incoming push (Max opcode 137)

    func handleIncomingCallPush(_ payload: JSONValue) async {
        guard let conversationId = payload["conversationId"]?.stringValue,
              let vcp = payload["vcp"]?.stringValue
        else { return }
        let callerId = payload["callerId"]?.int64Value
        let isVideo = payload["type"]?.stringValue == "VIDEO"
        if let current = callSession {
            if current.conversationId != conversationId {
                await rejectBusy(conversationId: conversationId, vcp: vcp, callerId: callerId, isVideo: isVideo)
            }
            return
        }
        let callerName = callerId.flatMap { contacts[$0]?.name } ?? "Входящий звонок"
        var state = ActiveCallState()
        state.phase = .ringing
        state.isIncoming = true
        state.conversationId = conversationId
        state.peerId = callerId
        state.chatId = callerId.flatMap { cid in chats.first(where: { dialogPeerId(for: $0) == cid })?.id }
        state.peerName = callerName
        state.isVideo = isVideo
        activeCall = state
        BackgroundKeepAlive.shared.stop()
        CallKitBridge.shared.reportIncoming(conversationId, caller: callerName, isVideo: isVideo)
        await NotificationService.shared.notifyIncomingCall(callerName: callerName, isVideo: isVideo, conversationId: conversationId)

        do {
            let params = try CallParamsCodec.decodeVCP(vcp)
            let session = CallSession(conversationId: conversationId, kind: .incoming, isGroup: false, params: params, log: Self.callLog)
            callSession = session
            let uid = await resolveCallsUserId()
            try await connect(session, type: .accept, incomingUserId: uid)
            session.ringTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard !Task.isCancelled, let self, self.callSession === session, !session.accepted else { return }
                self.endCall(message: "Пропущенный звонок")
            }
        } catch {
            endCall(message: error.localizedDescription)
        }
    }

    /// Second call while we are talking: answer "busy" like the official client (its SDK throws
    /// BUSY from processPush and hangs up through signaling) instead of letting it ring out.
    private func rejectBusy(conversationId: String, vcp: String, callerId: Int64?, isVideo: Bool) async {
        let name = callerId.flatMap { contacts[$0]?.name } ?? "Неизвестный"
        await NotificationService.shared.notifyIncomingCall(callerName: "Пропущен (вы разговаривали): \(name)", isVideo: isVideo, conversationId: conversationId)
        guard let params = try? CallParamsCodec.decodeVCP(vcp) else { return }
        let uid = await resolveCallsUserId()
        guard let url = try? CallParamsCodec.signalingURL(
            endpoint: params.endpoint, connectionType: .accept, appVersion: Self.callsAppVersion,
            clientType: params.clientType, incoming: (userId: uid, conversationId: conversationId, token: params.token)
        ) else { return }
        let signaling = OKCallSignaling(log: Self.callLog)
        if (try? await signaling.connect(url: url, timeout: 10)) != nil {
            _ = try? await signaling.send("hangup", ["reason": .string("BUSY")], needResponse: false)
        }
        await signaling.close()
    }

    // MARK: - Speaker, devices, network

    /// iPhone/iPad: loudspeaker ⇄ earpiece. Video calls start on the speaker, voice calls on the earpiece.
    func toggleSpeaker() {
        activeCall.speakerOn.toggle()
        #if os(iOS)
        CallDevices.setSpeaker(activeCall.speakerOn)
        #endif
    }

    /// After the user picked another camera in the device menu.
    func reselectCamera() async {
        await callSession?.engine?.reselectCamera()
    }

    /// Wi-Fi ⇄ cellular: reconnect signaling at once; the caller restarts ICE (DIRECT) or the SFU
    /// connection is reallocated (SERVER). If the peer does not recover DIRECT within 10 s, we ask
    /// for SERVER from either side.
    private func startPathMonitor(_ session: CallSession) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let key = path.availableInterfaces.map(\.name).sorted().joined(separator: ",") + "|\(path.status == .satisfied)"
            Task { @MainActor in
                guard let self, self.callSession === session else { return }
                defer { session.lastPathKey = key }
                guard let previous = session.lastPathKey, previous != key, path.status == .satisfied else { return }
                self.networkChanged(session)
            }
        }
        monitor.start(queue: DispatchQueue(label: "rms.max.calls.path"))
        session.pathMonitor = monitor
    }

    private func networkChanged(_ session: CallSession) {
        Self.callLog("network path changed")
        activeCall.statusMessage = "Сеть изменилась — переподключаемся…"
        Task { await session.signaling.forceReconnect() }
        guard session.accepted, let engine = session.engine else { return }
        if engine.mode == .server {
            Task { _ = try? await session.signaling.send("request-realloc") }
            return
        }
        if session.isMaster {
            Task { try? await engine.createOffer(iceRestart: true) }
        }
        session.iceRestartWatch?.cancel()
        session.iceRestartWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, let self, self.callSession === session,
                  session.topology == "DIRECT", engine.connectionState != .connected else { return }
            Self.callLog("switch-topology → SERVER (network change, from any side)")
            _ = try? await session.signaling.send("switch-topology", ["topology": .string("SERVER"), "force": .bool(false)])
        }
    }

    // MARK: - Connection

    private func prepareDevices(video: Bool) async -> Bool {
        guard await PermissionsCenter.shared.ensureMicrophone() else {
            endCall(message: "Нет доступа к микрофону")
            return false
        }
        if video {
            activeCall.cameraEnabled = await Self.requestCamera()
            if !activeCall.cameraEnabled { activeCall.statusMessage = "Нет доступа к камере — только голос" }
        }
        return true
    }

    private func connect(_ session: CallSession, type: CallParamsCodec.ConnectionType, incomingUserId: Int64? = nil) async throws {
        let url = try CallParamsCodec.signalingURL(
            endpoint: session.params.endpoint,
            connectionType: type,
            appVersion: Self.callsAppVersion,
            clientType: session.params.clientType,
            incoming: session.kind == .incoming
                ? (userId: incomingUserId, conversationId: session.conversationId, token: session.params.token)
                : nil
        )
        let connection = try await session.signaling.connect(url: url)
        guard callSession === session else { return }
        applyConnection(connection, to: session)
        guard callSession === session else { return }
        startPathMonitor(session)
        activeCall.speakerOn = activeCall.isVideo
        #if os(iOS)
        CallDevices.setSpeaker(activeCall.speakerOn)
        #endif

        session.eventsTask = Task { [weak self] in
            for await event in session.signaling.events {
                guard let self, self.callSession === session else { break }
                switch event {
                case .notification(let name, let msg):
                    await self.handleNotification(name, msg, session: session)
                case .reconnecting:
                    self.activeCall.statusMessage = "Восстанавливаем соединение…"
                case .reconnected(let msg):
                    self.activeCall.statusMessage = nil
                    self.applyConnection(msg, to: session)
                    if let t = msg["conversation"]?["topology"]?.stringValue, t != session.topology {
                        await self.switchTopology(session, to: t, offerTo: nil)
                    }
                case .closed(let reason):
                    if !session.ended { self.endCall(message: reason.map { "Соединение прервано: \($0)" } ?? "Звонок завершён") }
                }
            }
        }

        switch session.kind {
        case .outgoing:
            activeCall.phase = session.isGroup ? .active : .ringing
            if session.isGroup { activeCall.startedAt = Date(); session.accepted = true }
            if connection["conversation"]?["concurrent"]?.boolValue == true || session.params.isConcurrent {
                // A call is already running in this chat — join it (SDK _acceptConcurrent).
                session.accepted = true
                try await session.signaling.send("accept-call", ["mediaSettings": currentMediaSettings])
            }
            try await openTransport(session)
            announceMediaSettings(session)
            if !session.isGroup {
                session.ringTimeout = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    guard !Task.isCancelled, let self, self.callSession === session, !session.accepted else { return }
                    await self.hangupCall(reason: "CANCELED")
                    self.activeCall.statusMessage = "Нет ответа"
                }
            }
        case .join:
            session.accepted = true
            activeCall.phase = .active
            activeCall.startedAt = Date()
            try await openTransport(session)
            announceMediaSettings(session)
        case .incoming:
            break // waits for the user to accept
        }
    }

    private func applyConnection(_ msg: JSONValue, to session: CallSession) {
        session.myPeerId = msg["peerId"] ?? session.myPeerId
        let conversation = msg["conversation"]
        if let t = conversation?["topology"]?.stringValue, session.engine == nil {
            session.topology = t
            activeCall.topology = t
        }
        let knownUid = session.kind == .incoming ? cachedCallsUserId : CallParamsCodec.userId(inEndpoint: session.params.endpoint)
        for p in conversation?["participants"]?.arrayValue ?? [] {
            guard let ref = CallParticipantRef(participant: p) else { continue }
            let isMe = (knownUid != nil && ref.id == knownUid)
                || (p["peerId"]?["id"] != nil && p["peerId"]?["id"] == session.myPeerId?["id"])
            if isMe {
                session.me = ref
                continue
            }
            let state = p["state"]?.stringValue
            if state == "HUNGUP" || state == "REJECTED" {
                removeParticipant(ref, session: session)
                continue
            }
            upsertParticipant(ref, raw: p, session: session, joined: state == "ACCEPTED")
            if session.remote == nil { session.remote = ref }
        }
        if let me = session.me { cachedCallsUserId = me.id }
        applyFeatureSnapshot(msg, session: session)
        if session.kind == .incoming, session.participants.isEmpty, !session.accepted {
            endCall(message: "Звонок уже завершён")
        }
    }

    // MARK: - Transports

    /// Creates the media connection for the current topology (SDK `_openTransport`).
    private func openTransport(_ session: CallSession) async throws {
        if session.topology == "SERVER" {
            try await openServerTransport(session)
        } else {
            try await openDirectTransport(session)
        }
    }

    private func openDirectTransport(_ session: CallSession) async throws {
        let engine = makeEngine(for: session, mode: .direct)
        await prepareLocalMedia(engine)
        if session.isMaster {
            try await engine.createOffer()
        } else if let offer = session.pendingOffer {
            session.pendingOffer = nil
            try await engine.setRemoteDescription(type: offer.type, sdp: offer.sdp)
        }
        if session.accepted { startConnectWatch(session) }
    }

    private func openServerTransport(_ session: CallSession) async throws {
        let engine = makeEngine(for: session, mode: .server)
        await prepareLocalMedia(engine)
        session.serverSessionId = ""
        try await session.signaling.send("allocate-consumer", ["capabilities": OKCalls.consumerCapabilities()])
        requestLayouts(session, force: true)
    }

    /// `topology-changed` (or a reconnect snapshot) — tear down one transport, bring up the other.
    private func switchTopology(_ session: CallSession, to topology: String, offerTo: CallParticipantRef?) async {
        guard topology != session.topology || session.engine == nil else { return }
        Self.callLog("topology \(session.topology) → \(topology)")
        session.connectWatch?.cancel()
        session.iceRestartWatch?.cancel()
        session.topology = topology
        activeCall.topology = topology
        guard session.accepted || session.kind != .incoming else { return } // not answered yet: transport opens on accept
        if topology == "SERVER" {
            dropE2EForServerTopology(session)
            closeEngine(&session.direct)
            activeCall.statusMessage = "Соединение через сервер звонков"
            do { try await openServerTransport(session) } catch { endCall(message: error.localizedDescription) }
        } else {
            closeEngine(&session.server)
            clearSFUVideo(session)
            session.gotAnswer = false
            session.localOffer = nil
            let engine = makeEngine(for: session, mode: .direct)
            await prepareLocalMedia(engine)
            if let offerTo, offerTo == session.me {
                do { try await engine.createOffer() } catch { endCall(message: error.localizedDescription) }
            }
            startConnectWatch(session)
        }
    }

    /// DIRECT must connect within 5 s of opening (SDK transportConnectionWaitTime); otherwise the
    /// master asks the platform to relay through its SFU.
    private func startConnectWatch(_ session: CallSession) {
        session.connectWatch?.cancel()
        session.connectWatch = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard !Task.isCancelled, let self, self.callSession === session,
                  session.topology == "DIRECT", !session.mediaConnected, session.accepted else { return }
            self.requestServerTopology(session, reason: "нет прямого соединения за 5 с")
        }
    }

    private func requestServerTopology(_ session: CallSession, reason: String) {
        guard session.isMaster, session.topology == "DIRECT" else { return }
        Self.callLog("switch-topology → SERVER (\(reason))")
        activeCall.statusMessage = "Переключаемся на сервер звонков…"
        Task { _ = try? await session.signaling.send("switch-topology", ["topology": .string("SERVER"), "force": .bool(false)]) }
    }

    private func closeEngine(_ engine: inout WebRTCCallEngine?) {
        engine?.onLocalDescription = nil
        engine?.onLocalCandidate = nil
        engine?.onStateChange = nil
        engine?.close()
        engine = nil
    }

    // MARK: - Notifications

    private func handleNotification(_ name: String, _ msg: JSONValue, session: CallSession) async {
        let from = CallParticipantRef(message: msg)
        switch name {
        case "transmitted-data":
            guard session.topology == "DIRECT", let data = msg["data"] else { return }
            if session.remote == nil, let from, from != session.me { session.remote = from }
            if let sdp = data["sdp"], let type = sdp["type"]?.stringValue, let text = sdp["sdp"]?.stringValue {
                guard let engine = session.direct, session.accepted || session.isMaster else {
                    session.pendingOffer = (type, text) // incoming, not answered yet
                    return
                }
                if type == "answer" { session.gotAnswer = true }
                do { try await engine.setRemoteDescription(type: type, sdp: text) } catch {
                    Self.callLog("remote SDP rejected: \(error.localizedDescription)")
                }
            } else if let c = data["candidate"], let cand = c["candidate"]?.stringValue, !cand.isEmpty {
                let engine = session.direct ?? makeEngine(for: session, mode: .direct) // caches until the offer
                await engine.addRemoteCandidate(
                    candidate: cand,
                    sdpMid: c["sdpMid"]?.stringValue,
                    sdpMLineIndex: Int32(c["sdpMLineIndex"]?.int64Value ?? 0)
                )
            }

        case "accepted-call":
            if let from, from == session.me {
                if session.kind == .incoming && !session.accepted { endCall(message: "Принят на другом устройстве") }
                return
            }
            if let from { upsertParticipant(from, raw: msg["participant"], session: session, joined: true) }
            applyMediaSettings(msg["mediaSettings"], for: from, session: session)
            guard !session.isGroup || !session.accepted else { return }
            session.accepted = true
            session.ringTimeout?.cancel()
            if session.remote == nil { session.remote = from }
            if !session.mediaConnected { activeCall.phase = .connecting }
            if session.topology == "DIRECT" {
                // Re-send our offer in case it raced the callee's connection (duplicates are ignored).
                if session.isMaster, !session.gotAnswer, let offer = session.localOffer { sendSDP(session, type: "offer", sdp: offer) }
                startConnectWatch(session)
            }

        case "participant-added", "participant-joined":
            if let from, from != session.me {
                upsertParticipant(from, raw: msg["participant"], session: session, joined: name == "participant-joined")
                applyMediaSettings(msg["mediaSettings"] ?? msg["participant"]?["mediaSettings"], for: from, session: session)
            }

        case "hungup":
            guard let from else { endCall(message: Self.describeHangup(msg["reason"]?.stringValue)); return }
            if from == session.me {
                endCall(message: Self.describeHangup(msg["reason"]?.stringValue))
            } else if session.isGroup {
                removeParticipant(from, session: session)
            } else if from == session.remote {
                endCall(message: Self.describeHangup(msg["reason"]?.stringValue))
            }

        case "closed-conversation":
            endCall(message: Self.describeHangup(msg["reason"]?.stringValue ?? "ENDED"))

        case "media-settings-changed":
            applyMediaSettings(msg["mediaSettings"], for: from, session: session)

        case "topology-changed":
            guard let t = msg["topology"]?.stringValue else { return }
            let offerTo: CallParticipantRef? = {
                guard let id = msg["offerTo"]?[0]?.int64Value ?? msg["offerTo"]?[0]?.stringValue.flatMap({ Int64($0) }) else { return nil }
                return CallParticipantRef(
                    id: id,
                    type: msg["offerToTypes"]?[0]?.stringValue ?? "USER",
                    deviceIdx: Int(msg["offerToDeviceIdxs"]?[0]?.int64Value ?? 0)
                )
            }()
            await switchTopology(session, to: t, offerTo: offerTo)

        case "producer-updated":
            guard let sdp = msg["description"]?.stringValue else { return }
            let sessionId = msg["sessionId"]?.stringValue ?? ""
            if !session.serverSessionId.isEmpty, session.serverSessionId != sessionId {
                // New SFU session: rebuild the server connection (SDK ServerTransport._reconnect).
                closeEngine(&session.server)
                clearSFUVideo(session)
                let engine = makeEngine(for: session, mode: .server)
                await prepareLocalMedia(engine)
            }
            session.serverSessionId = sessionId
            await acceptProducer(session, offer: sdp, sessionId: sessionId)

        case "settings-update":
            if let cam = msg["camera"] {
                session.serverLimits = WebRTCCallEngine.VideoLimits(
                    maxDimension: cam["maxDimension"]?.int64Value.map(Int.init),
                    maxBitrateK: cam["maxBitrateK"]?.int64Value.map(Int.init),
                    maxFramerate: cam["maxFramerate"]?.int64Value.map(Int.init)
                )
                session.engine?.applyServerLimits(session.serverLimits)
            }

        case "video-quality-update":
            guard msg["mediaType"]?.stringValue != "SCREEN", let q = msg["quality"] else { return }
            if let b = q["maxBitrate"]?.int64Value { session.serverLimits.maxBitrateK = Int(b / 1024) }
            if let d = q["maxDimension"]?.int64Value { session.serverLimits.maxDimension = Int(d) }
            session.engine?.applyServerLimits(session.serverLimits)

        case "custom-data":
            _ = handleE2ECustomData(msg, session: session)

        case "realloc-con":
            guard session.topology == "SERVER" else { return }
            closeEngine(&session.server)
            clearSFUVideo(session)
            do { try await openServerTransport(session) } catch { endCall(message: error.localizedDescription) }

        case "error":
            Self.callLog("signaling error notification")

        default:
            handleFeatureNotification(name, msg, session: session)
        }
    }

    private func acceptProducer(_ session: CallSession, offer: String, sessionId: String) async {
        guard let engine = session.server else { return }
        do {
            let (answer, ssrcs) = try await engine.applyServerOffer(offer)
            var params: [String: JSONValue] = ["description": .string(answer), "sessionId": .string(sessionId)]
            if !ssrcs.isEmpty { params["ssrcs"] = .array(ssrcs.map { .string($0) }) }
            try await session.signaling.send("accept-producer", params)
        } catch {
            Self.callLog("accept-producer failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Participants & video

    private func upsertParticipant(_ ref: CallParticipantRef, raw: JSONValue?, session: CallSession, joined: Bool) {
        session.participants[ref.id] = ref
        let maxId = raw?["externalId"]?["id"]?.int64Value
        if let i = activeCall.participants.firstIndex(where: { $0.id == ref.id }) {
            if joined { activeCall.participants[i].joined = true }
            if let maxId, activeCall.participants[i].maxUserId == nil {
                activeCall.participants[i].maxUserId = maxId
                activeCall.participants[i].name = contacts[maxId]?.name ?? activeCall.participants[i].name
            }
        } else {
            let name = maxId.flatMap { contacts[$0]?.name } ?? (session.isGroup ? "Участник" : activeCall.peerName)
            var info = CallParticipantInfo(id: ref.id, maxUserId: maxId, name: name)
            info.joined = joined
            activeCall.participants.append(info)
        }
        if let ms = raw?["mediaSettings"] { applyMediaSettings(ms, for: ref, session: session) }
    }

    private func removeParticipant(_ ref: CallParticipantRef, session: CallSession) {
        session.participants[ref.id] = nil
        activeCall.participants.removeAll { $0.id == ref.id }
        callRemoteVideos[ref.id] = nil
        requestLayouts(session)
    }

    private func applyMediaSettings(_ settings: JSONValue?, for ref: CallParticipantRef?, session: CallSession) {
        guard let settings else { return }
        let screen = (settings["isScreenSharingEnabled"]?.boolValue ?? false) || (settings["isFastScreenSharingEnabled"]?.boolValue ?? false)
        let video = (settings["isVideoEnabled"]?.boolValue ?? false) || screen
        let audio = settings["isAudioEnabled"]?.boolValue ?? true
        let target = ref ?? session.remote
        if let target, let i = activeCall.participants.firstIndex(where: { $0.id == target.id }) {
            activeCall.participants[i].videoEnabled = video
            activeCall.participants[i].audioEnabled = audio
            activeCall.participants[i].screenSharing = screen
        }
        if !session.isGroup, target == nil || target == session.remote {
            activeCall.remoteVideoEnabled = video
            activeCall.remoteMuted = !audio
        }
        requestLayouts(session)
    }

    /// SFU only sends video we ask for (`update-display-layout`, SDK `requestDisplayLayout`).
    private func requestLayouts(_ session: CallSession, force: Bool = false) {
        guard session.topology == "SERVER", session.server != nil else { return }
        // Ask for what a tile can show: full screen for one peer, smaller for grids.
        let videos = activeCall.participants.filter(\.videoEnabled).count
        let size = videos <= 1 ? "1280x720" : (videos <= 4 ? "640x360" : "320x180")
        var layouts: [String: String] = [:]
        for info in activeCall.participants {
            guard let ref = session.participants[info.id] else { continue }
            layouts[SFUStreamDescription.layoutKey(ref)] = info.videoEnabled && !info.screenSharing ? "p=1:sz=\(size)" : "ss"
            layouts[SFUStreamDescription.layoutKey(ref, mediaType: "SCREEN")] = info.screenSharing ? "p=2:sz=1920x1080" : "ss"
        }
        // "ss" (stop stream) only for streams we requested before.
        let toSend = layouts.filter { k, v in
            (force || session.requestedLayouts[k] != v) && (v != "ss" || session.requestedLayouts[k] != nil)
        }
        guard !toSend.isEmpty else { return }
        for (k, v) in toSend { session.requestedLayouts[k] = v == "ss" ? nil : v }
        let payload: JSONValue = .object(toSend.mapValues { JSONValue.string($0) })
        Task { _ = try? await session.signaling.send("update-display-layout", ["layouts": payload]) }
    }

    private func handleSFUFrame(_ data: Data, session: CallSession) {
        for event in session.sfu.decode(data) {
            switch event {
            case .trackBound(let streamId, let participant, let mediaType):
                if let p = participant, mediaType == nil || mediaType == "CAMERA" || mediaType == "SCREEN" {
                    session.slotOwner[streamId] = p.id
                } else {
                    session.slotOwner[streamId] = nil
                }
                bindSFUVideo(session)
            case .speaker(let p):
                for i in activeCall.participants.indices {
                    activeCall.participants[i].speaking = activeCall.participants[i].id == p?.id
                }
            case .active:
                break
            case .videoQuality(let bitrate, let dimension, let screen):
                guard !screen else { break }
                session.serverLimits.maxBitrateK = bitrate / 1024
                session.serverLimits.maxDimension = dimension
                session.engine?.applyServerLimits(session.serverLimits)
            }
        }
    }

    /// Rebuilds participant → video from SFU slot bindings (a single peer needs no binding).
    private func bindSFUVideo(_ session: CallSession) {
        var videos: [Int64: CallVideoTrack] = [:]
        for (slot, track) in session.slotTrack {
            if let owner = session.slotOwner[slot] {
                videos[owner] = track
            } else if slot.hasPrefix("u"), let owner = Int64(slot.dropFirst()) {
                videos[owner] = track
            } else if !session.isGroup, let peer = session.remote {
                videos[peer.id] = track
            }
        }
        callRemoteVideos = videos
    }

    private func clearSFUVideo(_ session: CallSession) {
        session.slotOwner.removeAll()
        session.slotTrack.removeAll()
        session.requestedLayouts.removeAll()
        callRemoteVideos = [:]
    }

    // MARK: - Engines

    private var currentMediaSettings: JSONValue {
        var m = OKCalls.mediaSettings(audio: !activeCall.isMuted, video: activeCall.cameraEnabled || activeCall.sharingScreen)
        if activeCall.sharingScreen, case .object(var o) = m {
            o["isScreenSharingEnabled"] = .bool(true)
            m = .object(o)
        }
        return m
    }

    /// macOS: share the screen instead of the camera (official DIRECT behaviour). Through the SFU it
    /// travels in our camera slot — official clients show it as our video.
    func toggleScreenShare() async {
        guard let session = callSession, let engine = session.engine else { return }
        if activeCall.sharingScreen {
            await engine.stopScreenShare(resumeCamera: activeCall.cameraEnabled)
            activeCall.sharingScreen = false
            callLocalVideo = activeCall.cameraEnabled ? engine.localVideoTrack : nil
        } else {
            #if os(macOS)
            // Without Screen Recording access the capturer replaces the camera with nothing and the picture freezes:
            // ask first and leave the call untouched when it is not granted yet.
            guard PermissionsCenter.shared.state(.screen) == .granted || CGPreflightScreenCaptureAccess() else {
                _ = await PermissionsCenter.shared.request(.screen)
                PermissionsCenter.shared.alert = .screen
                return
            }
            guard await engine.startScreenShare() else {
                errorBanner = "Не удалось начать демонстрацию экрана. Разрешите запись экрана в Системных настройках → Конфиденциальность."
                return
            }
            activeCall.sharingScreen = true
            callLocalVideo = engine.localVideoTrack
            #else
            errorBanner = "Демонстрация экрана на iPhone/iPad пока недоступна"
            return
            #endif
        }
        announceMediaSettings(session)
    }

    private func announceMediaSettings(_ session: CallSession) {
        let settings = currentMediaSettings
        Task { _ = try? await session.signaling.send("change-media-settings", ["mediaSettings": settings], needResponse: false) }
    }

    /// Adds mic + (disabled) video track, then starts the camera if it should be on.
    private func prepareLocalMedia(_ engine: WebRTCCallEngine) async {
        engine.addLocalMedia()
        engine.setMicrophoneEnabled(!activeCall.isMuted)
        if activeCall.cameraEnabled {
            let ok = await engine.setCameraEnabled(true)
            activeCall.cameraEnabled = ok
            if !ok { activeCall.statusMessage = "Камера недоступна — продолжаем голосом" }
        }
        callLocalVideo = activeCall.cameraEnabled ? engine.localVideoTrack : nil
    }

    private func makeEngine(for session: CallSession, mode: WebRTCCallEngine.Mode) -> WebRTCCallEngine {
        if mode == .direct, let e = session.direct { return e }
        if mode == .server, let e = session.server { return e }
        let engine = WebRTCCallEngine(iceServers: session.params.iceServers, mode: mode)
        if mode == .direct { session.direct = engine } else { session.server = engine }

        engine.onRemoteVideoStream = { [weak self] streamId, track in
            Task { @MainActor in
                guard let self, self.callSession === session else { return }
                if mode == .direct {
                    if let peer = session.remote { self.callRemoteVideos[peer.id] = track }
                } else {
                    session.slotTrack[streamId] = track
                    self.bindSFUVideo(session)
                }
            }
        }
        engine.onRemoteStreamRemoved = { [weak self] streamId in
            Task { @MainActor in
                guard let self, self.callSession === session, mode == .server else { return }
                session.slotTrack[streamId] = nil
                self.bindSFUVideo(session)
            }
        }
        engine.onServerNotification = { [weak self] data in
            Task { @MainActor in
                guard let self, self.callSession === session else { return }
                self.handleSFUFrame(data, session: session)
            }
        }
        engine.onLocalDescription = { [weak self] type, sdp in
            Task { @MainActor in
                guard let self, self.callSession === session, mode == .direct else { return }
                if type == "offer" { session.localOffer = sdp }
                self.sendSDP(session, type: type, sdp: sdp)
            }
        }
        engine.onLocalCandidate = { [weak self] c in
            Task { @MainActor in
                // The SFU learns our address from ICE checks; candidates are trickled only peer-to-peer.
                guard let self, self.callSession === session, mode == .direct, let remote = session.remote else { return }
                var cand: [String: JSONValue] = ["candidate": .string(c.candidate), "sdpMLineIndex": .int(Int64(c.sdpMLineIndex))]
                if let mid = c.sdpMid { cand["sdpMid"] = .string(mid) }
                var params = remote.commandFields
                params["data"] = .object(["candidate": .object(cand)])
                _ = try? await session.signaling.send("transmit-data", params, needResponse: false)
            }
        }
        engine.onStateChange = { [weak self] state in
            Task { @MainActor in
                guard let self, self.callSession === session, session.engine === engine else { return }
                self.mediaStateChanged(state, session: session, engine: engine)
            }
        }
        return engine
    }

    private func mediaStateChanged(_ state: WebRTCCallEngine.State, session: CallSession, engine: WebRTCCallEngine) {
        switch state {
        case .connected:
            session.mediaConnected = true
            session.connectWatch?.cancel()
            session.iceRestartWatch?.cancel()
            activeCall.phase = .active
            activeCall.statusMessage = nil
            if activeCall.startedAt == nil { activeCall.startedAt = Date() }
            CallKitBridge.shared.reportConnected(session.conversationId)
            engine.applyServerLimits(session.serverLimits)
            if engine.mode == .direct && !engine.isEncrypted { announceE2E(session) }
            if session.adaptTask == nil {
                session.adaptTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        guard let self, self.callSession === session else { return }
                        await session.engine?.adaptToNetwork()
                    }
                }
            }
            #if os(iOS)
            CallDevices.setSpeaker(activeCall.speakerOn) // the route resets when CallKit activates audio
            #endif
        case .reconnecting, .failed:
            activeCall.statusMessage = "Переподключение…"
            if engine.mode == .server {
                // SFU connection lost: ask for a fresh allocation.
                Task { _ = try? await session.signaling.send("request-realloc") }
                return
            }
            if !session.mediaConnected {
                requestServerTopology(session, reason: "не удалось соединиться напрямую")
                return
            }
            // Was connected: the master restarts ICE; if that fails for 20 s, fall back to SERVER.
            if session.isMaster {
                Task { try? await engine.createOffer(iceRestart: true) }
            }
            session.iceRestartWatch?.cancel()
            session.iceRestartWatch = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled, let self, self.callSession === session, session.topology == "DIRECT" else { return }
                self.requestServerTopology(session, reason: "ICE restart не помог за 20 с")
            }
        default:
            break
        }
    }

    private func sendSDP(_ session: CallSession, type: String, sdp: String) {
        Task { [weak self] in
            // The SDK retries SDP delivery (up to 10 times) — the peer may not be connected yet.
            for attempt in 0..<10 {
                guard let self, self.callSession === session, let remote = session.remote else {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                var params = remote.commandFields
                params["data"] = .object([
                    "sdp": .object(["type": .string(type), "sdp": .string(sdp)]),
                    "animojiVersion": .int(1),
                ])
                do {
                    try await session.signaling.send("transmit-data", params)
                    return
                } catch {
                    Self.callLog("transmit-data \(type) attempt \(attempt + 1) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
        }
    }

    // MARK: - Ending

    private func hangupCall(reason: String) async {
        guard let session = callSession else { return }
        session.ended = true
        _ = try? await session.signaling.send("hangup", ["reason": .string(reason)], needResponse: false)
        endCall(message: reason == "REJECTED" ? "Звонок отклонён" : "Звонок завершён")
    }

    func endCall(message: String?) {
        if let session = callSession {
            session.ended = true
            session.cancelTimers()
            session.eventsTask?.cancel()
            closeEngine(&session.direct)
            closeEngine(&session.server)
            let signaling = session.signaling
            Task { await signaling.close() }
            CallKitBridge.shared.reportEnded(session.conversationId)
            callSession = nil
        }
        callLocalVideo = nil
        callRemoteVideos = [:]
        NotificationService.shared.clearCallNotifications()
        guard activeCall.phase != .idle else { return }
        activeCall.phase = .ended
        activeCall.statusMessage = message
        let ended = activeCall
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.activeCall == ended else { return }
            self.activeCall = ActiveCallState()
        }
    }

    // MARK: - Calls-platform identity

    /// Our user id on the calls platform — needed in the incoming signaling URL. Obtained exactly
    /// like the official client does at start-up (CallsAuthManager.ensureAuthenticated):
    /// Max op 158 → calls token → `auth.anonymLogin` on the calls API → `uid`. The reply's
    /// `external_user_id` must be our Max user id (the official client checks the same).
    /// Called right after login, so the very first incoming call already works.
    func prepareCalls() async {
        _ = await resolveCallsUserId(forceRefresh: false)
    }

    private func resolveCallsUserId(forceRefresh: Bool = false) async -> Int64? {
        if !forceRefresh, let uid = cachedCallsUserId { return uid }
        guard let token = try? await client.callsToken() else {
            Self.callLog("calls token (op 158) unavailable")
            return cachedCallsUserId
        }
        let configured = await client.serverConfigString("calls-endpoint").flatMap { $0.isEmpty ? nil : $0 }
        // calls.okcdn.ru is the platform the web app key is valid on (api.mycdn.me rejects it).
        var bases = [OKCalls.defaultApiBase]
        if let configured, configured != OKCalls.defaultApiBase { bases.insert(configured, at: 0) }
        for base in bases {
            do {
                let login = try await Self.anonymLogin(base: base, authToken: token)
                if let mine = currentAccount?.userId, let ext = login.externalUserId, ext != String(mine) {
                    Self.callLog("anonymLogin returned a foreign external id — ignored")
                    continue
                }
                cachedCallsUserId = login.uid
                return login.uid
            } catch {
                Self.callLog("anonymLogin via \(base) failed: \(error.localizedDescription)")
            }
        }
        return cachedCallsUserId
    }

    private static func anonymLogin(base: String, authToken: String) async throws -> (uid: Int64, externalUserId: String?) {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: "\(trimmed)/fb.do") else { throw CallParamsError.malformed("calls-endpoint") }
        let sessionData: JSONValue = .object([
            "version": .int(3),
            "device_id": .string(callsDeviceId),
            "client_version": .double(1.1),
            "client_type": .string("SDK_JS"),
            "auth_token": .string(authToken),
        ])
        let sd = String(decoding: try JSONEncoder().encode(sessionData), as: UTF8.self)
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        let body = "session_data=\(enc(sd))&application_key=\(OKCalls.webAppKey)&method=auth.anonymLogin&format=JSON"
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        let (data, _) = try await MediaHTTP.session.data(for: req)
        let resp = try JSONDecoder().decode(JSONValue.self, from: data)
        return try CallParamsCodec.parseAnonymLogin(resp)
    }

    // MARK: - Helpers

    static func requestMicrophone() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
        #endif
    }

    static func requestCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    static func describeHangup(_ reason: String?) -> String {
        switch reason {
        case "REJECTED", "CALLER_IS_REJECTED": return "Звонок отклонён"
        case "BUSY", "HAS_ACTIVE_CALL": return "Абонент занят"
        case "MISSED", "CALL_TIMEOUT", "TIMEOUT": return "Нет ответа"
        case "CALLEE_IS_OFFLINE", "CALLEE_UNAVAILABLE": return "Абонент недоступен"
        case "CALLER_IS_BLOCKED": return "Вы в чёрном списке абонента"
        case "NOT_FRIENDS": return "Абонент принимает звонки только от контактов"
        case "ANOTHER_DEVICE": return "Принят на другом устройстве"
        case "PARTICIPANT_LIMIT_REACHED": return "В звонке нет мест"
        case "CANCELED": return "Звонок отменён"
        default: return "Звонок завершён"
        }
    }

    static let callsAppVersion = "26.11.9"

    static var callsDeviceId: String {
        let key = "rmsmax.calls.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    /// Our id on the calls platform, remembered per Max account.
    internal var cachedCallsUserId: Int64? {
        get {
            guard let key = callsUidKey else { return nil }
            return (UserDefaults.standard.object(forKey: key) as? NSNumber)?.int64Value
        }
        set {
            guard let key = callsUidKey else { return }
            UserDefaults.standard.set(newValue.map { NSNumber(value: $0) }, forKey: key)
        }
    }

    private var callsUidKey: String? {
        currentAccount.map { "rmsmax.calls.uid.\($0.id)" }
    }

    static let callLog: @Sendable (String) -> Void = { line in
        #if DEBUG
        print("[calls] \(line)")
        #endif
    }
}
