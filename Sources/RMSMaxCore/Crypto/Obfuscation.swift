import Foundation

public enum Obfuscation {
    private static let zhBase: UInt32 = 0x4E00
    private static let zhCount: UInt32 = 2048

    public static func detectChinese(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars.prefix(5))
        guard scalars.count == 5 else { return false }
        for scalar in scalars {
            let cp = scalar.value
            guard cp >= zhBase && cp < zhBase + zhCount else { return false }
            let idx = cp - zhBase
            if (idx & 1) != 0 { return false }
        }
        return true
    }

    public static func obfuscateChinese(_ bytes: Data) -> String {
        let maxEven = Int((zhCount - 1) / 2)
        var outScalars: [Unicode.Scalar] = []
        outScalars.reserveCapacity(5 + ((bytes.count + 2) * 8) / 11 + 2)

        for _ in 0..<5 {
            let r = Int.random(in: 0...maxEven)
            let idx = UInt32(r * 2)
            if let scalar = Unicode.Scalar(zhBase + idx) {
                outScalars.append(scalar)
            }
        }

        let len = UInt16(min(bytes.count, Int(UInt16.max))).bigEndian
        var payload = Data(capacity: 2 + bytes.count)
        withUnsafeBytes(of: len) { payload.append(contentsOf: $0) }
        payload.append(bytes)

        let bitsPerChar = 11
        var bitBuffer: UInt64 = 0
        var bitCount = 0

        for b in payload {
            bitBuffer = (bitBuffer << 8) | UInt64(b)
            bitCount += 8
            while bitCount >= bitsPerChar {
                bitCount -= bitsPerChar
                let idx = UInt32((bitBuffer >> bitCount) & UInt64((1 << bitsPerChar) - 1))
                if let scalar = Unicode.Scalar(zhBase + idx) {
                    outScalars.append(scalar)
                }
                bitBuffer &= UInt64((1 << bitCount) - 1)
            }
        }

        if bitCount > 0 {
            let idx = UInt32((bitBuffer << (bitsPerChar - bitCount)) & UInt64((1 << bitsPerChar) - 1))
            if let scalar = Unicode.Scalar(zhBase + idx) {
                outScalars.append(scalar)
            }
        }

        return String(String.UnicodeScalarView(outScalars))
    }

    public static func deobfuscateChinese(_ text: String) throws -> Data {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 5 else {
            throw CryptoError.invalidPacket("Текст слишком короткий для деобфускации")
        }

        let bitsPerChar = 11
        var bitBuffer: UInt64 = 0
        var bitCount = 0
        var raw = Data()

        for scalar in scalars.dropFirst(5) {
            let cp = scalar.value
            guard cp >= zhBase && cp < zhBase + zhCount else { continue }
            let idx = cp - zhBase
            bitBuffer = (bitBuffer << bitsPerChar) | UInt64(idx)
            bitCount += bitsPerChar
            while bitCount >= 8 {
                bitCount -= 8
                let byte = UInt8((bitBuffer >> bitCount) & 0xFF)
                raw.append(byte)
                bitBuffer &= UInt64((1 << bitCount) - 1)
            }
        }

        guard raw.count >= 2 else {
            throw CryptoError.invalidPacket("Повреждённый заголовок обфускации")
        }

        let expectedLen = (Int(raw[0]) << 8) | Int(raw[1])
        let content = raw.dropFirst(2)
        guard content.count >= expectedLen else {
            throw CryptoError.invalidPacket("Повреждённая длина полезной нагрузки")
        }
        return Data(content.prefix(expectedLen))
    }

    public static func decodeEncryptedBytes(from text: String) -> (bytes: Data, mode: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if detectChinese(trimmed), let b = try? deobfuscateChinese(trimmed) {
            return (b, "zh")
        }
        if let b = Data(base64Encoded: trimmed), let first = b.first, (first >> 6) == 0 {
            return (b, "raw")
        }
        return nil
    }

    public static func encodeEncryptedBytes(_ bytes: Data, mode: String?) -> String {
        switch mode {
        case "none", "raw":
            return bytes.base64EncodedString()
        default:
            return obfuscateChinese(bytes)
        }
    }
}
