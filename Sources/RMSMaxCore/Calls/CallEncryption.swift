import Foundation
import CryptoKit

public final class CallEncryptionSession: @unchecked Sendable {
    public enum Mode: String, Sendable {
        case plain
        case secure
    }

    private let lock = NSLock()
    private var _mode: Mode = .plain
    private var _fingerprint: String?
    private var _isOriginator = true
    private var _bypassEncrypt = false
    private var _bypassDecrypt = false

    private var audioSendKey: SymmetricKey?
    private var audioRecvKey: SymmetricKey?
    private var videoSendKey: SymmetricKey?
    private var videoRecvKey: SymmetricKey?

    public var mode: Mode {
        lock.withLock { _mode }
    }

    public var fingerprint: String? {
        lock.withLock { _fingerprint }
    }

    public init() {}

    public func initPlain() {
        lock.withLock {
            _mode = .plain
            _fingerprint = nil
            audioSendKey = nil
            audioRecvKey = nil
            videoSendKey = nil
            videoRecvKey = nil
        }
    }

    public func setBypass(encrypt: Bool? = nil, decrypt: Bool? = nil) {
        lock.withLock {
            if let encrypt { _bypassEncrypt = encrypt }
            if let decrypt { _bypassDecrypt = decrypt }
        }
    }

    private func normalizeSecretBytes(_ secret: String) -> Data {
        if secret.count == 64, let hexData = Data(hexString: secret) {
            return hexData
        }
        return Data(SHA256.hash(data: Data(secret.utf8)))
    }

    public func initFromChatSecret(_ chatSecret: String, conversationId: String, isOriginator: Bool = true) {
        initFromSecretData(normalizeSecretBytes(chatSecret), conversationId: conversationId, isOriginator: isOriginator)
    }

    public func initFromSecretData(_ rawSecret: Data, conversationId: String, isOriginator: Bool = true) {
        let salt = Data(SHA256.hash(data: Data("maxplus-call-media-salt-v3|\(conversationId)".utf8)))
        deriveSessionKeys(rawSecret: rawSecret, salt: salt, isOriginator: isOriginator, symmetricGroup: false)
    }

    public func initGroupFromSecret(_ groupSecret: String, conversationId: String) {
        let raw = normalizeSecretBytes(groupSecret)
        let salt = Data(SHA256.hash(data: Data("maxplus-group-call-media-salt-v1|\(conversationId)".utf8)))
        deriveSessionKeys(rawSecret: raw, salt: salt, isOriginator: true, symmetricGroup: true)
    }

    private func deriveSessionKeys(rawSecret: Data, salt: Data, isOriginator: Bool, symmetricGroup: Bool) {
        let inputKey = SymmetricKey(data: rawSecret)

        func deriveAES128Key(info: String) -> SymmetricKey {
            let derived = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: inputKey,
                salt: salt,
                info: Data(info.utf8),
                outputByteCount: 24
            )
            let bytes = derived.withUnsafeBytes { Data($0.prefix(16)) }
            return SymmetricKey(data: bytes)
        }

        let aSend: SymmetricKey
        let aRecv: SymmetricKey
        let vSend: SymmetricKey
        let vRecv: SymmetricKey

        if symmetricGroup {
            aSend = deriveAES128Key(info: "maxplus-v2-group-audio")
            aRecv = aSend
            vSend = deriveAES128Key(info: "maxplus-v2-group-video")
            vRecv = vSend
        } else {
            aSend = deriveAES128Key(info: isOriginator ? "maxplus-v2-audio-orig-to-resp" : "maxplus-v2-audio-resp-to-orig")
            aRecv = deriveAES128Key(info: isOriginator ? "maxplus-v2-audio-resp-to-orig" : "maxplus-v2-audio-orig-to-resp")
            vSend = deriveAES128Key(info: isOriginator ? "maxplus-v2-video-orig-to-resp" : "maxplus-v2-video-resp-to-orig")
            vRecv = deriveAES128Key(info: isOriginator ? "maxplus-v2-video-resp-to-orig" : "maxplus-v2-video-orig-to-resp")
        }

        let fpKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data("maxplus-fingerprint-v2".utf8),
            outputByteCount: 8
        )
        let fpHex = fpKey.withUnsafeBytes { Data($0).hexString.uppercased() }
        var fpParts: [String] = []
        var idx = fpHex.startIndex
        while idx < fpHex.endIndex {
            let next = fpHex.index(idx, offsetBy: 4, limitedBy: fpHex.endIndex) ?? fpHex.endIndex
            fpParts.append(String(fpHex[idx..<next]))
            idx = next
        }
        let fpString = fpParts.joined(separator: "-")

        lock.withLock {
            _mode = .secure
            _isOriginator = isOriginator
            _fingerprint = fpString
            audioSendKey = aSend
            audioRecvKey = aRecv
            videoSendKey = vSend
            videoRecvKey = vRecv
        }
    }

    public func encryptFrame(_ raw: Data, kind: CallMediaKind = .audio) -> Data {
        let (mode, bypass, encKey) = lock.withLock {
            (_mode, _bypassEncrypt, kind == .video ? videoSendKey : audioSendKey)
        }
        guard mode == .secure, !bypass, let encKey else { return raw }

        let unencryptedBytes = CallFrameHeader.unencryptedBytes(raw: raw, kind: kind)
        guard raw.count > unencryptedBytes else { return raw }

        let payload = raw.dropFirst(unencryptedBytes)
        let ivBytes = SymmetricCrypto.randomBytes(12)
        guard
            let nonce = try? AES.GCM.Nonce(data: ivBytes),
            let sealed = try? AES.GCM.seal(payload, using: encKey, nonce: nonce)
        else {
            return raw
        }

        let cipherAndTag = sealed.ciphertext + sealed.tag
        var result = Data(capacity: unencryptedBytes + cipherAndTag.count + 14)
        result.append(raw.prefix(unencryptedBytes))
        result.append(cipherAndTag)
        result.append(ivBytes)
        result.append(0x0c)
        result.append(0x00)
        return result
    }

    public func decryptFrame(_ raw: Data, kind: CallMediaKind = .audio) -> Data? {
        let (mode, bypass, decKey) = lock.withLock {
            (_mode, _bypassDecrypt, kind == .video ? videoRecvKey : audioRecvKey)
        }
        if bypass { return raw }

        let unencryptedBytes = CallFrameHeader.unencryptedBytes(raw: raw, kind: kind)
        let bytes = Array(raw)
        let isEncrypted = bytes.count >= unencryptedBytes + 30
            && bytes[bytes.count - 2] == 0x0c
            && bytes[bytes.count - 1] == 0x00

        guard isEncrypted else { return raw }
        guard let decKey else { return mode == .plain ? raw : nil }

        let ctAndTag = Data(bytes[unencryptedBytes..<(bytes.count - 14)])
        let ivBytes = Data(bytes[(bytes.count - 14)..<(bytes.count - 2)])
        guard ctAndTag.count >= 16,
              let nonce = try? AES.GCM.Nonce(data: ivBytes)
        else { return nil }

        let split = ctAndTag.count - 16
        let ct = ctAndTag.prefix(split)
        let tag = ctAndTag.suffix(16)
        guard let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag),
              let plain = try? AES.GCM.open(box, using: decKey)
        else {
            return nil
        }

        return Data(bytes[0..<unencryptedBytes]) + plain
    }

    // MARK: - Ephemeral P-256 Call ECDH

    public static func generateCallKeyPair() -> P256.KeyAgreement.PrivateKey {
        P256.KeyAgreement.PrivateKey()
    }

    public static func exportPublicKeyBytes(_ privateKey: P256.KeyAgreement.PrivateKey) -> Data {
        privateKey.publicKey.x963Representation // 65-byte uncompressed X9.63 (matches WebCrypto 'raw' P-256)
    }

    public static func deriveSharedSecret(
        myPrivateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKeyBytes: Data
    ) throws -> Data {
        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKeyBytes)
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: peerPub)
        return shared.withUnsafeBytes { Data($0) }
    }
}
