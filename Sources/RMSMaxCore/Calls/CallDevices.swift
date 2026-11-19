import Foundation
import AVFoundation
@preconcurrency import LiveKitWebRTC

/// A selectable camera, microphone or speaker.
public struct CallDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let isDefault: Bool
}

/// Device choice for calls. Cameras come from AVFoundation; on macOS microphones and speakers are
/// switched inside WebRTC's audio device module (LiveKit ADM) without touching system defaults.
/// On iOS audio routing (speaker, Bluetooth, AirPods) goes through AVAudioSession / the route picker.
@MainActor
public enum CallDevices {
    private nonisolated static let cameraKey = "rmsmax.calls.cameraId"

    public nonisolated static var preferredCameraId: String? {
        get { UserDefaults.standard.string(forKey: cameraKey) }
        set { UserDefaults.standard.set(newValue, forKey: cameraKey) }
    }

    public static func cameras() -> [CallDevice] {
        RTCCameraVideoCapturer.captureDevices().map {
            CallDevice(id: $0.uniqueID, name: $0.localizedName, isDefault: $0.uniqueID == preferredCameraId)
        }
    }

    #if os(macOS)
    private static var adm: RTCAudioDeviceModule { WebRTCCallEngine.sharedFactory.audioDeviceModule }

    public static func microphones() -> [CallDevice] {
        let current = adm.inputDevice.deviceId
        return adm.inputDevices.map { CallDevice(id: $0.deviceId, name: $0.name, isDefault: $0.deviceId == current) }
    }

    public static func speakers() -> [CallDevice] {
        let current = adm.outputDevice.deviceId
        return adm.outputDevices.map { CallDevice(id: $0.deviceId, name: $0.name, isDefault: $0.deviceId == current) }
    }

    public static func selectMicrophone(_ id: String) {
        if let d = adm.inputDevices.first(where: { $0.deviceId == id }) { adm.inputDevice = d }
    }

    public static func selectSpeaker(_ id: String) {
        if let d = adm.outputDevices.first(where: { $0.deviceId == id }) { adm.outputDevice = d }
    }
    #endif

    #if os(iOS)
    /// Loudspeaker on/off (earpiece otherwise; Bluetooth/AirPods via the system route picker).
    public static func setSpeaker(_ on: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        try? session.overrideOutputAudioPort(on ? .speaker : .none)
    }
    #endif
}
