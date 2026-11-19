import XCTest
import CoreVideo
@preconcurrency import LiveKitWebRTC
@testable import RMSMaxCore

final class CallsTests: XCTestCase {
    /// Literal-only LZ4 block (valid per spec) — enough to produce a `vcp` like the server's.
    private func lz4Literals(_ data: Data) -> Data {
        var out = Data()
        let n = data.count
        if n < 15 {
            out.append(UInt8(n << 4))
        } else {
            out.append(0xF0)
            var rest = n - 15
            while rest >= 255 { out.append(255); rest -= 255 }
            out.append(UInt8(rest))
        }
        out.append(data)
        return out
    }

    func testDecodeIncomingVCP() throws {
        let json = #"{"srcp":"MAX","stne":"stun:a.example:3478,stun:b.example:3478","tkn":"T0K+en/=","trne":"turn:t.example:3478","trnp":"secret","trnu":"user","wse":"wss://sig.example/ws","wte":""}"#
        let raw = Data(json.utf8)
        let vcp = "\(raw.count):\(lz4Literals(raw).base64EncodedString())"
        let p = try CallParamsCodec.decodeVCP(vcp)
        XCTAssertEqual(p.endpoint, "wss://sig.example/ws")
        XCTAssertEqual(p.token, "T0K+en/=")
        XCTAssertEqual(p.clientType, "MAX")
        XCTAssertEqual(p.iceServers, [
            CallIceServer(urls: ["stun:a.example:3478", "stun:b.example:3478"]),
            CallIceServer(urls: ["turn:t.example:3478", "turn:t.example:3478?transport=tcp"], username: "user", credential: "secret"),
        ])
        XCTAssertThrowsError(try CallParamsCodec.decodeVCP("garbage"))
    }

    func testParseOutgoingInternalCallerParams() throws {
        let json = #"{"endpoint":"wss://sig.example/ws?userId=42&token=abc&conversationId=c1","isConcurrent":false,"clientType":"MAX","stun":{"urls":["stun:s:3478"," stun:s:3478 "]},"turn":{"urls":["turn:t:3478"],"username":"u","credential":"p"}}"#
        let p = try CallParamsCodec.parseInternalCallerParams(json)
        XCTAssertEqual(p.token, "abc")
        XCTAssertEqual(p.iceServers.first?.urls, ["stun:s:3478"])
        XCTAssertEqual(p.iceServers.last?.urls.last, "turn:t:3478?transport=tcp")
        XCTAssertEqual(CallParamsCodec.userId(inEndpoint: p.endpoint), 42)
        XCTAssertThrowsError(try CallParamsCodec.parseInternalCallerParams(#"{"endpoint":"wss://x"}"#))
    }

    func testSignalingURLMatchesOfficialSDK() throws {
        let incoming = try CallParamsCodec.signalingURL(
            endpoint: "wss://sig.example/ws",
            connectionType: .accept,
            appVersion: "26.11.9",
            clientType: "MAX",
            incoming: (userId: 777, conversationId: "conv-1", token: "a+b/c=")
        )
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: incoming, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["userId"], "777")
        XCTAssertEqual(q["entityType"], "USER")
        XCTAssertEqual(q["deviceIdx"], "0")
        XCTAssertEqual(q["conversationId"], "conv-1")
        XCTAssertEqual(q["token"], "a+b/c=")
        XCTAssertEqual(q["tgt"], "accept")
        XCTAssertEqual(q["version"], "5")
        XCTAssertEqual(q["platform"], "WEB")
        XCTAssertEqual(q["clientType"], "MAX")
        XCTAssertEqual(q["capabilities"], "3D")
        XCTAssertTrue(incoming.absoluteString.contains("token=a%2Bb"), "plus must be escaped")

        let outgoing = try CallParamsCodec.signalingURL(
            endpoint: "wss://sig.example/ws?userId=42&token=abc",
            connectionType: .start, appVersion: "1", clientType: nil
        )
        let oq = URLComponents(url: outgoing, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(oq.filter { $0.name == "token" }.map(\.value), ["abc"])
        XCTAssertEqual(oq.first { $0.name == "tgt" }?.value, "start")
        XCTAssertEqual(oq.first { $0.name == "clientType" }?.value, "PORTAL")
    }

    func testParticipantRefs() {
        let p = CallParticipantRef(participant: .object(["id": .int(5), "idType": .string("USER"), "deviceIdx": .int(2)]))
        XCTAssertEqual(p, CallParticipantRef(id: 5, deviceIdx: 2))
        XCTAssertEqual(p?.commandFields["deviceIdx"], .int(2))
        let m = CallParticipantRef(message: .object(["participantId": .string("9"), "participantType": .string("USER")]))
        XCTAssertEqual(m, CallParticipantRef(id: 9))
        XCTAssertNil(m?.commandFields["deviceIdx"])
    }

    func testSDPPatcherDropsLegacyAudioCodecs() {
        let sdp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111 9 0 8 13 126",
            "a=rtpmap:111 opus/48000/2",
            "a=rtcp-fb:111 transport-cc",
            "a=fmtp:111 minptime=10;useinbandfec=1",
            "a=rtpmap:9 G722/8000",
            "a=rtpmap:0 PCMU/8000",
            "a=rtpmap:8 PCMA/8000",
            "a=rtpmap:13 CN/8000",
            "a=rtpmap:126 telephone-event/8000",
            "",
        ].joined(separator: "\r\n")
        let out = SDPPatcher.patch(sdp)
        XCTAssertTrue(out.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"))
        XCTAssertTrue(out.contains("a=rtpmap:111 opus/48000/2"))
        XCTAssertTrue(out.contains("a=fmtp:111"))
        for gone in ["G722", "PCMU", "PCMA", "CN/8000", "telephone-event"] { XCTAssertFalse(out.contains(gone), gone) }
    }

    func testMediaSettingsShape() {
        let m = OKCalls.mediaSettings(audio: true, video: false)
        XCTAssertEqual(m["isAudioEnabled"], .bool(true))
        XCTAssertEqual(m["isVideoEnabled"], .bool(false))
        XCTAssertEqual(m.objectValue?.count, 6)
    }

    /// Two real WebRTC peer connections negotiate through our offer/answer/candidate plumbing
    /// and reach `connected` over loopback — no network, no microphone.
    func testWebRTCEnginesConnectOverLoopback() async throws {
        let caller = WebRTCCallEngine(iceServers: [])
        let callee = WebRTCCallEngine(iceServers: [])
        let connected = expectation(description: "both connected")
        connected.expectedFulfillmentCount = 2
        let flags = ConnectedFlags()

        caller.onLocalDescription = { type, sdp in
            Task { try? await callee.setRemoteDescription(type: type, sdp: sdp) }
        }
        callee.onLocalDescription = { type, sdp in
            Task { try? await caller.setRemoteDescription(type: type, sdp: sdp) }
        }
        caller.onLocalCandidate = { c in
            Task { await callee.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) }
        }
        callee.onLocalCandidate = { c in
            Task { await caller.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) }
        }
        caller.onStateChange = { s in if s == .connected, flags.mark(0) { connected.fulfill() } }
        callee.onStateChange = { s in if s == .connected, flags.mark(1) { connected.fulfill() } }

        try await caller.createOffer()
        await fulfillment(of: [connected], timeout: 20)
        caller.close()
        callee.close()
    }
}

extension CallsTests {
    /// Video end to end: synthetic camera frames go through H.264/VP8 encode → DTLS-SRTP → decode
    /// on the other engine, which must report the remote track and render decoded frames.
    func testVideoFramesFlowBetweenEngines() async throws {
        let caller = WebRTCCallEngine(iceServers: [])
        let callee = WebRTCCallEngine(iceServers: [])
        caller.addLocalMedia(audio: false)
        callee.addLocalMedia(audio: false)

        let counter = FrameCounter()
        let gotFrames = expectation(description: "decoded remote frames")
        counter.onFrames = { n in if n == 5 { gotFrames.fulfill() } }
        // The ObjC track wrapper owns its renderers — keep it alive, as AppStore.callRemoteVideo does.
        callee.onRemoteVideoTrack = { track in counter.hold(track); track.track.add(counter) }

        caller.onLocalDescription = { t, sdp in Task { try? await callee.setRemoteDescription(type: t, sdp: sdp) } }
        callee.onLocalDescription = { t, sdp in Task { try? await caller.setRemoteDescription(type: t, sdp: sdp) } }
        caller.onLocalCandidate = { c in Task { await callee.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }
        callee.onLocalCandidate = { c in Task { await caller.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }

        try await caller.createOffer()
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer)
        let pixels = try XCTUnwrap(buffer)
        let pump = Task {
            var t: Int64 = 0
            while !Task.isCancelled {
                caller.pushFrame(pixels, timeNs: t)
                t += 33_000_000
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        await fulfillment(of: [gotFrames], timeout: 20)
        pump.cancel()
        XCTAssertEqual(counter.lastSize, CGSize(width: 320, height: 240))
        let stats = await callee.statsSummary()
        XCTAssertTrue(stats.contains("inbound-rtp[kind=video"), stats)
        caller.close()
        callee.close()
    }
}

private final class FrameCounter: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var lastSize = CGSize.zero
    var onFrames: ((Int) -> Void)?
    private var held: CallVideoTrack?
    func hold(_ t: CallVideoTrack) { lock.lock(); held = t; lock.unlock() }
    func setSize(_ size: CGSize) { lastSize = size }
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); count += 1; let n = count; lastSize = CGSize(width: Int(frame.width), height: Int(frame.height)); lock.unlock()
        onFrames?(n)
    }
}

private final class ConnectedFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<Int>()
    func mark(_ i: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seen.insert(i).inserted
    }
}

extension CallsTests {
    func testParseAnonymLogin() throws {
        let ok = try CallParamsCodec.parseAnonymLogin(.object([
            "uid": .string("910000000001"), "session_key": .string("s"), "external_user_id": .string("12345"),
        ]))
        XCTAssertEqual(ok.uid, 910000000001)
        XCTAssertEqual(ok.externalUserId, "12345")
        // Real server reply to a bad token (probed against calls.okcdn.ru/fb.do).
        XCTAssertThrowsError(try CallParamsCodec.parseAnonymLogin(.object([
            "error_code": .int(401), "error_msg": .string("AUTH_LOGIN : Access token is broken"), "error_data": .null,
        ])))
    }
}

// MARK: - SERVER topology (SFU) and reconnect

extension CallsTests {
    func testStreamDescriptionsAndLayoutKeys() {
        let d = SFUStreamDescription("u42:d1:sCAMERA:mmain")
        XCTAssertEqual(d?.participant, CallParticipantRef(id: 42, deviceIdx: 1))
        XCTAssertEqual(d?.mediaType, "CAMERA")
        XCTAssertEqual(SFUStreamDescription("g7")?.participant.type, "GROUP")
        XCTAssertNil(SFUStreamDescription("x1"))
        XCTAssertNil(SFUStreamDescription("u5:q1"))
        XCTAssertEqual(SFUStreamDescription.layoutKey(CallParticipantRef(id: 42)), "u42:sCAMERA")
        XCTAssertEqual(SFUStreamDescription.layoutKey(CallParticipantRef(id: 42, deviceIdx: 2)), "u42:d2:sCAMERA")
    }

    func testSFUNotificationDecoderBindsPooledTracks() throws {
        let decoder = SFUNotificationDecoder()
        var registry = Data([1])
        registry.append(try MsgPack.encode(.object(["u5:sCAMERA": .int(3), "u9": .int(4)])))
        XCTAssertEqual(decoder.decode(registry), [])

        var bind = Data([7])
        bind.append(try MsgPack.encode(.object([
            "0": .array([.int(3), .int(123), .int(1), .bool(false), .null]),
            "1": .array([.null, .null, .int(2), .bool(false), .null]),
        ])))
        XCTAssertEqual(decoder.decode(bind), [
            .trackBound(streamId: "pat-0", participant: CallParticipantRef(id: 5), mediaType: "CAMERA"),
            .trackBound(streamId: "pat-1", participant: nil, mediaType: nil),
        ])

        var speaker = Data([3])
        speaker.append(try MsgPack.encode(.int(4)))
        XCTAssertEqual(decoder.decode(speaker), [.speaker(CallParticipantRef(id: 9))])
        XCTAssertEqual(decoder.decode(Data([99, 0xc0])), [])
    }

    func testAcceptedSSRCsFromServerOffer() {
        let sdp = [
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=ssrc:1001 label:audio-mix",
            "a=ssrc:1001 cname:x",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=ssrc:2002 label:video-pat-0",
            "a=ssrc:3003 label:video-u77",
            "a=ssrc:4004 label:something-else",
        ].joined(separator: "\r\n")
        XCTAssertEqual(SFUSDP.acceptedSSRCs(in: sdp), ["1001", "2002", "3003"])
    }

    func testSignalingRetryURL() {
        let base = URL(string: "wss://sig.example/ws?userId=1&token=a%2Bb&tgt=start")!
        let retry = OKCallSignaling.retryURL(from: base, lastStamp: 777, peerId: 55)
        let q = Dictionary(uniqueKeysWithValues: URLComponents(url: retry, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["tgt"], "retry")
        XCTAssertEqual(q["recoverTs"], "777")
        XCTAssertEqual(q["peerId"], "55")
        XCTAssertEqual(q["token"], "a+b")
        XCTAssertTrue(retry.absoluteString.contains("token=a%2Bb"))
    }

    func testConsumerCapabilitiesMatchWhatWeImplement() {
        let c = OKCalls.consumerCapabilities()
        XCTAssertEqual(c["audioMix"], .bool(true))
        XCTAssertEqual(c["unifiedPlan"], .bool(true))
        XCTAssertEqual(c["singleSession"], .bool(true))
        XCTAssertEqual(c["simulcast"], .bool(false))
    }

    /// SERVER topology end to end: a stand-in "SFU" offers (as `producer-updated` would), our
    /// server-mode engine answers through `applyServerOffer`, and decoded video reaches us.
    func testServerModeAnswersSFUOfferAndReceivesVideo() async throws {
        let sfu = WebRTCCallEngine(iceServers: [])           // plays the platform's SFU
        let client = WebRTCCallEngine(iceServers: [], mode: .server)
        sfu.addLocalMedia(audio: false)
        client.addLocalMedia(audio: false)

        let counter = FrameCounter()
        let gotFrames = expectation(description: "video via server mode")
        counter.onFrames = { n in if n == 5 { gotFrames.fulfill() } }
        client.onRemoteVideoStream = { _, track in counter.hold(track); track.track.add(counter) }

        sfu.onLocalDescription = { type, sdp in
            guard type == "offer" else { return }
            Task {
                do {
                    let (answer, _) = try await client.applyServerOffer(sdp)
                    try await sfu.setRemoteDescription(type: "answer", sdp: answer)
                } catch { XCTFail("\(error)") }
            }
        }
        sfu.onLocalCandidate = { c in Task { await client.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }
        client.onLocalCandidate = { c in Task { await sfu.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }

        try await sfu.createOffer()
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer)
        let pixels = try XCTUnwrap(buffer)
        let pump = Task {
            var t: Int64 = 0
            while !Task.isCancelled {
                sfu.pushFrame(pixels, timeNs: t)
                t += 33_000_000
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        await fulfillment(of: [gotFrames], timeout: 20)
        pump.cancel()
        sfu.close()
        client.close()
    }
}

// MARK: - E2E calls (RMS ↔ RMS)

extension CallsTests {
    private func runEncryptedLoopback(callerKey: Data, calleeKey: Data, expectFrames: Bool) async throws {
        let caller = WebRTCCallEngine(iceServers: [])
        let callee = WebRTCCallEngine(iceServers: [])
        caller.addLocalMedia(audio: false)
        callee.addLocalMedia(audio: false)
        let counter = FrameCounter()
        let gotFrames = expectation(description: "frames")
        gotFrames.isInverted = !expectFrames
        counter.onFrames = { n in if n == 5 { gotFrames.fulfill() } }
        callee.onRemoteVideoTrack = { track in counter.hold(track); track.track.add(counter) }
        caller.onLocalDescription = { t, sdp in Task { try? await callee.setRemoteDescription(type: t, sdp: sdp) } }
        callee.onLocalDescription = { t, sdp in
            Task {
                try? await caller.setRemoteDescription(type: t, sdp: sdp)
                // Both sides switch encryption on once negotiated (as after the custom-data exchange).
                caller.enableE2E(key: callerKey, salt: Data("conv".utf8))
                callee.enableE2E(key: calleeKey, salt: Data("conv".utf8))
            }
        }
        caller.onLocalCandidate = { c in Task { await callee.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }
        callee.onLocalCandidate = { c in Task { await caller.addRemoteCandidate(candidate: c.candidate, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex) } }
        try await caller.createOffer()
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attrs, &buffer)
        let pixels = try XCTUnwrap(buffer)
        let pump = Task {
            var t: Int64 = 0
            while !Task.isCancelled {
                caller.pushFrame(pixels, timeNs: t)
                t += 33_000_000
                try? await Task.sleep(nanoseconds: 33_000_000)
            }
        }
        await fulfillment(of: [gotFrames], timeout: expectFrames ? 20 : 6)
        pump.cancel()
        XCTAssertTrue(caller.isEncrypted)
        caller.close()
        callee.close()
    }

    func testEncryptedCallWithMatchingKeysDeliversVideo() async throws {
        let key = AppStore.callMediaKey(sessionSecret: Data(repeating: 7, count: 32), conversationId: "conv")
        try await runEncryptedLoopback(callerKey: key, calleeKey: key, expectFrames: true)
    }

    func testEncryptedCallWithWrongKeyDeliversNothing() async throws {
        let a = AppStore.callMediaKey(sessionSecret: Data(repeating: 7, count: 32), conversationId: "conv")
        let b = AppStore.callMediaKey(sessionSecret: Data(repeating: 8, count: 32), conversationId: "conv")
        try await runEncryptedLoopback(callerKey: a, calleeKey: b, expectFrames: false)
    }

    func testCallKeyDerivationIsPerConversation() {
        let secret = Data(repeating: 1, count: 32)
        let k1 = AppStore.callMediaKey(sessionSecret: secret, conversationId: "a")
        let k2 = AppStore.callMediaKey(sessionSecret: secret, conversationId: "b")
        XCTAssertEqual(k1.count, 32)
        XCTAssertNotEqual(k1, k2)
        XCTAssertEqual(AppStore.callKeyCheck(k1), AppStore.callKeyCheck(k1))
        XCTAssertNotEqual(AppStore.callKeyCheck(k1), AppStore.callKeyCheck(k2))
    }
}
