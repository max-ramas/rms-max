import Foundation
#if os(iOS)
import AVFoundation
#endif

/// iOS only, opt-in: keeps the app (and its Max connection) alive in the background so incoming
/// calls still arrive and ring via CallKit.
///
/// Why not PushKit like the official app: Max's servers send VoIP pushes with *their* APNs
/// certificate to *their* bundle id — a third-party client can never receive them. What remains
/// on a sideloaded build is the `audio` background mode: we play inaudible silence (mixed with
/// other audio, so music is not interrupted). Costs some battery, hence off by default.
@MainActor
public final class BackgroundKeepAlive {
    public static let shared = BackgroundKeepAlive()
    public static let settingKey = "rmsmax.calls.backgroundKeepAlive"

    public static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: settingKey) }
        set { UserDefaults.standard.set(newValue, forKey: settingKey) }
    }

    #if os(iOS)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var interruptionObserver: NSObjectProtocol?

    public func appDidEnterBackground(callActive: Bool) {
        guard Self.isEnabled, !callActive, engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
            buffer.frameLength = 8000 // one second of zeros, looped
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            self.engine = engine
            self.player = player
            interruptionObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
            ) { [weak self] note in
                guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
                Task { @MainActor in try? self?.engine?.start(); self?.player?.play() }
            }
        } catch {
            stop()
        }
    }

    public func appWillEnterForeground() { stop() }

    /// Before a call: CallKit/WebRTC take over the audio session.
    public func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        if let o = interruptionObserver { NotificationCenter.default.removeObserver(o) }
        interruptionObserver = nil
    }
    #else
    public func appDidEnterBackground(callActive: Bool) {}
    public func appWillEnterForeground() {}
    public func stop() {}
    #endif
}
