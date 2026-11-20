import SwiftUI
@preconcurrency import AVFoundation
import AVKit
import RMSMaxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Recorder

/// Records a clip with the camera and microphone and turns it into a 480×480 H.264/AAC mp4 («кружок», up to 60 s).
@MainActor
final class CircleRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    enum State: Equatable { case idle, ready, recording, processing, finished, failed(String) }

    static let maxSeconds: Double = 60
    let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "dev.rms.maks.circle.session")
    private var timer: Timer?
    private var startedAt = Date()
    private var rawURL: URL?

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: Double = 0
    private(set) var resultURL: URL?
    private(set) var resultDurationMs = 0

    func prepare() async {
        guard await PermissionsCenter.shared.request(.camera).isUsable else {
            PermissionsCenter.shared.alert = .camera
            state = .failed("Нет доступа к камере")
            return
        }
        guard await PermissionsCenter.shared.ensureMicrophone() else { state = .failed("Нет доступа к микрофону"); return }
        session.beginConfiguration()
        session.sessionPreset = .high
        #if os(iOS)
        let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) ?? AVCaptureDevice.default(for: .video)
        #else
        let cam = AVCaptureDevice.default(for: .video)
        #endif
        guard let cam, let camIn = try? AVCaptureDeviceInput(device: cam), session.canAddInput(camIn) else {
            session.commitConfiguration()
            state = .failed("Камера не найдена")
            return
        }
        session.addInput(camIn)
        if let mic = AVCaptureDevice.default(for: .audio), let micIn = try? AVCaptureDeviceInput(device: mic), session.canAddInput(micIn) {
            session.addInput(micIn)
        }
        movie.maxRecordedDuration = CMTime(seconds: Self.maxSeconds, preferredTimescale: 600)
        if session.canAddOutput(movie) { session.addOutput(movie) }
        session.commitConfiguration()
        let s = session
        sessionQueue.async { s.startRunning() }
        state = .ready
    }

    func stopSession() {
        timer?.invalidate()
        let s = session
        sessionQueue.async { if s.isRunning { s.stopRunning() } }
    }

    func start() {
        guard state == .ready else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("circle_raw_\(UUID().uuidString).mov")
        rawURL = url
        elapsed = 0
        startedAt = Date()
        movie.startRecording(to: url, recordingDelegate: self)
        state = .recording
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    func stop() {
        guard state == .recording else { return }
        movie.stopRecording()
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        // The max-duration limit also ends with an «error» that still carries a usable file.
        let usable = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? (error == nil)
        Task { @MainActor in
            self.timer?.invalidate()
            guard usable else { self.state = .failed(error?.localizedDescription ?? "Запись не удалась"); return }
            self.state = .processing
            do {
                let (url, ms) = try await Self.exportSquare(outputFileURL)
                self.resultURL = url
                self.resultDurationMs = ms
                self.state = .finished
            } catch {
                self.state = .failed("Не удалось подготовить видео: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: outputFileURL)
        }
    }

    func discard() {
        if let u = resultURL { try? FileManager.default.removeItem(at: u) }
        resultURL = nil
        resultDurationMs = 0
        elapsed = 0
        state = .ready
    }

    /// Centre crop to a square, scaled to 480×480, H.264 + AAC in an mp4 container.
    static func exportSquare(_ source: URL) async throws -> (URL, Int) {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "Circle", code: 1, userInfo: [NSLocalizedDescriptionKey: "В записи нет видео"])
        }
        let natural = try await track.load(.naturalSize)
        let tx = try await track.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let rect = CGRect(origin: .zero, size: natural).applying(tx)
        let side = min(abs(rect.width), abs(rect.height))
        let out: CGFloat = 480
        var t = tx
        t = t.concatenating(CGAffineTransform(translationX: -rect.minX - (abs(rect.width) - side) / 2, y: -rect.minY - (abs(rect.height) - side) / 2))
        t = t.concatenating(CGAffineTransform(scaleX: out / side, y: out / side))

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let comp = AVMutableVideoComposition()
        comp.renderSize = CGSize(width: out, height: out)
        comp.frameDuration = CMTime(value: 1, timescale: 30)
        comp.instructions = [instruction]

        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("circle_\(UUID().uuidString).mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetMediumQuality) else {
            throw NSError(domain: "Circle", code: 2, userInfo: [NSLocalizedDescriptionKey: "Экспорт недоступен"])
        }
        export.videoComposition = comp
        export.outputURL = dest
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in export.exportAsynchronously { c.resume() } }
        guard export.status == .completed else {
            throw export.error ?? NSError(domain: "Circle", code: 3, userInfo: [NSLocalizedDescriptionKey: "Экспорт не завершён"])
        }
        return (dest, Int(duration.seconds * 1000))
    }
}

// MARK: - Layer-backed views

#if os(macOS)
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspectFill
        v.layer = layer
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView.layer as? AVPlayerLayer)?.player = player }
}
#else
final class LayerHostView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
}
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let v = PreviewHost()
        (v.layer as! AVCaptureVideoPreviewLayer).session = session
        (v.layer as! AVCaptureVideoPreviewLayer).videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    final class PreviewHost: UIView { override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self } }
}
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        (v.layer as! AVPlayerLayer).player = player
        (v.layer as! AVPlayerLayer).videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}
#endif

// MARK: - Recorder sheet

struct CircleRecorderSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chatId: Int64
    @StateObject private var rec = CircleRecorder()
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 14) {
            Text("Видеосообщение").font(.headline)
            ZStack {
                Circle().fill(Color.black)
                switch rec.state {
                case .finished:
                    if let player { PlayerLayerView(player: player).clipShape(Circle()) }
                case .failed(let msg):
                    Text(msg).font(.caption).foregroundStyle(.white).multilineTextAlignment(.center).padding()
                case .processing:
                    ProgressView().tint(.white)
                default:
                    CameraPreview(session: rec.session).clipShape(Circle())
                }
                Circle().stroke(rec.state == .recording ? Color.red : Color.accentColor.opacity(0.6), lineWidth: 4)
            }
            .frame(width: 260, height: 260)

            Text(timeText).font(.title3.monospacedDigit()).foregroundStyle(rec.state == .recording ? .red : .secondary)

            HStack(spacing: 14) {
                switch rec.state {
                case .ready:
                    Button { rec.start() } label: { Label("Записать", systemImage: "record.circle") }
                        .buttonStyle(.borderedProminent).tint(.red)
                case .recording:
                    Button { rec.stop() } label: { Label("Стоп", systemImage: "stop.circle.fill") }
                        .buttonStyle(.borderedProminent)
                case .finished:
                    Button("Переснять") { player?.pause(); player = nil; rec.discard() }
                    Button {
                        if let url = rec.resultURL, let data = try? Data(contentsOf: url) {
                            let ms = rec.resultDurationMs
                            Task { await store.sendVideoMessage(chatId: chatId, data: data, durationMs: ms) }
                        }
                        close()
                    } label: { Label("Отправить", systemImage: "paperplane.fill") }
                    .buttonStyle(.borderedProminent)
                case .failed:
                    Button("Закрыть") { close() }
                default:
                    EmptyView()
                }
                if !isFailed { Button("Отмена", role: .cancel) { close() } }
            }
            Text("Круглое видео до \(Int(CircleRecorder.maxSeconds)) секунд").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(minWidth: 340)
        .task { await rec.prepare() }
        .onChange(of: rec.state) { _, s in
            if s == .finished, let url = rec.resultURL {
                let p = AVPlayer(url: url)
                p.actionAtItemEnd = .none
                NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
                    p.seek(to: .zero); p.play()
                }
                p.isMuted = false
                player = p
                p.play()
            }
        }
        .onDisappear { rec.stopSession(); player?.pause() }
    }

    private var isFailed: Bool { if case .failed = rec.state { return true } else { return false } }

    private var timeText: String {
        let t = rec.state == .finished ? Double(rec.resultDurationMs) / 1000 : rec.elapsed
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }

    private func close() {
        player?.pause()
        rec.stopSession()
        dismiss()
    }
}

// MARK: - Playback of received circles

struct VideoMessageView: View {
    @EnvironmentObject private var store: AppStore
    let message: MaxMessage
    let attachment: MaxAttachment
    @State private var player: AVPlayer?
    @State private var loading = false
    @State private var failed = false
    @State private var playing = false
    @State private var status: String?

    private var durationText: String {
        let s = Int((attachment.durationMs ?? 0) / (((attachment.durationMs ?? 0) > 1000) ? 1000 : 1))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.85))
            if let player {
                PlayerLayerView(player: player).clipShape(Circle())
            }
            if player == nil || !playing {
                VStack(spacing: 4) {
                    if loading { ProgressView().tint(.white) }
                    else { Image(systemName: failed ? "exclamationmark.triangle" : "play.fill").font(.system(size: 34)).foregroundStyle(.white) }
                    Text(failed ? "Не удалось загрузить" : (status ?? durationText)).font(.caption.bold()).foregroundStyle(.white.opacity(0.85))
                }
            }
        }
        .frame(width: 210, height: 210)
        .contentShape(Circle())
        .onTapGesture { toggle() }
        .help("Видеосообщение")
        .onDisappear { player?.pause(); playing = false }
    }

    private func toggle() {
        if let player {
            if playing { player.pause(); playing = false } else { player.play(); playing = true }
            return
        }
        guard !loading, Int64(message.id) != nil, attachment.videoId != nil else { failed = true; return }
        loading = true; failed = false; status = nil
        Task {
            defer { loading = false }
            // The CDN uses the Russian root CA, which AVPlayer does not trust: download with our own trust rules, play the file.
            // A fresh clip is transcoded on the server first, so the first tries may fail — wait a little.
            var lastError: Error?
            for attempt in 0..<6 {
                do {
                    let file = try await store.localFile(for: attachment, in: message)
                    try await start(file)
                    return
                } catch {
                    lastError = error
                    ProtocolLog.add("video message try \(attempt + 1) failed: \(error.localizedDescription)")
                    if attempt < 5 {
                        status = "Видео обрабатывается…"
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                }
            }
            status = nil
            failed = true
            ProtocolLog.add("video message gave up: \(lastError?.localizedDescription ?? "?")")
        }
    }

    private func start(_ file: URL) async throws {
        let item = AVPlayerItem(url: file)
        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .pause
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { _ in
            p.seek(to: .zero); playing = false
        }
        player = p
        p.play()
        playing = true
        // AVPlayer never throws: look at the item status shortly after to catch a broken or still incomplete file.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        if item.status == .failed {
            player = nil; playing = false
            try? FileManager.default.removeItem(at: file) // do not cache a bad download
            throw item.error ?? NSError(domain: "VideoMessage", code: 1, userInfo: [NSLocalizedDescriptionKey: "Файл не воспроизводится"])
        }
    }
}
