import SwiftUI
import AVFoundation
import RMSMaxCore

// MARK: - Recorder

@MainActor
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var levels: [Double] = []
    private var fileURL: URL?

    struct Result {
        let data: Data
        let fileName: String
        let mime: String
        let durationMs: Int
        let wave: [UInt8]
    }

    static func requestPermission() async -> Bool {
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

    func start() async throws {
        guard await Self.requestPermission() else {
            throw MediaError.unsupported("Нет доступа к микрофону. Разрешите его в настройках системы.")
        }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voice_\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 48_000,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw MediaError.unsupported("Не удалось начать запись") }
        recorder = rec
        fileURL = url
        levels = []
        elapsed = 0
        isRecording = true
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        // dBFS → linear amplitude (what the official client averages for its waveform).
        let db = Double(recorder.averagePower(forChannel: 0))
        let amp = pow(10, db / 20)
        level = max(0, min(1, (db + 60) / 60))
        levels.append(amp)
        elapsed = recorder.currentTime
        if elapsed >= 15 * 60 { _ = stop() }
    }

    /// Stops recording and returns the encoded file plus the official-client waveform (80 bytes, 0…127).
    func stop(asOgg: Bool = true) -> Result? {
        guard let recorder, let fileURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        cleanupTimer()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        guard duration >= 0.5, let m4a = try? Data(contentsOf: fileURL) else { return nil }
        let stamp = Int(Date().timeIntervalSince1970)
        let durationMs = max(1000, Int(duration * 1000))
        let wave = Self.wave(from: levels)
        // Official clients send Ogg/Opus; fall back to the recorder's AAC if encoding fails.
        if asOgg, let ogg = try? OggOpusEncoder.encode(fileAt: fileURL) {
            return Result(data: ogg, fileName: "voice_\(stamp).ogg", mime: "audio/ogg", durationMs: durationMs, wave: wave)
        }
        return Result(data: m4a, fileName: "voice_\(stamp).m4a", mime: "audio/mp4", durationMs: durationMs, wave: wave)
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        cleanupTimer()
    }

    private func cleanupTimer() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        isRecording = false
        level = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Same algorithm as the official web client's createWave(): bucket mean × 800, capped at 127.
    static func wave(from samples: [Double], count: Int = 80) -> [UInt8] {
        guard !samples.isEmpty else { return Array(repeating: 0, count: count) }
        return (0..<count).map { t in
            let lo = t * samples.count / count
            let hi = max(lo + 1, (t + 1) * samples.count / count)
            let slice = samples[min(lo, samples.count - 1)..<min(hi, samples.count)]
            let mean = slice.reduce(0, +) / Double(max(1, slice.count))
            return UInt8(min(127, Int(mean * 800)))
        }
    }
}

/// Recording strip that replaces the compose bar while recording.
struct VoiceRecordingBar: View {
    @ObservedObject var recorder: VoiceRecorder
    let encrypted: Bool
    let onSend: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onCancel) {
                Image(systemName: "trash").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help("Отменить запись")

            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(0.4 + recorder.level * 0.6)
            Text(Self.format(recorder.elapsed))
                .font(.body.monospacedDigit())
            if encrypted {
                Label("будет зашифровано", systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            GeometryReader { geo in
                Capsule()
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor)
                            .frame(width: max(6, geo.size.width * recorder.level))
                    }
            }
            .frame(height: 6)

            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .keyboardShortcut(.return, modifiers: [])
            .help("Отправить голосовое")
        }
        .padding(12)
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Inline player for voice messages

@MainActor
final class VoicePlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var duration: TimeInterval = 0
    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(url: URL) throws {
        if let player, isPlaying {
            player.pause()
            isPlaying = false
            timer?.invalidate()
            return
        }
        if player == nil {
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            player = p
            duration = p.duration
        }
        player?.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.progress = 0
            self.timer?.invalidate()
        }
    }
}

struct VoiceMessageRow: View {
    @StateObject private var player = VoicePlayer()
    let durationMs: Double?
    let wave: [UInt8]?
    let encrypted: Bool
    let loading: Bool
    let failed: String?
    let fetch: () async -> URL?

    var body: some View {
        HStack(spacing: 10) {
            Button {
                Task {
                    guard let url = await fetch() else { return }
                    do { try player.toggle(url: url) } catch { playError = "Формат не поддерживается этим устройством" }
                }
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor).frame(width: 36, height: 36)
                    if loading { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").foregroundStyle(.white) }
                }
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                WaveformView(samples: wave ?? [], progress: player.progress)
                    .frame(width: 150, height: 22)
                HStack(spacing: 4) {
                    if encrypted { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.green) }
                    Text(failed ?? playError ?? VoiceRecordingBar.format(totalSeconds))
                        .font(.caption2)
                        .foregroundStyle(failed == nil && playError == nil ? Color.secondary : Color.red)
                }
            }
        }
    }

    @State private var playError: String?

    private var totalSeconds: TimeInterval {
        if player.duration > 0 { return player.duration }
        return (durationMs ?? 0) / 1000
    }
}

struct WaveformView: View {
    let samples: [UInt8]
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let bars = samples.isEmpty ? Array(repeating: UInt8(30), count: 40) : samples
            let count = bars.count
            let barWidth = max(1, geo.size.width / CGFloat(count) - 1)
            HStack(alignment: .center, spacing: 1) {
                ForEach(0..<count, id: \.self) { i in
                    let h = max(2, geo.size.height * min(1, CGFloat(bars[i]) / 127))
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Double(i) / Double(count) <= progress ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(width: barWidth, height: h)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}
