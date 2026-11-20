// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import Compression
import CryptoKit

public enum E2EPayload: Sendable, Equatable {
    case text(String)
    case media(text: String, media: MediaDescriptor)
    case handshake(Data)
}

public enum E2EProtocol {
    public static let protocolVersion: UInt8 = 0x00
    public static let flagSession: UInt8 = 1 << 5
    public static let flagPassword: UInt8 = 1 << 4
    public static let flagCompressed: UInt8 = 1 << 3
    public static let flagControl: UInt8 = 1 << 2

    public struct Header: Sendable, Equatable {
        public let version: UInt8
        public let hasSession: Bool
        public let hasPassword: Bool
        public let isCompressed: Bool
        public let isControl: Bool

        public func encode() -> UInt8 {
            ((version & 0x03) << 6)
                | (hasSession ? flagSession : 0)
                | (hasPassword ? flagPassword : 0)
                | (isCompressed ? flagCompressed : 0)
                | (isControl ? flagControl : 0)
        }

        public static func decode(_ byte: UInt8) -> Header {
            Header(
                version: (byte >> 6) & 0x03,
                hasSession: (byte & flagSession) != 0,
                hasPassword: (byte & flagPassword) != 0,
                isCompressed: (byte & flagCompressed) != 0,
                isControl: (byte & flagControl) != 0
            )
        }
    }

    public static func deriveChatSalt(chatId: Int64) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data("maxplus_chat_pwd_salt_v1:".utf8))
        var cidBE = chatId.bigEndian
        withUnsafeBytes(of: &cidBE) { hasher.update(data: Data($0)) }
        return Data(Data(hasher.finalize()).prefix(16))
    }

    public static func compressRawDeflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return Data() }
        let cap = max(data.count + 128, 256)
        var dst = [UInt8](repeating: 0, count: cap)
        let written = data.withUnsafeBytes { srcRaw -> Int in
            guard let srcPtr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
            return compression_encode_buffer(&dst, cap, srcPtr, data.count, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { return nil }
        return Data(dst.prefix(written))
    }

    public static func decompressRawDeflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        var cap = max(data.count * 8, 65536)
        while cap <= 8 * 1024 * 1024 {
            var dst = [UInt8](repeating: 0, count: cap)
            let written = data.withUnsafeBytes { srcRaw -> Int in
                guard let srcPtr = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return compression_decode_buffer(&dst, cap, srcPtr, data.count, nil, COMPRESSION_ZLIB)
            }
            if written == 0 {
                throw CryptoError.compressionFailed
            }
            if written < cap {
                return Data(dst.prefix(written))
            }
            cap *= 2
        }
        throw CryptoError.compressionFailed
    }

    public static func packMessage(
        payload: E2EPayload,
        sessionKey: Data? = nil,
        password: String? = nil,
        chatId: Int64? = nil
    ) throws -> Data {
        let isControl: Bool
        var rawBytes: Data

        switch payload {
        case .text(let text):
            isControl = false
            rawBytes = Data([0x01]) + Data(text.utf8)
        case .media(let text, let media):
            isControl = false
            let mediaArr: JSONValue = .array([
                .int(Int64(media.attachIndex)),
                .string(media.name),
                .string(media.mime),
                .string(media.mediaType),
                .int(Int64(media.size)),
                media.width.map { .int(Int64($0)) } ?? .null,
                media.height.map { .int(Int64($0)) } ?? .null,
                media.duration.map { .double($0) } ?? .null,
                media.wave.map { .array($0.map { .int(Int64($0)) }) } ?? .null,
                media.videoType.map { .int(Int64($0)) } ?? .null,
                media.color.map { .string($0) } ?? .null,
            ])
            let tupleBytes = try MsgPack.encode(.array([.string(text), mediaArr]))
            rawBytes = Data([0x02]) + tupleBytes
        case .handshake(let hsBytes):
            isControl = true
            rawBytes = hsBytes
        }

        var isCompressed = false
        if !isControl && rawBytes.count >= 64 {
            if let compressed = compressRawDeflate(rawBytes), compressed.count < rawBytes.count {
                rawBytes = compressed
                isCompressed = true
            }
        }

        let cleanPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? password : nil
        let hasSession = (sessionKey?.count == 32)
        if let sKey = sessionKey, sKey.count == 32 {
            let nonce = SymmetricCrypto.randomBytes(12)
            let ct = try SymmetricCrypto.encrypt(key: sKey, nonce: nonce, plaintext: rawBytes)
            rawBytes = nonce + ct
        }

        let hasPassword = cleanPassword != nil
        if let pwd = cleanPassword {
            let salt = chatId.map { deriveChatSalt(chatId: $0) } ?? SymmetricCrypto.randomBytes(16)
            let nonce = SymmetricCrypto.randomBytes(12)
            let pKey = try SymmetricCrypto.deriveKey(password: pwd, salt: salt)
            let ct = try SymmetricCrypto.encrypt(key: pKey, nonce: nonce, plaintext: rawBytes)
            rawBytes = salt + nonce + ct
        }

        let header = Header(
            version: protocolVersion,
            hasSession: hasSession,
            hasPassword: hasPassword,
            isCompressed: isCompressed,
            isControl: isControl
        )
        return Data([header.encode()]) + rawBytes
    }

    public static func unpackMessage(
        bytes: Data,
        sessionKey: Data? = nil,
        password: String? = nil
    ) throws -> E2EPayload {
        guard let first = bytes.first else {
            throw CryptoError.invalidPacket("Empty E2E packet")
        }
        let header = Header.decode(first)
        guard header.version == protocolVersion else {
            throw CryptoError.invalidPacket("Unsupported protocol version")
        }

        var current = Data(bytes.dropFirst())
        let cleanPassword = password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? password : nil

        if header.hasPassword {
            guard let pwd = cleanPassword else {
                throw CryptoError.missingPassword
            }
            guard current.count >= 16 + 12 + 16 else {
                throw CryptoError.invalidPacket("Password payload too short")
            }
            let salt = Data(current.prefix(16))
            let nonce = Data(current.dropFirst(16).prefix(12))
            let ct = Data(current.dropFirst(28))
            let pKey = try SymmetricCrypto.deriveKey(password: pwd, salt: salt)
            do {
                current = try SymmetricCrypto.decrypt(key: pKey, nonce: nonce, ciphertextAndTag: ct)
            } catch {
                throw CryptoError.wrongPassword
            }
        }

        if header.hasSession {
            guard let sKey = sessionKey, sKey.count == 32 else {
                throw CryptoError.missingSessionKey
            }
            guard current.count >= 12 + 16 else {
                throw CryptoError.invalidPacket("Session payload too short")
            }
            let nonce = Data(current.prefix(12))
            let ct = Data(current.dropFirst(12))
            do {
                current = try SymmetricCrypto.decrypt(key: sKey, nonce: nonce, ciphertextAndTag: ct)
            } catch {
                throw CryptoError.failedSessionDecryption
            }
        }

        if header.isCompressed {
            current = try decompressRawDeflate(current)
        }

        if header.isControl {
            return .handshake(current)
        }

        guard let tag = current.first else {
            return .text("")
        }

        let body = Data(current.dropFirst())
        switch tag {
        case 0x01:
            return .text(String(decoding: body, as: UTF8.self))
        case 0x02:
            let val = try MsgPack.decode(body)
            guard let tuple = val.arrayValue, tuple.count >= 2,
                  let text = tuple[0].stringValue
            else {
                throw CryptoError.invalidPacket("Invalid media payload envelope")
            }
            if let arr = tuple[1].arrayValue, arr.count >= 5 {
                let media = MediaDescriptor(
                    attachIndex: Int(arr[0].int64Value ?? 0),
                    name: arr[1].stringValue ?? "attachment",
                    mime: arr[2].stringValue ?? "application/octet-stream",
                    mediaType: arr[3].stringValue ?? "FILE",
                    size: UInt64(max(0, arr[4].int64Value ?? 0)),
                    width: arr.count > 5 ? arr[5].int64Value.map { UInt32(max(0, $0)) } : nil,
                    height: arr.count > 6 ? arr[6].int64Value.map { UInt32(max(0, $0)) } : nil,
                    duration: arr.count > 7 ? arr[7].doubleValue : nil,
                    wave: arr.count > 8 ? arr[8].bytesValue : nil,
                    videoType: arr.count > 9 ? arr[9].int64Value.map { Int32($0) } : nil,
                    color: arr.count > 10 ? arr[10].stringValue : nil
                )
                return .media(text: text, media: media)
            }
            throw CryptoError.invalidPacket("Unsupported MediaDescriptor shape")
        default:
            if let s = String(data: current, encoding: .utf8) {
                return .text(s)
            }
            throw CryptoError.invalidPacket("Unknown payload format")
        }
    }
}
