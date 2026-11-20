// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import AVFoundation

/// Call sounds like the official client has (ringtone, ringback while dialing, connected, busy, end), synthesized here:
/// plain sine tones, no assets. They follow the call phase; the incoming ringtone is macOS only (iOS rings through CallKit).
@MainActor
public final class CallSounds {
    public static let shared = CallSounds()
    public var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "rmsmaks.sounds.calls") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "rmsmaks.sounds.calls"); if !newValue { stop() } }
    }

    public enum Tone { case ringtone, ringback, connected, busy, ended }
    private var player: AVAudioPlayer?
    private var current: Tone?

    /// Called on every change of the call state.
    public func update(old: ActiveCallState, new: ActiveCallState) {
        guard old.phase != new.phase else { return }
        switch new.phase {
        case .ringing:
            #if os(macOS)
            play(new.isIncoming ? .ringtone : .ringback)
            #else
            if !new.isIncoming { play(.ringback) }
            #endif
        case .connecting:
            if old.phase == .ringing { stop() }          // the call was picked up / is being joined
        case .active:
            play(.connected)
        case .ended:
            let m = (new.statusMessage ?? "").lowercased()
            let wasLive = old.phase == .active || old.phase == .ringing || old.phase == .connecting
            guard wasLive else { stop(); return }
            play(m.contains("отклон") || m.contains("занят") || m.contains("не отвеч") ? .busy : .ended)
        case .idle:
            stop()
        }
    }

    public func stop() {
        player?.stop(); player = nil; current = nil
    }

    func play(_ tone: Tone) {
        guard enabled else { return }
        stop()
        guard let p = try? AVAudioPlayer(data: Self.wav(for: tone)) else { return }
        p.numberOfLoops = (tone == .ringtone || tone == .ringback) ? -1 : 0
        p.volume = 0.6
        p.prepareToPlay()
        p.play()
        player = p; current = tone
    }

    // MARK: synthesis

    struct Segment { var freqs: [Double]; var seconds: Double }     // no freqs = silence

    static func segments(for tone: Tone) -> [Segment] {
        switch tone {
        case .ringback: return [Segment(freqs: [425], seconds: 1.0), Segment(freqs: [], seconds: 3.0)]       // long beep, long pause
        case .ringtone: return [Segment(freqs: [659], seconds: 0.16), Segment(freqs: [784], seconds: 0.16), Segment(freqs: [988], seconds: 0.28),
                                Segment(freqs: [], seconds: 0.2), Segment(freqs: [659], seconds: 0.16), Segment(freqs: [784], seconds: 0.16),
                                Segment(freqs: [988], seconds: 0.28), Segment(freqs: [], seconds: 1.6)]
        case .connected: return [Segment(freqs: [660], seconds: 0.09), Segment(freqs: [], seconds: 0.04), Segment(freqs: [880], seconds: 0.12)]
        case .busy: return Array(repeating: [Segment(freqs: [425], seconds: 0.35), Segment(freqs: [], seconds: 0.35)], count: 3).flatMap { $0 }
        case .ended: return [Segment(freqs: [425], seconds: 0.2), Segment(freqs: [], seconds: 0.1), Segment(freqs: [340], seconds: 0.3)]
        }
    }

    /// 16-bit mono PCM wrapped as WAV; every segment has short fades so the tone does not click.
    static func wav(for tone: Tone) -> Data {
        let rate = 44100.0
        var samples: [Int16] = []
        for seg in segments(for: tone) {
            let n = Int(seg.seconds * rate)
            let fade = min(Int(0.008 * rate), n / 2)
            for i in 0..<n {
                guard !seg.freqs.isEmpty else { samples.append(0); continue }
                var v = 0.0
                for f in seg.freqs { v += sin(2 * Double.pi * f * Double(i) / rate) + 0.25 * sin(4 * Double.pi * f * Double(i) / rate) }
                v /= Double(seg.freqs.count) * 1.25
                let env = i < fade ? Double(i) / Double(max(fade, 1)) : (i > n - fade ? Double(n - i) / Double(max(fade, 1)) : 1)
                samples.append(Int16(max(-1, min(1, v * env * 0.5)) * Double(Int16.max)))
            }
        }
        var d = Data()
        func u32(_ x: UInt32) { var v = x.littleEndian; d.append(Data(bytes: &v, count: 4)) }
        func u16(_ x: UInt16) { var v = x.littleEndian; d.append(Data(bytes: &v, count: 2)) }
        let dataSize = UInt32(samples.count * 2)
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataSize); d.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataSize)
        for s in samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
