import Foundation
import CryptoKit

public struct KeypairBundle: Sendable, Equatable {
    public let edSk: Data
    public let edPk: Data
    public let xSk: Data
    public let xPk: Data

    public func toHexStruct(timestamp: Int64? = nil) -> KeypairBundleHex {
        KeypairBundleHex(
            edSkHex: edSk.hexString,
            edPkHex: edPk.hexString,
            xSkHex: xSk.hexString,
            xPkHex: xPk.hexString,
            timestamp: timestamp
        )
    }
}

public struct ParsedHandshake: Sendable, Equatable {
    public let subtype: UInt8
    public let edPk: Data
    public let xPk: Data
    public let timestamp: Int64
}

public struct GroupWrappedKeyEntry: Sendable, Equatable {
    public let recipientXPk: Data
    public let nonce: Data
    public let ciphertext: Data
}

public struct ParsedGroupKeyWrap: Sendable, Equatable {
    public let senderEdPk: Data
    public let senderXPk: Data
    public let timestamp: Int64
    public let recipientCount: Int
}

public enum AsymmetricCrypto {
    public static let handshakeInit: UInt8 = 0x01
    public static let handshakeAccept: UInt8 = 0x02
    public static let groupKeyAnnounce: UInt8 = 0x03
    public static let groupKeyWrap: UInt8 = 0x04

    public static func generateKeypairBundle() -> KeypairBundle {
        let edKey = Curve25519.Signing.PrivateKey()
        let xKey = Curve25519.KeyAgreement.PrivateKey()
        return KeypairBundle(
            edSk: edKey.rawRepresentation,
            edPk: edKey.publicKey.rawRepresentation,
            xSk: xKey.rawRepresentation,
            xPk: xKey.publicKey.rawRepresentation
        )
    }

    public static func computeSharedSecret(myXSk: Data, peerXPk: Data) throws -> Data {
        let sk = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myXSk)
        let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerXPk)
        let shared = try sk.sharedSecretFromKeyAgreement(with: pk)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }

        var hasher = SHA256()
        hasher.update(data: Data("maxplus-e2e-session-v1".utf8))
        hasher.update(data: sharedBytes)
        return Data(hasher.finalize())
    }

    public static func signData(edSk: Data, data: Data) throws -> Data {
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: edSk)
        return try key.signature(for: data)
    }

    public static func verifySignature(edPk: Data, data: Data, signature: Data) -> Bool {
        guard let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: edPk), signature.count == 64 else {
            return false
        }
        return pub.isValidSignature(signature, for: data)
    }

    private static func createSignedHandshakePacket(
        subtype: UInt8,
        edSk: Data,
        edPk: Data,
        xPk: Data,
        timestamp: Int64
    ) throws -> Data {
        guard edPk.count == 32, xPk.count == 32 else { throw CryptoError.invalidKeyLength }
        var body = Data(capacity: 73)
        body.append(subtype)
        body.append(edPk)
        body.append(xPk)
        var tsBE = timestamp.bigEndian
        withUnsafeBytes(of: &tsBE) { body.append(contentsOf: $0) }

        let sig = try signData(edSk: edSk, data: body)
        return body + sig
    }

    public static func createHandshakeInit(edSk: Data, edPk: Data, xPk: Data, timestamp: Int64) throws -> Data {
        try createSignedHandshakePacket(subtype: handshakeInit, edSk: edSk, edPk: edPk, xPk: xPk, timestamp: timestamp)
    }

    public static func createHandshakeAccept(edSk: Data, edPk: Data, xPk: Data, timestamp: Int64) throws -> Data {
        try createSignedHandshakePacket(subtype: handshakeAccept, edSk: edSk, edPk: edPk, xPk: xPk, timestamp: timestamp)
    }

    public static func createGroupKeyAnnounce(edSk: Data, edPk: Data, xPk: Data, timestamp: Int64) throws -> Data {
        try createSignedHandshakePacket(subtype: groupKeyAnnounce, edSk: edSk, edPk: edPk, xPk: xPk, timestamp: timestamp)
    }

    public static func parseAndVerifyHandshake(_ bytes: Data) throws -> ParsedHandshake {
        guard bytes.count == 1 + 32 + 32 + 8 + 64 else {
            throw CryptoError.invalidPacket("Неверная длина пакета рукопожатия")
        }
        let subtype = bytes[0]
        guard subtype == handshakeInit || subtype == handshakeAccept || subtype == groupKeyAnnounce else {
            throw CryptoError.invalidPacket("Неизвестный тип рукопожатия")
        }
        let edPk = Data(bytes[1..<33])
        let xPk = Data(bytes[33..<65])
        let tsSlice = bytes[65..<73]
        var tsRaw: Int64 = 0
        _ = withUnsafeMutableBytes(of: &tsRaw) { tsSlice.copyBytes(to: $0) }
        let timestamp = Int64(bigEndian: tsRaw)
        let sig = Data(bytes[73..<137])

        guard verifySignature(edPk: edPk, data: Data(bytes[0..<73]), signature: sig) else {
            throw CryptoError.invalidPacket("Подпись рукопожатия недействительна")
        }
        return ParsedHandshake(subtype: subtype, edPk: edPk, xPk: xPk, timestamp: timestamp)
    }

    // Wire-compatible with Rust `rmp_serde` array representation of GroupKeyWrapBody / GroupKeyWrapWire.
    public static func createGroupKeyWrap(
        senderEdSk: Data,
        senderEdPk: Data,
        senderXSk: Data,
        senderXPk: Data,
        groupSecret: Data,
        recipientXPks: [Data],
        timestamp: Int64
    ) throws -> Data {
        guard senderEdPk.count == 32, senderXPk.count == 32, groupSecret.count == 32 else {
            throw CryptoError.invalidKeyLength
        }

        var recipientArrays: [JSONValue] = []
        recipientArrays.reserveCapacity(recipientXPks.count)

        for pk in recipientXPks {
            guard pk.count == 32 else { throw CryptoError.invalidKeyLength }
            let pairKey = try computeSharedSecret(myXSk: senderXSk, peerXPk: pk)
            let nonce = SymmetricCrypto.randomBytes(12)
            let ct = try SymmetricCrypto.encrypt(key: pairKey, nonce: nonce, plaintext: groupSecret, aad: pk)
            recipientArrays.append(.array([
                byteArrayJSON(pk),
                byteArrayJSON(nonce),
                byteArrayJSON(ct),
            ]))
        }

        let bodyValue: JSONValue = .array([
            byteArrayJSON(senderEdPk),
            byteArrayJSON(senderXPk),
            .int(timestamp),
            .array(recipientArrays),
        ])
        let bodyBytes = try MsgPack.encode(bodyValue)

        var signPayload = Data(capacity: 1 + bodyBytes.count)
        signPayload.append(groupKeyWrap)
        signPayload.append(bodyBytes)
        let sig = try signData(edSk: senderEdSk, data: signPayload)

        let wireValue: JSONValue = .array([
            byteArrayJSON(bodyBytes),
            byteArrayJSON(sig),
        ])
        let wireBytes = try MsgPack.encode(wireValue)

        var packet = Data(capacity: 1 + wireBytes.count)
        packet.append(groupKeyWrap)
        packet.append(wireBytes)
        return packet
    }

    public static func parseAndUnwrapGroupKey(
        _ bytes: Data,
        myXSk: Data?,
        myXPk: Data?
    ) throws -> (ParsedGroupKeyWrap, Data?) {
        guard let first = bytes.first, first == groupKeyWrap else {
            throw CryptoError.invalidPacket("Неверный заголовок пакета группового ключа")
        }

        let wireVal = try MsgPack.decode(Data(bytes.dropFirst()))
        guard
            let wireArr = wireVal.arrayValue,
            wireArr.count >= 2,
            let bodyByteArr = wireArr[0].bytesValue,
            let sigByteArr = wireArr[1].bytesValue
        else {
            throw CryptoError.invalidPacket("Некорректная структура wire группового ключа")
        }

        let bodyBytes = Data(bodyByteArr)
        let sig = Data(sigByteArr)
        guard sig.count == 64 else {
            throw CryptoError.invalidPacket("Неверная длина подписи группового ключа")
        }

        let bodyVal = try MsgPack.decode(bodyBytes)
        guard
            let bodyArr = bodyVal.arrayValue,
            bodyArr.count >= 4,
            let senderEdBytes = bodyArr[0].bytesValue,
            let senderXBytes = bodyArr[1].bytesValue,
            let ts = bodyArr[2].int64Value,
            let recipientsVal = bodyArr[3].arrayValue
        else {
            throw CryptoError.invalidPacket("Некорректное тело пакета группового ключа")
        }

        let senderEdPk = Data(senderEdBytes)
        let senderXPk = Data(senderXBytes)

        var signPayload = Data(capacity: 1 + bodyBytes.count)
        signPayload.append(groupKeyWrap)
        signPayload.append(bodyBytes)
        guard verifySignature(edPk: senderEdPk, data: signPayload, signature: sig) else {
            throw CryptoError.invalidPacket("Недействительная подпись пакета группового ключа")
        }

        var unwrapped: Data?
        if let sk = myXSk, let pk = myXPk {
            for item in recipientsVal {
                guard
                    let entry = item.arrayValue,
                    entry.count >= 3,
                    let recPkBytes = entry[0].bytesValue,
                    let nonceBytes = entry[1].bytesValue,
                    let ctBytes = entry[2].bytesValue
                else {
                    continue
                }
                let recPk = Data(recPkBytes)
                if recPk == pk {
                    let pairKey = try computeSharedSecret(myXSk: sk, peerXPk: senderXPk)
                    let plain = try SymmetricCrypto.decrypt(
                        key: pairKey,
                        nonce: Data(nonceBytes),
                        ciphertextAndTag: Data(ctBytes),
                        aad: pk
                    )
                    guard plain.count == 32 else {
                        throw CryptoError.invalidKeyLength
                    }
                    unwrapped = plain
                    break
                }
            }
        }

        return (
            ParsedGroupKeyWrap(
                senderEdPk: senderEdPk,
                senderXPk: senderXPk,
                timestamp: ts,
                recipientCount: recipientsVal.count
            ),
            unwrapped
        )
    }

    private static func byteArrayJSON(_ data: Data) -> JSONValue {
        .array(data.map { .int(Int64($0)) })
    }
}
