import Foundation
import CryptoKit

public enum CryptoError: Error, LocalizedError {
    case invalidKeyLength
    case invalidCiphertext
    case invalidPacket(String)
    case missingPassword
    case wrongPassword
    case missingSessionKey
    case failedSessionDecryption
    case compressionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: return "Ключ должен быть длиной 32 байта"
        case .invalidCiphertext: return "Некорректный формат шифротекста"
        case .invalidPacket(let msg): return msg
        case .missingPassword: return "Требуется пароль для расшифровки сообщения"
        case .wrongPassword: return "Неверный пароль чата"
        case .missingSessionKey: return "Отсутствует сессионный ключ для расшифровки"
        case .failedSessionDecryption: return "Не удалось расшифровать сообщение ключом сессии"
        case .compressionFailed: return "Ошибка сжатия/распаковки данных"
        }
    }
}

// MARK: - Symmetric ChaCha20-Poly1305 & Argon2id

public enum SymmetricCrypto {
    private static let keyCacheLock = NSLock()
    private static var keyCache: [String: Data] = [:]

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0..<count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }

    public static func encrypt(key: Data, nonce: Data, plaintext: Data, aad: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw CryptoError.invalidKeyLength }
        let symKey = SymmetricKey(data: key)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)
        let sealed: ChaChaPoly.SealedBox
        if let aad {
            sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: chachaNonce, authenticating: aad)
        } else {
            sealed = try ChaChaPoly.seal(plaintext, using: symKey, nonce: chachaNonce)
        }
        return sealed.ciphertext + sealed.tag
    }

    public static func decrypt(key: Data, nonce: Data, ciphertextAndTag: Data, aad: Data? = nil) throws -> Data {
        guard key.count == 32 else { throw CryptoError.invalidKeyLength }
        guard ciphertextAndTag.count >= 16 else { throw CryptoError.invalidCiphertext }
        let symKey = SymmetricKey(data: key)
        let chachaNonce = try ChaChaPoly.Nonce(data: nonce)
        let splitIdx = ciphertextAndTag.count - 16
        let ct = ciphertextAndTag.prefix(splitIdx)
        let tag = ciphertextAndTag.suffix(16)
        let box = try ChaChaPoly.SealedBox(nonce: chachaNonce, ciphertext: ct, tag: tag)
        if let aad {
            return try ChaChaPoly.open(box, using: symKey, authenticating: aad)
        }
        return try ChaChaPoly.open(box, using: symKey)
    }

    /// Argon2id (RFC 9106): v=0x13, m=19456 KiB, t=2, p=1, tagLen=32 (matches Rust `argon2::Params::new(19456, 2, 1, Some(32))`).
    public static func deriveKey(password: String, salt: Data) throws -> Data {
        let cacheKey = "\(password)|\(salt.hexString)"
        keyCacheLock.lock()
        if let cached = keyCache[cacheKey] {
            keyCacheLock.unlock()
            return cached
        }
        keyCacheLock.unlock()

        let derived = Argon2idKDF.derive(
            password: Data(password.utf8),
            salt: salt,
            memoryKiB: 19456,
            iterations: 2,
            parallelism: 1,
            tagLength: 32
        )

        keyCacheLock.lock()
        keyCache[cacheKey] = derived
        keyCacheLock.unlock()
        return derived
    }
}

// MARK: - Media Byte Encryption Envelope (0x8F 0x3D magic compatible with Max+)

public enum MediaCrypto {
    public static let binaryMagic: [UInt8] = [0x8F, 0x3D]
    private static let legacyMagic = Data("MAXMEDIA\u{01}".utf8)

    public static func encryptMediaBytes(_ raw: Data, key: Data, dummyType: String = "pdf") throws -> Data {
        let nonce = SymmetricCrypto.randomBytes(12)
        let magicData = Data(binaryMagic)
        let ct = try SymmetricCrypto.encrypt(key: key, nonce: nonce, plaintext: raw, aad: magicData)

        let dummyHeader: Data
        switch dummyType {
        case "docx", "xlsx":
            dummyHeader = Data([0x50, 0x4B, 0x03, 0x04, 0x14, 0x00, 0x08, 0x00, 0x08, 0x00])
        case "mp3":
            dummyHeader = Data([0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x00])
        case "ogg":
            dummyHeader = Data([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0])
        default:
            dummyHeader = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        }

        var out = Data(capacity: dummyHeader.count + 2 + 12 + ct.count)
        out.append(dummyHeader)
        out.append(contentsOf: binaryMagic)
        out.append(nonce)
        out.append(ct)
        return out
    }

    public static func decryptMediaBytes(_ encrypted: Data, key: Data) throws -> Data {
        let magicData = Data(binaryMagic)
        if let range = encrypted.range(of: magicData) {
            let payload = encrypted[range.upperBound...]
            if payload.count >= 28 {
                let nonce = Data(payload.prefix(12))
                let ct = Data(payload.dropFirst(12))
                if let pt = try? SymmetricCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: ct, aad: magicData) {
                    return pt
                }
                if let pt = try? SymmetricCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: ct, aad: nil) {
                    return pt
                }
            }
        }
        if let range = encrypted.range(of: legacyMagic) {
            let payload = encrypted[range.upperBound...]
            if payload.count >= 28 {
                let nonce = Data(payload.prefix(12))
                let ct = Data(payload.dropFirst(12))
                if let pt = try? SymmetricCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: ct, aad: legacyMagic) {
                    return pt
                }
                if let pt = try? SymmetricCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: ct, aad: nil) {
                    return pt
                }
            }
        }
        if encrypted.count >= 28 {
            let nonce = Data(encrypted.prefix(12))
            let ct = Data(encrypted.dropFirst(12))
            if let pt = try? SymmetricCrypto.decrypt(key: key, nonce: nonce, ciphertextAndTag: ct, aad: nil) {
                return pt
            }
        }
        throw CryptoError.invalidCiphertext
    }
}

// MARK: - Pure Swift BLAKE2b + RFC 9106 Argon2id

enum BLAKE2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b,
        0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f,
        0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
    ]

    @inline(__always)
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    @inline(__always)
    private static func g(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
        v[a] = v[a] &+ v[b] &+ x
        v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = v[a] &+ v[b] &+ y
        v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = v[c] &+ v[d]
        v[b] = rotr(v[b] ^ v[c], 63)
    }

    private static func compress(_ h: inout [UInt64], block: UnsafeBufferPointer<UInt64>, t: UInt64, last: Bool) {
        var v = h + iv
        v[12] ^= t
        if last { v[14] ^= ~UInt64(0) }

        for r in 0..<12 {
            let s = sigma[r]
            g(&v, 0, 4, 8, 12, block[s[0]], block[s[1]])
            g(&v, 1, 5, 9, 13, block[s[2]], block[s[3]])
            g(&v, 2, 6, 10, 14, block[s[4]], block[s[5]])
            g(&v, 3, 7, 11, 15, block[s[6]], block[s[7]])
            g(&v, 0, 5, 10, 15, block[s[8]], block[s[9]])
            g(&v, 1, 6, 11, 12, block[s[10]], block[s[11]])
            g(&v, 2, 7, 8, 13, block[s[12]], block[s[13]])
            g(&v, 3, 4, 9, 14, block[s[14]], block[s[15]])
        }

        for i in 0..<8 {
            h[i] ^= v[i] ^ v[i + 8]
        }
    }

    static func hash(_ data: Data, outLength: Int) -> Data {
        var h = iv
        h[0] ^= 0x01010000 ^ UInt64(outLength)

        let bytes = Array(data)
        var blockBytes = [UInt8](repeating: 0, count: 128)
        var offset = 0
        var t: UInt64 = 0

        if bytes.isEmpty {
            blockBytes.withUnsafeBytes { raw in
                raw.bindMemory(to: UInt64.self).withMemoryRebound(to: UInt64.self, { ptr in
                    var le = [UInt64](repeating: 0, count: 16)
                    for i in 0..<16 { le[i] = UInt64(littleEndian: ptr[i]) }
                    le.withUnsafeBufferPointer { compress(&h, block: $0, t: 0, last: true) }
                })
            }
        } else {
            while offset + 128 < bytes.count {
                t &+= 128
                let slice = Array(bytes[offset..<(offset + 128)])
                var words = [UInt64](repeating: 0, count: 16)
                slice.withUnsafeBytes { raw in
                    for i in 0..<16 {
                        words[i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian
                    }
                }
                words.withUnsafeBufferPointer { compress(&h, block: $0, t: t, last: false) }
                offset += 128
            }

            let rem = bytes.count - offset
            t &+= UInt64(rem)
            for i in 0..<rem { blockBytes[i] = bytes[offset + i] }
            var words = [UInt64](repeating: 0, count: 16)
            blockBytes.withUnsafeBytes { raw in
                for i in 0..<16 {
                    words[i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian
                }
            }
            words.withUnsafeBufferPointer { compress(&h, block: $0, t: t, last: true) }
        }

        var out = Data(capacity: 64)
        for word in h {
            var le = word.littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return Data(out.prefix(outLength))
    }

    static func variableLengthHash(_ input: Data, outLength: Int) -> Data {
        var lenLE = UInt32(outLength).littleEndian
        var seed = Data(bytes: &lenLE, count: 4)
        seed.append(input)

        if outLength <= 64 {
            return hash(seed, outLength: outLength)
        }

        let r = ((outLength + 31) / 32) - 2
        var result = Data(capacity: outLength)
        var v = hash(seed, outLength: 64)
        result.append(v.prefix(32))

        for _ in 2...r {
            v = hash(v, outLength: 64)
            result.append(v.prefix(32))
        }

        let tailLen = outLength - 32 * r
        let vLast = hash(v, outLength: tailLen)
        result.append(vLast)
        return result
    }
}

private enum Argon2idKDF {
    private static let wordsPerBlock = 128 // 1024 bytes

    @inline(__always)
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 {
        (x >> n) | (x << (64 - n))
    }

    @inline(__always)
    private static func fBlaMka(_ x: UInt64, _ y: UInt64) -> UInt64 {
        let xl = x & 0xFFFF_FFFF
        let yl = y & 0xFFFF_FFFF
        return x &+ y &+ 2 &* (xl &* yl)
    }

    @inline(__always)
    private static func gRound(
        _ v: UnsafeMutablePointer<UInt64>,
        _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int,
        _ i4: Int, _ i5: Int, _ i6: Int, _ i7: Int,
        _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int,
        _ i12: Int, _ i13: Int, _ i14: Int, _ i15: Int
    ) {
        @inline(__always) func gb(_ a: inout UInt64, _ b: inout UInt64, _ c: inout UInt64, _ d: inout UInt64) {
            a = fBlaMka(a, b)
            d = rotr(d ^ a, 32)
            c = fBlaMka(c, d)
            b = rotr(b ^ c, 24)
            a = fBlaMka(a, b)
            d = rotr(d ^ a, 16)
            c = fBlaMka(c, d)
            b = rotr(b ^ c, 63)
        }
        var x0 = v[i0], x1 = v[i1], x2 = v[i2], x3 = v[i3]
        var x4 = v[i4], x5 = v[i5], x6 = v[i6], x7 = v[i7]
        var x8 = v[i8], x9 = v[i9], x10 = v[i10], x11 = v[i11]
        var x12 = v[i12], x13 = v[i13], x14 = v[i14], x15 = v[i15]

        gb(&x0, &x4, &x8, &x12)
        gb(&x1, &x5, &x9, &x13)
        gb(&x2, &x6, &x10, &x14)
        gb(&x3, &x7, &x11, &x15)
        gb(&x0, &x5, &x10, &x15)
        gb(&x1, &x6, &x11, &x12)
        gb(&x2, &x7, &x8, &x13)
        gb(&x3, &x4, &x9, &x14)

        v[i0] = x0; v[i1] = x1; v[i2] = x2; v[i3] = x3
        v[i4] = x4; v[i5] = x5; v[i6] = x6; v[i7] = x7
        v[i8] = x8; v[i9] = x9; v[i10] = x10; v[i11] = x11
        v[i12] = x12; v[i13] = x13; v[i14] = x14; v[i15] = x15
    }

    private static func fillBlock(
        prev: UnsafePointer<UInt64>,
        ref: UnsafePointer<UInt64>,
        dst: UnsafeMutablePointer<UInt64>,
        r: UnsafeMutablePointer<UInt64>,
        z: UnsafeMutablePointer<UInt64>,
        xorDst: Bool
    ) {
        for i in 0..<128 {
            let val = prev[i] ^ ref[i]
            r[i] = val
            z[i] = val
        }

        for i in 0..<8 {
            let b = 16 * i
            gRound(
                z,
                b + 0, b + 1, b + 2, b + 3,
                b + 4, b + 5, b + 6, b + 7,
                b + 8, b + 9, b + 10, b + 11,
                b + 12, b + 13, b + 14, b + 15
            )
        }

        for i in 0..<8 {
            let b = 2 * i
            gRound(
                z,
                b + 0, b + 1, b + 16, b + 17,
                b + 32, b + 33, b + 48, b + 49,
                b + 64, b + 65, b + 80, b + 81,
                b + 96, b + 97, b + 112, b + 113
            )
        }

        if xorDst {
            for i in 0..<128 {
                dst[i] ^= z[i] ^ r[i]
            }
        } else {
            for i in 0..<128 {
                dst[i] = z[i] ^ r[i]
            }
        }
    }

    private static func writeBytesToWords(_ data: Data, into dst: UnsafeMutablePointer<UInt64>) {
        data.withUnsafeBytes { raw in
            for i in 0..<128 {
                dst[i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian
            }
        }
    }

    private static func wordsToBytes(_ words: UnsafePointer<UInt64>) -> Data {
        var out = Data(capacity: 1024)
        for i in 0..<128 {
            var le = words[i].littleEndian
            withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
        }
        return out
    }

    static func derive(
        password: Data,
        salt: Data,
        memoryKiB: Int,
        iterations: Int,
        parallelism: Int,
        tagLength: Int
    ) -> Data {
        let syncPoints = 4
        let laneBlocks = (memoryKiB / (syncPoints * parallelism)) * syncPoints
        let segLen = laneBlocks / syncPoints

        func le32(_ v: Int) -> Data {
            var x = UInt32(v).littleEndian
            return Data(bytes: &x, count: 4)
        }

        var h0Input = Data()
        h0Input.append(le32(parallelism))
        h0Input.append(le32(tagLength))
        h0Input.append(le32(memoryKiB))
        h0Input.append(le32(iterations))
        h0Input.append(le32(0x13))
        h0Input.append(le32(2)) // Argon2id
        h0Input.append(le32(password.count))
        h0Input.append(password)
        h0Input.append(le32(salt.count))
        h0Input.append(salt)
        h0Input.append(le32(0))
        h0Input.append(le32(0))
        let h0 = BLAKE2b.hash(h0Input, outLength: 64)

        let memPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: laneBlocks * wordsPerBlock)
        memPtr.initialize(repeating: 0, count: laneBlocks * wordsPerBlock)
        defer { memPtr.deallocate() }

        let zeroPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        zeroPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { zeroPtr.deallocate() }

        let addrPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        addrPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { addrPtr.deallocate() }

        let inputPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        inputPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { inputPtr.deallocate() }

        let tmpPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        tmpPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { tmpPtr.deallocate() }

        let rPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        rPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { rPtr.deallocate() }

        let zPtr = UnsafeMutablePointer<UInt64>.allocate(capacity: wordsPerBlock)
        zPtr.initialize(repeating: 0, count: wordsPerBlock)
        defer { zPtr.deallocate() }

        func initBlock(_ idx: Int) {
            var inp = Data(capacity: 72)
            inp.append(h0)
            inp.append(le32(idx))
            inp.append(le32(0))
            let b = BLAKE2b.variableLengthHash(inp, outLength: 1024)
            writeBytesToWords(b, into: memPtr.advanced(by: idx * wordsPerBlock))
        }

        initBlock(0)
        initBlock(1)

        for pass in 0..<iterations {
            for slice in 0..<syncPoints {
                let dataIndependent = (pass == 0 && slice < 2)
                if dataIndependent {
                    inputPtr.update(repeating: 0, count: wordsPerBlock)
                    inputPtr[0] = UInt64(pass)
                    inputPtr[1] = 0
                    inputPtr[2] = UInt64(slice)
                    inputPtr[3] = UInt64(laneBlocks)
                    inputPtr[4] = UInt64(iterations)
                    inputPtr[5] = 2 // Argon2id
                }

                let startIdx = (pass == 0 && slice == 0) ? 2 : 0
                for idx in startIdx..<segLen {
                    let curOffset = slice * segLen + idx
                    let prevOffset = curOffset == 0 ? (laneBlocks - 1) : (curOffset - 1)

                    let j1: UInt32
                    if dataIndependent {
                        let slot = idx % 128
                        if slot == 0 || idx == startIdx {
                            inputPtr[6] = UInt64(idx / 128 + 1)
                            fillBlock(prev: zeroPtr, ref: inputPtr, dst: tmpPtr, r: rPtr, z: zPtr, xorDst: false)
                            fillBlock(prev: zeroPtr, ref: tmpPtr, dst: addrPtr, r: rPtr, z: zPtr, xorDst: false)
                        }
                        j1 = UInt32(truncatingIfNeeded: addrPtr[slot])
                    } else {
                        j1 = UInt32(truncatingIfNeeded: memPtr[prevOffset * wordsPerBlock])
                    }

                    let refAreaSize: Int
                    if pass == 0 {
                        refAreaSize = (slice * segLen) + idx - 1
                    } else {
                        refAreaSize = laneBlocks - segLen + idx - 1
                    }

                    var x = UInt64(j1)
                    x = (x &* x) >> 32
                    x = (UInt64(refAreaSize) &* x) >> 32
                    let zz = UInt64(refAreaSize) - 1 - x

                    let startPos: Int
                    if pass == 0 || slice == 3 {
                        startPos = 0
                    } else {
                        startPos = (slice + 1) * segLen
                    }
                    let refIdx = (startPos + Int(zz)) % laneBlocks

                    fillBlock(
                        prev: memPtr.advanced(by: prevOffset * wordsPerBlock),
                        ref: memPtr.advanced(by: refIdx * wordsPerBlock),
                        dst: memPtr.advanced(by: curOffset * wordsPerBlock),
                        r: rPtr,
                        z: zPtr,
                        xorDst: pass > 0
                    )
                }
            }
        }

        let lastPtr = memPtr.advanced(by: (laneBlocks - 1) * wordsPerBlock)
        return BLAKE2b.variableLengthHash(wordsToBytes(lastPtr), outLength: tagLength)
    }
}
