import Foundation
import AVFoundation

/// Encodes recorded audio to Ogg/Opus (48 kHz mono, 20 ms frames) — the voice format official Max clients send.
/// Uses the system Opus encoder (AVAudioConverter) and a small RFC 7845 Ogg muxer.
public enum OggOpusEncoder {
    public enum EncodeError: Error, LocalizedError {
        case failed(String)
        public var errorDescription: String? {
            if case .failed(let m) = self { return "Не удалось закодировать в Opus: \(m)" }
            return nil
        }
    }

    static let sampleRate: Double = 48_000
    static let frameSize: AVAudioFrameCount = 960
    static let preSkip: UInt16 = 312

    /// Reads any audio file AVFoundation understands (e.g. the recorder's M4A) and returns Ogg/Opus bytes.
    public static func encode(fileAt url: URL, bitrate: Int = 32_000) throws -> Data {
        let source = try AVAudioFile(forReading: url)
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw EncodeError.failed("формат PCM") }

        // Resample/downmix whatever was recorded to 48 kHz mono float.
        let srcFormat = source.processingFormat
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: AVAudioFrameCount(source.length))!
        try source.read(into: srcBuffer)
        let pcm: AVAudioPCMBuffer
        if srcFormat.sampleRate == sampleRate && srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            pcm = srcBuffer
        } else {
            guard let resampler = AVAudioConverter(from: srcFormat, to: pcmFormat) else { throw EncodeError.failed("ресемплер") }
            let cap = AVAudioFrameCount(Double(srcBuffer.frameLength) * sampleRate / srcFormat.sampleRate) + 4096
            pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: cap)!
            var done = false
            var err: NSError?
            resampler.convert(to: pcm, error: &err) { _, status in
                if done { status.pointee = .endOfStream; return nil }
                done = true; status.pointee = .haveData; return srcBuffer
            }
            if let err { throw EncodeError.failed(err.localizedDescription) }
        }
        return try encode(pcm: pcm, bitrate: bitrate)
    }

    public static func encode(pcm: AVAudioPCMBuffer, bitrate: Int = 32_000) throws -> Data {
        var desc = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: frameSize, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0
        )
        guard let opusFormat = AVAudioFormat(streamDescription: &desc),
              let converter = AVAudioConverter(from: pcm.format, to: opusFormat)
        else { throw EncodeError.failed("кодек Opus недоступен") }
        converter.bitRate = bitrate

        var packets: [Data] = []
        var fed = false
        while true {
            let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 32, maximumPacketSize: 1500)
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, inStatus in
                if fed { inStatus.pointee = .endOfStream; return nil }
                fed = true; inStatus.pointee = .haveData; return pcm
            }
            if let err { throw EncodeError.failed(err.localizedDescription) }
            if let descs = out.packetDescriptions {
                for k in 0..<Int(out.packetCount) {
                    let d = descs[k]
                    packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
                }
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        guard !packets.isEmpty else { throw EncodeError.failed("пустой результат") }
        return mux(packets: packets, totalSamples: Int64(pcm.frameLength))
    }

    // MARK: - Ogg muxing (RFC 3533 / RFC 7845)

    static func mux(packets: [Data], totalSamples: Int64) -> Data {
        let serial = UInt32.random(in: 1...UInt32.max)
        var seq: UInt32 = 0
        var out = Data()

        var head = Data("OpusHead".utf8)
        head.append(1)                                   // version
        head.append(1)                                   // channels
        head.append(contentsOf: le16(preSkip))
        head.append(contentsOf: le32(UInt32(sampleRate))) // input sample rate
        head.append(contentsOf: [0, 0])                  // output gain
        head.append(0)                                   // mapping family
        out.append(page([head], granule: 0, serial: serial, seq: &seq, flags: 0x02))

        let vendor = Data("RMS MAX".utf8)
        var tags = Data("OpusTags".utf8)
        tags.append(contentsOf: le32(UInt32(vendor.count)))
        tags.append(vendor)
        tags.append(contentsOf: le32(0))
        out.append(page([tags], granule: 0, serial: serial, seq: &seq, flags: 0))

        // ~1 s of audio per page (50 × 20 ms), well under the 255-segment limit.
        let perPage = 50
        var granule: Int64 = 0
        var index = 0
        while index < packets.count {
            let chunk = Array(packets[index..<min(index + perPage, packets.count)])
            index += chunk.count
            granule += Int64(chunk.count) * Int64(frameSize)
            let isLast = index >= packets.count
            let finalGranule = isLast ? min(granule, totalSamples + Int64(preSkip)) : granule
            out.append(page(chunk, granule: finalGranule, serial: serial, seq: &seq, flags: isLast ? 0x04 : 0))
        }
        return out
    }

    static func page(_ packets: [Data], granule: Int64, serial: UInt32, seq: inout UInt32, flags: UInt8) -> Data {
        var lacing: [UInt8] = []
        for p in packets {
            var rest = p.count
            while rest >= 255 { lacing.append(255); rest -= 255 }
            lacing.append(UInt8(rest))
        }
        var d = Data("OggS".utf8)
        d.append(0)
        d.append(flags)
        d.append(contentsOf: le64(UInt64(bitPattern: granule)))
        d.append(contentsOf: le32(serial))
        d.append(contentsOf: le32(seq))
        let crcOffset = d.count
        d.append(contentsOf: [0, 0, 0, 0])
        d.append(UInt8(lacing.count))
        d.append(contentsOf: lacing)
        for p in packets { d.append(p) }
        let crc = oggCRC(d)
        d.replaceSubrange(crcOffset..<crcOffset + 4, with: le32(crc))
        seq += 1
        return d
    }

    /// Ogg CRC-32: polynomial 0x04C11DB7, initial value 0, no reflection, no final XOR.
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var r = UInt32(i) << 24
        for _ in 0..<8 { r = (r & 0x8000_0000) != 0 ? (r << 1) ^ 0x04C1_1DB7 : r << 1 }
        return r
    }

    static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(byte)) & 0xFF)] }
        return crc
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
    private static func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xFF) } }
}
