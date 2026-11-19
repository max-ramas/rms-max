import Foundation
import AVFoundation
#if os(macOS)
import AppKit
#endif
@preconcurrency import LiveKitWebRTC

/// One direct (peer-to-peer) media connection, mirroring the official SDK's DirectTransport:
/// the caller ("master") adds its tracks and offers right away; the callee adds tracks and
/// answers once the user accepts. ICE candidates are trickled through signaling.
public final class WebRTCCallEngine: NSObject, @unchecked Sendable {
    /// `.direct`: peer-to-peer with the other participant (SDK DirectTransport).
    /// `.server`: one connection to the platform's SFU (SDK ServerTransport): the server offers,
    /// we answer via `accept-producer`; remote media arrive as an audio mix plus on-demand video tracks.
    public enum Mode: Sendable { case direct, server }

    public enum State: String, Sendable {
        case new, connecting, connected, reconnecting, failed, closed
    }

    public struct LocalCandidate: Sendable {
        public let candidate: String
        public let sdpMid: String?
        public let sdpMLineIndex: Int32
    }

    public var onLocalDescription: (@Sendable (_ type: String, _ sdp: String) -> Void)?
    public var onLocalCandidate: (@Sendable (LocalCandidate) -> Void)?
    public var onStateChange: (@Sendable (State) -> Void)?
    /// Fired when the peer's video track becomes available (frames flow once they enable a camera).
    public var onRemoteVideoTrack: (@Sendable (CallVideoTrack) -> Void)?
    /// Every remote video track with its stream id (SFU: "pat-N" pool slots or "u<id>").
    public var onRemoteVideoStream: (@Sendable (_ streamId: String, CallVideoTrack) -> Void)?
    public var onRemoteStreamRemoved: (@Sendable (_ streamId: String) -> Void)?
    /// Binary frames from the SFU's `producerNotification` data channel (MsgPack, type byte first).
    public var onServerNotification: (@Sendable (Data) -> Void)?

    public let mode: Mode
    private var dataChannels: [RTCDataChannel] = []
    private var serverOfferChain: Task<Void, Never>?

    private static let factory: RTCPeerConnectionFactory = {
        // WebRTC writes to sockets the peer may already have closed; without this the
        // default SIGPIPE action kills the whole app mid-call.
        signal(SIGPIPE, SIG_IGN)
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private let queue = DispatchQueue(label: "rms.max.webrtc")
    private var pc: RTCPeerConnection?
    private var audioTrack: RTCAudioTrack?
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var usingFrontCamera = true
    private var captureMaxSide: Int = 1280
    private var serverLimits = VideoLimits()
    private var networkMaxSide: Int = 1280
    private var remoteVideoReported = false
    #if os(macOS)
    private var desktopCapturer: RTCDesktopCapturer?
    #endif
    public private(set) var isSharingScreen = false
    private var keyProvider: RTCFrameCryptorKeyProvider?
    private var cryptors: [RTCFrameCryptor] = []
    public private(set) var isEncrypted = false
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemoteDescription = false
    private var lastRemoteSDP: String?
    private var tracksAdded = false

    public init(iceServers: [CallIceServer], mode: Mode = .direct) {
        self.mode = mode
        super.init()
        let config = RTCConfiguration()
        config.iceServers = iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        config.sdpSemantics = .unifiedPlan
        config.bundlePolicy = .maxBundle
        config.rtcpMuxPolicy = .require
        config.continualGatheringPolicy = .gatherContinually
        config.tcpCandidatePolicy = .enabled
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        pc = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
        if mode == .server, let pc {
            // Same labelled, ordered channels the official client opens towards the SFU.
            for label in ["producerNotification", "producerCommand", "producerScreenShare", "consumerScreenShare"] {
                let cfg = RTCDataChannelConfiguration()
                cfg.isOrdered = true
                if let dc = pc.dataChannel(forLabel: label, configuration: cfg) {
                    dc.delegate = self
                    dataChannels.append(dc)
                }
            }
        }
    }

    /// Microphone + camera tracks. Like the official client, a video track is always sent:
    /// while the camera is off it is disabled, and libwebrtc then emits black frames —
    /// turning the camera on later needs no renegotiation. WebRTC drives the audio session itself.
    public func addLocalMedia(audio: Bool = true) {
        guard let pc, !tracksAdded else { return }
        tracksAdded = true
        if audio {
            let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            let track = Self.factory.audioTrack(with: source, trackId: "audio0")
            pc.add(track, streamIds: ["stream0"])
            audioTrack = track
        }

        let vSource = Self.factory.videoSource()
        let vTrack = Self.factory.videoTrack(with: vSource, trackId: "video0")
        vTrack.isEnabled = false
        pc.add(vTrack, streamIds: ["stream0"])
        videoSource = vSource
        videoTrack = vTrack
    }

    public func setMicrophoneEnabled(_ enabled: Bool) {
        audioTrack.map { $0.isEnabled = enabled }
    }

    /// Local preview handle (nil until media is added).
    public var localVideoTrack: CallVideoTrack? {
        videoTrack.map(CallVideoTrack.init)
    }

    /// Starts or stops the camera. Returns false when no camera could be opened.
    @discardableResult
    public func setCameraEnabled(_ enabled: Bool) async -> Bool {
        guard let videoSource, let videoTrack else { return false }
        if !enabled {
            videoTrack.isEnabled = false
            if let capturer { await capturer.stopCapture() }
            capturer = nil
            return true
        }
        let cap = capturer ?? RTCCameraVideoCapturer(delegate: videoSource)
        guard let device = Self.pickCamera(front: usingFrontCamera),
              let format = Self.pickFormat(for: device)
        else { return false }
        let fps = Self.pickFps(for: format)
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        captureMaxSide = Int(max(dims.width, dims.height))
        do {
            try await cap.startCapture(with: device, format: format, fps: fps)
        } catch {
            return false
        }
        capturer = cap
        videoTrack.isEnabled = true
        return true
    }

    /// Test hook: feeds one frame into the local video track as if a camera produced it.
    func pushFrame(_ buffer: CVPixelBuffer, timeNs: Int64) {
        guard let videoSource, let videoTrack else { return }
        videoTrack.isEnabled = true
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: timeNs)
        videoSource.capturer(RTCVideoCapturer(delegate: videoSource), didCapture: frame)
    }

    /// Compact RTP counters for diagnostics (local only — never sent anywhere).
    public func statsSummary() async -> String {
        guard let pc else { return "closed" }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in
            pc.statistics { cont.resume(returning: $0) }
        }
        var parts: [String] = []
        for stat in report.statistics.values where stat.type == "outbound-rtp" || stat.type == "inbound-rtp" || stat.type == "media-source" {
            let v = stat.values
            let keys = ["kind", "framesEncoded", "framesSent", "bytesSent", "framesReceived", "framesDecoded", "bytesReceived", "frames", "qualityLimitationReason", "encoderImplementation", "decoderImplementation"]
            let fields = keys.compactMap { k in v[k].map { "\(k)=\($0)" } }
            parts.append("\(stat.type)[\(fields.joined(separator: " "))]")
        }
        return parts.sorted().joined(separator: "\n")
    }

    /// Screen sharing (macOS): the screen replaces the camera in our video track, as the official
    /// client does for DIRECT calls. macOS asks for Screen Recording permission on first use.
    @discardableResult
    public func startScreenShare() async -> Bool {
        #if os(macOS)
        guard let videoSource, let videoTrack else { return false }
        if let capturer { await capturer.stopCapture(); self.capturer = nil }
        let cap = RTCDesktopCapturer(defaultScreen: self, capture: videoSource)
        desktopCapturer = cap
        if let screen = NSScreen.main {
            let px = screen.frame.size.applying(.init(scaleX: screen.backingScaleFactor, y: screen.backingScaleFactor))
            captureMaxSide = Int(max(px.width, px.height))
        }
        cap.startCapture(withFPS: 15)
        videoTrack.isEnabled = true
        isSharingScreen = true
        applyVideoLimits()
        return true
        #else
        return false
        #endif
    }

    /// Stops sharing; the camera comes back if it was on.
    public func stopScreenShare(resumeCamera: Bool) async {
        #if os(macOS)
        if let d = desktopCapturer { await d.stopCapture() }
        desktopCapturer = nil
        #endif
        isSharingScreen = false
        if resumeCamera { await setCameraEnabled(true) } else { videoTrack?.isEnabled = false }
    }

    /// End-to-end media encryption (AES-GCM per frame, LiveKit FrameCryptor) with a key both
    /// RMS MAX sides derive from their chat's E2E session. Only works peer-to-peer: the SFU mixes
    /// audio, which needs plaintext, so the session never enables this in SERVER topology.
    public func enableE2E(key: Data, salt: Data) {
        guard let pc else { return }
        let provider = keyProvider ?? RTCFrameCryptorKeyProvider(
            ratchetSalt: salt,
            ratchetWindowSize: 0,
            sharedKeyMode: true,
            uncryptedMagicBytes: nil,
            failureTolerance: -1,
            keyRingSize: 16,
            discardFrameWhenCryptorNotReady: true,
            keyDerivationAlgorithm: .HKDF,
            keySize: 256
        )
        provider.setSharedKey(key, with: 0)
        keyProvider = provider
        if cryptors.isEmpty {
            for sender in pc.senders {
                if let c = RTCFrameCryptor(factory: Self.factory, rtpSender: sender, participantId: "local", algorithm: .aesGcm, keyProvider: provider) {
                    cryptors.append(c)
                }
            }
            for receiver in pc.receivers { attachDecryptor(receiver) }
        }
        cryptors.forEach { $0.keyIndex = 0; $0.enabled = true }
        isEncrypted = true
    }

    public func disableE2E() {
        cryptors.forEach { $0.enabled = false }
        isEncrypted = false
    }

    private func attachDecryptor(_ receiver: RTCRtpReceiver) {
        guard let provider = keyProvider,
              let c = RTCFrameCryptor(factory: Self.factory, rtpReceiver: receiver, participantId: "remote", algorithm: .aesGcm, keyProvider: provider)
        else { return }
        c.keyIndex = 0
        c.enabled = isEncrypted
        cryptors.append(c)
    }

    /// Front ↔ back (phones/iPads); a no-op where only one camera exists.
    public func switchCamera() async {
        guard capturer != nil else { return }
        usingFrontCamera.toggle()
        if Self.pickCamera(front: usingFrontCamera) == nil { usingFrontCamera.toggle(); return }
        await setCameraEnabled(true)
    }

    static func pickCamera(front: Bool) -> AVCaptureDevice? {
        let devices = RTCCameraVideoCapturer.captureDevices()
        if let id = CallDevices.preferredCameraId, let chosen = devices.first(where: { $0.uniqueID == id }) {
            #if os(iOS)
            if chosen.position == (front ? .front : .back) { return chosen }
            #else
            return chosen
            #endif
        }
        #if os(iOS)
        let wanted: AVCaptureDevice.Position = front ? .front : .back
        return devices.first(where: { $0.position == wanted }) ?? devices.first
        #else
        return devices.first
        #endif
    }

    /// Restarts the camera on the currently preferred device (after the user picks another one).
    public func reselectCamera() async {
        guard capturer != nil else { return }
        await setCameraEnabled(true)
    }

    static var sharedFactory: RTCPeerConnectionFactory { factory }

    /// Closest format to 1280×720 (the official client's default ceiling), preferring 30 fps.
    static func pickFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return abs(Int(d.width) - 1280) + abs(Int(d.height) - 720)
        }
        return formats.min(by: { score($0) < score($1) })
    }

    static func pickFps(for format: AVCaptureDevice.Format) -> Int {
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return Int(min(30, maxFps))
    }

    /// Caller side: offer (receiving audio and video like the official client does).
    /// `iceRestart` is what the master sends when the direct connection drops.
    public func createOffer(iceRestart: Bool = false) async throws {
        guard let pc else { throw CallSignalingError.closed }
        var mandatory = ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"]
        if iceRestart { mandatory["IceRestart"] = "true" }
        let constraints = RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: nil)
        let offer = try await pc.offer(for: constraints)
        let patched = RTCSessionDescription(type: .offer, sdp: SDPPatcher.patch(offer.sdp))
        try await pc.setLocalDescription(patched)
        onLocalDescription?("offer", patched.sdp)
    }

    /// Applies the peer's SDP; for an offer, answers it.
    public func setRemoteDescription(type: String, sdp: String) async throws {
        guard let pc else { throw CallSignalingError.closed }
        if lastRemoteSDP == sdp { return }
        lastRemoteSDP = sdp
        let kind: RTCSdpType = type == "offer" ? .offer : (type == "pranswer" ? .prAnswer : .answer)
        try await pc.setRemoteDescription(RTCSessionDescription(type: kind, sdp: SDPPatcher.patch(sdp)))
        let cached = queue.sync { () -> [RTCIceCandidate] in
            hasRemoteDescription = true
            defer { pendingCandidates.removeAll() }
            return pendingCandidates
        }
        for c in cached { try? await pc.add(c) }
        if kind == .offer {
            let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
            let patched = RTCSessionDescription(type: .answer, sdp: SDPPatcher.patch(answer.sdp))
            try await pc.setLocalDescription(patched)
            onLocalDescription?("answer", patched.sdp)
        }
    }

    public func addRemoteCandidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) async {
        guard let pc, !candidate.isEmpty else { return }
        let c = RTCIceCandidate(sdp: candidate, sdpMLineIndex: sdpMLineIndex, sdpMid: sdpMid)
        let ready = queue.sync { () -> Bool in
            if !hasRemoteDescription { pendingCandidates.append(c) }
            return hasRemoteDescription
        }
        if ready { try? await pc.add(c) }
    }

    public var connectionState: State {
        switch pc?.connectionState {
        case .connected?: return .connected
        case .connecting?: return .connecting
        case .disconnected?: return .reconnecting
        case .failed?: return .failed
        case .closed?, nil: return .closed
        default: return .new
        }
    }

    /// Upload limits for our camera: `settings-update` / `video-quality-update` from the platform
    /// (maxDimension 0 = stop uploading video) combined with our own network adaptation.
    public struct VideoLimits: Equatable, Sendable {
        public var maxDimension: Int?
        public var maxBitrateK: Int?
        public var maxFramerate: Int?
        public init(maxDimension: Int? = nil, maxBitrateK: Int? = nil, maxFramerate: Int? = nil) {
            self.maxDimension = maxDimension
            self.maxBitrateK = maxBitrateK
            self.maxFramerate = maxFramerate
        }
    }

    public func applyServerLimits(_ limits: VideoLimits) {
        serverLimits = limits
        applyVideoLimits()
    }

    /// Network adaptation (SDK DirectTransport): loss/RTT → 1280 / 640 / 320 px.
    public func adaptToNetwork() async {
        guard let pc, videoTrack?.isEnabled == true else { return }
        let report: RTCStatisticsReport = await withCheckedContinuation { cont in pc.statistics { cont.resume(returning: $0) } }
        var loss = 0.0, rtt = 0.0
        for stat in report.statistics.values where stat.type == "remote-inbound-rtp" && (stat.values["kind"] as? String) == "video" {
            loss = max(loss, ((stat.values["fractionLost"] as? NSNumber)?.doubleValue ?? 0) * 100)
            rtt = max(rtt, ((stat.values["roundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1000)
        }
        let side: Int
        if loss >= 10 || rtt >= 1500 { side = 320 }
        else if loss >= 4 || rtt >= 1000 { side = 640 }
        else if loss <= 2 && rtt <= 700 { side = 1280 }
        else { side = networkMaxSide }
        if side != networkMaxSide {
            networkMaxSide = side
            applyVideoLimits()
        }
    }

    private func applyVideoLimits() {
        guard let pc else { return }
        for sender in pc.senders where sender.track?.kind == "video" {
            let params = sender.parameters
            guard let enc = params.encodings.first else { continue }
            if serverLimits.maxDimension == 0 {
                enc.isActive = false
            } else {
                enc.isActive = true
                let target = min(serverLimits.maxDimension ?? 1280, networkMaxSide)
                enc.scaleResolutionDownBy = NSNumber(value: max(1.0, Double(captureMaxSide) / Double(max(target, 1))))
                enc.maxBitrateBps = serverLimits.maxBitrateK.map { NSNumber(value: $0 * 1000) }
                enc.maxFramerate = serverLimits.maxFramerate.map { NSNumber(value: $0) }
            }
            sender.parameters = params
        }
    }

    public func restartIce() {
        pc?.restartIce()
    }

    /// SFU offer (`producer-updated`) → our answer + the SSRCs we accept (for `accept-producer`).
    /// Offers are processed strictly one at a time, as in the SDK.
    public func applyServerOffer(_ sdp: String) async throws -> (answer: String, ssrcs: [String]) {
        let previous = serverOfferChain
        var result: Result<(String, [String]), Error> = .failure(CallSignalingError.closed)
        let task = Task { [weak self] in
            _ = await previous?.value
            guard let self, let pc = self.pc else { return }
            do {
                try await pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: SDPPatcher.patch(sdp)))
                let answer = try await pc.answer(for: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
                let patched = RTCSessionDescription(type: .answer, sdp: SDPPatcher.patch(answer.sdp))
                try await pc.setLocalDescription(patched)
                result = .success((patched.sdp, SFUSDP.acceptedSSRCs(in: sdp)))
            } catch {
                result = .failure(error)
            }
        }
        serverOfferChain = task
        await task.value
        let (answer, ssrcs) = try result.get()
        return (answer, ssrcs)
    }

    public func close() {
        cryptors.forEach { $0.enabled = false }
        cryptors.removeAll()
        #if os(macOS)
        desktopCapturer?.stopCapture()
        desktopCapturer = nil
        #endif
        serverOfferChain?.cancel()
        dataChannels.forEach { $0.delegate = nil; $0.close() }
        dataChannels.removeAll()
        audioTrack?.isEnabled = false
        videoTrack?.isEnabled = false
        capturer?.stopCapture()
        capturer = nil
        pc?.close()
        pc = nil
    }
}

extension WebRTCCallEngine: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd rtpReceiver: RTCRtpReceiver, streams mediaStreams: [RTCMediaStream]) {
        if keyProvider != nil { attachDecryptor(rtpReceiver) }
        if let video = rtpReceiver.track as? RTCVideoTrack {
            onRemoteVideoStream?(mediaStreams.first?.streamId ?? video.trackId, CallVideoTrack(video))
        }
        reportRemoteVideo(rtpReceiver.track)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove rtpReceiver: RTCRtpReceiver) {
        if let video = rtpReceiver.track as? RTCVideoTrack { onRemoteStreamRemoved?(video.trackId) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        reportRemoteVideo(transceiver.receiver.track)
    }

    private func reportRemoteVideo(_ track: RTCMediaStreamTrack?) {
        guard let video = track as? RTCVideoTrack else { return }
        let fire = queue.sync { () -> Bool in
            defer { remoteVideoReported = true }
            return !remoteVideoReported
        }
        if fire { onRemoteVideoTrack?(CallVideoTrack(video)) }
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let mapped: State
        switch newState {
        case .new: mapped = .new
        case .connecting: mapped = .connecting
        case .connected: mapped = .connected
        case .disconnected: mapped = .reconnecting
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: return
        }
        onStateChange?(mapped)
    }

    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalCandidate?(LocalCandidate(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex))
    }
}

#if os(macOS)
extension WebRTCCallEngine: RTCDesktopCapturerDelegate {
    public func didSourceCaptureStart(_ capturer: RTCDesktopCapturer) {}
    public func didSourceCapturePaused(_ capturer: RTCDesktopCapturer) {}
    public func didSourceCaptureStop(_ capturer: RTCDesktopCapturer) {}
    public func didSourceCaptureError(_ capturer: RTCDesktopCapturer) {}
}
#endif

extension WebRTCCallEngine: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}

    public func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard dataChannel.label == "producerNotification", buffer.isBinary else { return }
        onServerNotification?(buffer.data)
    }
}

/// SFU SDP helpers (SDK ServerTransport._updateSSRCMap).
enum SFUSDP {
    /// SSRCs labelled `audio|video-<u123|g123|mix|pat-N|ta-N>` in the server's offer.
    static func acceptedSSRCs(in sdp: String) -> [String] {
        let pattern = #"^a=ssrc:([0-9]+) label:(audio|video)-((?:[ug]?[0-9]+)|(?:mix)|(?:pat-[0-9]+)|(?:ta-[0-9]+))"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [String] = []
        for line in sdp.components(separatedBy: "\r\n") {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let ssrc = ns.substring(with: m.range(at: 1))
                if !out.contains(ssrc) { out.append(ssrc) }
            }
        }
        return out
    }
}

/// The official SDK strips these legacy audio codecs from every SDP it creates or applies.
enum SDPPatcher {
    static let removedAudioCodecs: Set<String> = ["G722", "PCMU", "PCMA", "CN", "telephone-event"]

    static func patch(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        var drop = Set<String>()
        for line in lines where line.hasPrefix("a=rtpmap:") {
            let rest = line.dropFirst("a=rtpmap:".count)
            let parts = rest.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let codec = parts[1].split(separator: "/").first else { continue }
            if removedAudioCodecs.contains(String(codec)) { drop.insert(String(parts[0])) }
        }
        guard !drop.isEmpty else { return sdp }
        var out: [String] = []
        for line in lines {
            if line.hasPrefix("m=audio ") {
                let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
                if f.count > 3 {
                    out.append((f[0..<3] + f[3...].filter { !drop.contains($0) }).joined(separator: " "))
                    continue
                }
            }
            if let pt = payloadType(of: line), drop.contains(pt) { continue }
            out.append(line)
        }
        return out.joined(separator: "\r\n")
    }

    private static func payloadType(of line: String) -> String? {
        for prefix in ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"] where line.hasPrefix(prefix) {
            return line.dropFirst(prefix.count).split(separator: " ").first.map(String.init)
        }
        return nil
    }
}
