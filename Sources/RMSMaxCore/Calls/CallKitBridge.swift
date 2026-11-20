// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
#if os(iOS)
import CallKit
import AVFoundation
@preconcurrency import LiveKitWebRTC
#endif

/// System call UI on iOS (CallKit): incoming-call screen, lock screen controls, audio routing and
/// interruption handling. WebRTC audio runs in manual mode and starts only when CallKit activates
/// the audio session — the combination Apple requires for VoIP apps. No-op on macOS.
///
/// Note: without PushKit (which needs an App Store/APNs VoIP certificate) iOS delivers incoming
/// calls only while the app is running; CallKit then shows the native ringing screen.
@MainActor
public final class CallKitBridge: NSObject {
    public static let shared = CallKitBridge()

    /// Wired by the app: user actions coming from the system UI.
    public var onAnswer: ((_ conversationId: String) -> Void)?
    public var onEnd: ((_ conversationId: String) -> Void)?
    public var onMute: ((_ conversationId: String, _ muted: Bool) -> Void)?

    #if os(iOS)
    private let provider: CXProvider
    private let controller = CXCallController()
    private var uuids: [String: UUID] = [:]
    private var reportedMuted: [String: Bool] = [:]

    override init() {
        let config = CXProviderConfiguration()
        config.supportsVideo = true
        config.maximumCallsPerCallGroup = 1
        config.maximumCallGroups = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = false // keep call history out of the system Phone app
        provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }

    private func uuid(for id: String) -> UUID {
        if let u = uuids[id] { return u }
        let u = UUID()
        uuids[id] = u
        return u
    }

    private func conversation(for uuid: UUID) -> String? {
        uuids.first(where: { $0.value == uuid })?.key
    }

    public func reportIncoming(_ id: String, caller: String, isVideo: Bool) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = isVideo
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportNewIncomingCall(with: uuid(for: id), update: update) { error in
            if let error { print("[calls] CallKit incoming failed: \(error.localizedDescription)") }
        }
    }

    public func reportOutgoing(_ id: String, to name: String, isVideo: Bool) {
        let action = CXStartCallAction(call: uuid(for: id), handle: CXHandle(type: .generic, value: name))
        action.isVideo = isVideo
        controller.request(CXTransaction(action: action)) { _ in }
    }

    public func reportConnecting(_ id: String) {
        guard let u = uuids[id] else { return }
        provider.reportOutgoingCall(with: u, startedConnectingAt: nil)
    }

    public func reportConnected(_ id: String) {
        guard let u = uuids[id] else { return }
        provider.reportOutgoingCall(with: u, connectedAt: nil)
    }

    public func reportMuted(_ id: String, _ muted: Bool) {
        guard let u = uuids[id], reportedMuted[id] != muted else { return }
        reportedMuted[id] = muted
        controller.request(CXTransaction(action: CXSetMutedCallAction(call: u, muted: muted))) { _ in }
    }

    public func reportEnded(_ id: String) {
        guard let u = uuids.removeValue(forKey: id) else { return }
        reportedMuted[id] = nil
        provider.reportCall(with: u, endedAt: nil, reason: .remoteEnded)
    }
    #else
    public func reportIncoming(_ id: String, caller: String, isVideo: Bool) {}
    public func reportOutgoing(_ id: String, to name: String, isVideo: Bool) {}
    public func reportConnecting(_ id: String) {}
    public func reportConnected(_ id: String) {}
    public func reportMuted(_ id: String, _ muted: Bool) {}
    public func reportEnded(_ id: String) {}
    #endif
}

#if os(iOS)
extension CallKitBridge: CXProviderDelegate {
    nonisolated public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            for id in self.uuids.keys { self.onEnd?(id) }
            self.uuids.removeAll()
        }
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuid = action.callUUID
        Task { @MainActor in
            if let id = self.conversation(for: uuid) { self.onAnswer?(id) }
        }
        action.fulfill()
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid = action.callUUID
        Task { @MainActor in
            if let id = self.conversation(for: uuid) {
                self.uuids[id] = nil
                self.onEnd?(id)
            }
        }
        action.fulfill()
    }

    nonisolated public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let uuid = action.callUUID
        let muted = action.isMuted
        Task { @MainActor in
            if let id = self.conversation(for: uuid), self.reportedMuted[id] != muted {
                self.reportedMuted[id] = muted
                self.onMute?(id, muted)
            }
        }
        action.fulfill()
    }

    nonisolated public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(audioSession)
        rtc.isAudioEnabled = true
    }

    nonisolated public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(audioSession)
    }
}
#endif
