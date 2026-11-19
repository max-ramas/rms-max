import Foundation

/// Repackages an Ogg/Opus voice message (the format official Max clients store) into a CAF container,
/// which AVFoundation plays natively. No decoding: Opus packets are copied as-is.
/// Mirrors the official web client's CafRemuxWorker.
public enum OggOpusCAF {
    public enum RemuxError: Error, LocalizedError {
        case malformed(String)
        public var errorDescription: String? {
            if case .malformed(let m) = self { return "Не удалось разобрать Ogg/Opus: \(m)" }
            return nil
        }
    }

    public static func isOgg(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data("OggS".utf8)
    }

    public static func remux(_ data: Data) throws -> Data {
        let b = [UInt8](data)
        var serial: UInt32?
        var lastGranule: Int64 = -1
        var gotHead = false
        var channels = 1
        var preSkip = 0
        var samplesPerPacket: Int?
        var packetSizes: [Int] = []
        var audio = Data()
        var pendingParts: [Range<Int>] = []
        var packetIndex = 0
        var pos = 0

        func u32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
        }

        while pos < b.count {
            guard pos + 27 <= b.count else { throw RemuxError.malformed("усечён заголовок страницы") }
            guard b[pos] == 0x4F, b[pos + 1] == 0x67, b[pos + 2] == 0x67, b[pos + 3] == 0x53 else {
                throw RemuxError.malformed("нет сигнатуры OggS")
            }
            let lo = u32(pos + 6), hi = u32(pos + 10)
            let granule: Int64 = (lo == .max && hi == .max) ? -1 : Int64(hi) << 32 | Int64(lo)
            let pageSerial = u32(pos + 14)
            if let serial, serial != pageSerial { throw RemuxError.malformed("цепочки Ogg не поддерживаются") }
            serial = pageSerial
            if granule != -1 { lastGranule = granule }

            let segCount = Int(b[pos + 26])
            let dataStart = pos + 27 + segCount
            guard dataStart <= b.count else { throw RemuxError.malformed("усечена таблица сегментов") }
            var cursor = dataStart
            var segStart = dataStart
            for i in 0..<segCount {
                let size = Int(b[pos + 27 + i])
                cursor += size
                guard cursor <= b.count else { throw RemuxError.malformed("усечены данные страницы") }
                if size == 255 { continue }
                var parts = pendingParts
                pendingParts = []
                if cursor > segStart { parts.append(segStart..<cursor) }
                segStart = cursor
                let length = parts.reduce(0) { $0 + $1.count }
                if length > 0 {
                    if packetIndex == 0 {
                        let head = parts.flatMap { b[$0] }
                        guard head.count >= 19, String(bytes: head.prefix(8), encoding: .ascii) == "OpusHead" else {
                            throw RemuxError.malformed("первый пакет не OpusHead")
                        }
                        guard head[18] == 0 else { throw RemuxError.malformed("многоканальная раскладка не поддерживается") }
                        channels = Int(head[9])
                        preSkip = Int(head[10]) | Int(head[11]) << 8
                        gotHead = true
                    } else if packetIndex > 1 {
                        let packet = parts.flatMap { b[$0] }
                        let samples = try samplesIn(packet)
                        if let spp = samplesPerPacket, spp != samples {
                            throw RemuxError.malformed("пакеты Opus разной длительности")
                        }
                        samplesPerPacket = samples
                        audio.append(contentsOf: packet)
                        packetSizes.append(length)
                    }
                    packetIndex += 1
                }
            }
            let pageEnd = dataStart + (0..<segCount).reduce(0) { $0 + Int(b[pos + 27 + $1]) }
            if cursor > segStart { pendingParts.append(segStart..<cursor) }
            pos = pageEnd
        }

        guard gotHead else { throw RemuxError.malformed("нет заголовка OpusHead") }
        guard let spp = samplesPerPacket, !packetSizes.isEmpty else { throw RemuxError.malformed("нет аудиопакетов") }

        let total = Int64(packetSizes.count * spp)
        let validEnd = lastGranule > Int64(preSkip) && lastGranule <= total
        let validFrames = validEnd ? lastGranule - Int64(preSkip) : total - Int64(preSkip)
        let remainder = validEnd ? total - lastGranule : 0

        var w = BEWriter()
        w.fourCC("caff"); w.u16(1); w.u16(0)
        w.fourCC("desc"); w.u64(32)
        w.f64(48_000); w.fourCC("opus"); w.u32(0); w.u32(0)
        w.u32(UInt32(spp)); w.u32(UInt32(channels)); w.u32(0)
        if let layout = channelLayoutTag(channels) {
            w.fourCC("chan"); w.u64(12); w.u32(layout); w.u32(0); w.u32(0)
        }
        w.fourCC("kuki"); w.u64(28)
        w.u32(2048); w.u32(48_000); w.u32(UInt32(spp)); w.i32(-1000); w.u32(UInt32(channels)); w.u32(0); w.u32(0)
        var table = BEWriter()
        for s in packetSizes { table.varint(s) }
        w.fourCC("pakt"); w.u64(UInt64(24 + table.data.count))
        w.u64(UInt64(packetSizes.count)); w.u64(UInt64(max(0, validFrames)))
        w.u32(UInt32(preSkip)); w.u32(UInt32(max(0, remainder)))
        w.data.append(table.data)
        w.fourCC("data"); w.u64(UInt64(4 + audio.count)); w.u32(0)
        w.data.append(audio)
        return w.data
    }

    /// Samples (at 48 kHz) carried by one Opus packet, from its TOC byte (RFC 6716 §3.1).
    static func samplesIn(_ packet: [UInt8]) throws -> Int {
        guard let toc = packet.first else { throw RemuxError.malformed("пустой пакет") }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count > 1 else { throw RemuxError.malformed("короткий пакет") }
            frames = Int(packet[1] & 63)
        }
        guard frames > 0 else { throw RemuxError.malformed("пакет без кадров") }
        let config = Int(toc >> 3)
        let frameSize: Int
        if config < 12 { frameSize = [480, 960, 1920, 2880][config & 3] }
        else if config < 16 { frameSize = [480, 960][config & 1] }
        else { frameSize = [120, 240, 480, 960][config & 3] }
        return frames * frameSize
    }

    static func channelLayoutTag(_ channels: Int) -> UInt32? {
        switch channels {
        case 1: return 6_553_601 // kAudioChannelLayoutTag_Mono
        case 2: return 6_619_138 // kAudioChannelLayoutTag_Stereo
        default: return nil
        }
    }
}

private struct BEWriter {
    var data = Data()
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
    mutating func fourCC(_ s: String) { data.append(contentsOf: Array(s.utf8.prefix(4))) }
    mutating func varint(_ value: Int) {
        var groups: [UInt8] = []
        var n = value
        repeat { groups.insert(UInt8(n & 127), at: 0); n >>= 7 } while n > 0
        for (i, g) in groups.enumerated() { data.append(i < groups.count - 1 ? g | 128 : g) }
    }
}
