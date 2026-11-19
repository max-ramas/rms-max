import XCTest
import CryptoKit
import AVFoundation
@testable import RMSMaxCore

final class RMSMaxCoreTests: XCTestCase {

    // MARK: - 1. MsgPack Round-Trip

    func testMsgPackRoundTripWithBinaryKeys() throws {
        // Max binary keys ("mode", "wave", "previewData", "chatCacheFingerprint", "chatsCountGroups")
        // encode arrays / `.binary` as MsgPack bin8/16/32 (0xC4/0xC5/0xC6), and decode using lossy UTF-8 string
        // parity with rumax (`MsgPackValue::Binary => String::from_utf8_lossy`).
        let asciiBin = Data("bin-tag".utf8)
        let original: JSONValue = .object([
            "intPos": .int(42),
            "intNeg": .int(-1234567890123),
            "boolTrue": .bool(true),
            "boolFalse": .bool(false),
            "doubleVal": .double(3.14159),
            "text": .string("Привет, RMS MAX!"),
            "nullVal": .null,
            "mode": .array([.int(1), .int(2), .int(3)]),
            "wave": .binary(Data([0x41, 0x42, 0x43])),
            "previewData": .string("JPG!"),
            "chatCacheFingerprint": .array([.int(0x41), .int(0x42)]),
            "chatsCountGroups": .array([.int(0x0A), .int(0x32)]),
            "binAscii": .binary(asciiBin),
            "nested": .array([
                .int(1),
                .object(["inner": .string("ok"), "emptyBin": .binary(Data())]),
            ]),
        ])

        let encoded = try MsgPack.encode(original)
        // Verify Max binary key encoding emits 0xC4 bin8 headers (e.g. `wave` key followed by 0xC4 0x03 "ABC")
        let expectedWaveSequence = Data([0xA4]) + Data("wave".utf8) + Data([0xC4, 0x03, 0x41, 0x42, 0x43])
        XCTAssertNotNil(encoded.range(of: expectedWaveSequence))
        let expectedModeSequence = Data([0xA4]) + Data("mode".utf8) + Data([0xC4, 0x03, 0x01, 0x02, 0x03])
        XCTAssertNotNil(encoded.range(of: expectedModeSequence))

        let decoded = try MsgPack.decode(encoded)

        XCTAssertEqual(decoded["intPos"]?.int64Value, 42)
        XCTAssertEqual(decoded["intNeg"]?.int64Value, -1234567890123)
        XCTAssertEqual(decoded["boolTrue"], .bool(true))
        XCTAssertEqual(decoded["boolFalse"], .bool(false))
        if case .double(let d)? = decoded["doubleVal"] {
            XCTAssertEqual(d, 3.14159, accuracy: 1e-9)
        } else {
            XCTFail("Expected doubleVal")
        }
        XCTAssertEqual(decoded["text"]?.stringValue, "Привет, RMS MAX!")
        XCTAssertEqual(decoded["nullVal"], .null)
        XCTAssertEqual(decoded["wave"]?.stringValue, "ABC")
        XCTAssertEqual(decoded["previewData"]?.stringValue, "JPG!")
        XCTAssertEqual(decoded["chatCacheFingerprint"]?.stringValue, "AB")
        XCTAssertEqual(decoded["chatsCountGroups"]?.stringValue, "\n2")
        XCTAssertEqual(decoded["binAscii"]?.stringValue, "bin-tag")
        XCTAssertEqual(decoded["nested"]?[0]?.int64Value, 1)
        XCTAssertEqual(decoded["nested"]?[1]?["inner"]?.stringValue, "ok")
        XCTAssertEqual(decoded["nested"]?[1]?["emptyBin"]?.stringValue, "")
    }

    // MARK: - 2. LZ4 Block Decompression

    func testLZ4BlockDecompressSyntheticSequence() throws {
        // Compress "ABCDE" (5 literals) + match(offset=4, len=6 -> "BCDEBC") + "XYZ" (3 literals)
        // Token 1: literalLen = 5, matchLenMinus4 = 2 => (5 << 4) | 2 = 0x52
        // Literals: 'A','B','C','D','E'
        // Offset (LE): 0x04, 0x00 ("BCDE", copy 6 bytes -> overlapping "BCDEBC")
        // Token 2: literalLen = 3, matchLen = 0 (end of block) => (3 << 4) = 0x30
        // Literals: 'X','Y','Z'
        let compressed = Data([
            0x52,
            0x41, 0x42, 0x43, 0x44, 0x45,
            0x04, 0x00,
            0x30,
            0x58, 0x59, 0x5A,
        ])

        let decompressed = try LZ4Block.decompress(compressed)
        XCTAssertEqual(String(data: decompressed, encoding: .utf8), "ABCDEBCDEBCXYZ")
    }

    // MARK: - 3. APK Build Fingerprint

    func testFingerprintGenerator96Bytes() throws {
        let versionData = try XCTUnwrap(ApkBuildFingerprint.embeddedVersions["26.31.0"])
        let fp = FingerprintGenerator.generate(
            versionData: versionData,
            deviceId: "0123456789abcdef0123456789abcdef",
            callsSeed: 987654321,
            arch: "arm64-v8a"
        )
        let bytes = try XCTUnwrap(fp)
        XCTAssertEqual(bytes.count, 96)

        let fpAgain = FingerprintGenerator.generate(
            versionData: versionData,
            deviceId: "0123456789abcdef0123456789abcdef",
            callsSeed: 987654321,
            arch: "arm64-v8a"
        )
        XCTAssertEqual(bytes, fpAgain)
    }

    // MARK: - 4. Asymmetric Crypto: 1:1 Handshake & Group Key Wrap / Rotation

    func testAsymmetricHandshake1on1AndTamperRejection() throws {
        let alice = AsymmetricCrypto.generateKeypairBundle()
        let bob = AsymmetricCrypto.generateKeypairBundle()
        let ts: Int64 = 1_760_000_000_000

        let initPkt = try AsymmetricCrypto.createHandshakeInit(
            edSk: alice.edSk,
            edPk: alice.edPk,
            xPk: alice.xPk,
            timestamp: ts
        )
        XCTAssertEqual(initPkt.first, AsymmetricCrypto.handshakeInit)

        let parsedInit = try AsymmetricCrypto.parseAndVerifyHandshake(initPkt)
        XCTAssertEqual(parsedInit.subtype, AsymmetricCrypto.handshakeInit)
        XCTAssertEqual(parsedInit.edPk, alice.edPk)
        XCTAssertEqual(parsedInit.xPk, alice.xPk)
        XCTAssertEqual(parsedInit.timestamp, ts)

        let acceptPkt = try AsymmetricCrypto.createHandshakeAccept(
            edSk: bob.edSk,
            edPk: bob.edPk,
            xPk: bob.xPk,
            timestamp: ts + 100
        )
        let parsedAccept = try AsymmetricCrypto.parseAndVerifyHandshake(acceptPkt)
        XCTAssertEqual(parsedAccept.subtype, AsymmetricCrypto.handshakeAccept)

        let secretAlice = try AsymmetricCrypto.computeSharedSecret(myXSk: alice.xSk, peerXPk: parsedAccept.xPk)
        let secretBob = try AsymmetricCrypto.computeSharedSecret(myXSk: bob.xSk, peerXPk: parsedInit.xPk)
        XCTAssertEqual(secretAlice, secretBob)
        XCTAssertEqual(secretAlice.count, 32)
        XCTAssertFalse(EmojiFingerprint.generate(sharedSecret: secretAlice).isEmpty)

        // Tamper signature byte
        var tampered = initPkt
        tampered[tampered.count - 1] ^= 0xFF
        XCTAssertThrowsError(try AsymmetricCrypto.parseAndVerifyHandshake(tampered))
    }

    func testGroupE2EThreePartyWrapAndRotation() throws {
        let alice = AsymmetricCrypto.generateKeypairBundle()
        let bob = AsymmetricCrypto.generateKeypairBundle()
        let charlie = AsymmetricCrypto.generateKeypairBundle()
        let eve = AsymmetricCrypto.generateKeypairBundle()

        // Step A: Participants announce keys with 0x03
        let bobAnnounce = try AsymmetricCrypto.createGroupKeyAnnounce(
            edSk: bob.edSk,
            edPk: bob.edPk,
            xPk: bob.xPk,
            timestamp: 100
        )
        let parsedBob = try AsymmetricCrypto.parseAndVerifyHandshake(bobAnnounce)
        XCTAssertEqual(parsedBob.subtype, AsymmetricCrypto.groupKeyAnnounce)

        // Step B: Alice generates group secret 1 and wraps it for [Bob, Charlie] using 0x04
        let groupSecretV1 = SymmetricCrypto.randomBytes(32)
        let wrapV1 = try AsymmetricCrypto.createGroupKeyWrap(
            senderEdSk: alice.edSk,
            senderEdPk: alice.edPk,
            senderXSk: alice.xSk,
            senderXPk: alice.xPk,
            groupSecret: groupSecretV1,
            recipientXPks: [bob.xPk, charlie.xPk],
            timestamp: 200
        )
        XCTAssertEqual(wrapV1.first, AsymmetricCrypto.groupKeyWrap)

        let (headerBob, unwrappedBob) = try AsymmetricCrypto.parseAndUnwrapGroupKey(
            wrapV1,
            myXSk: bob.xSk,
            myXPk: bob.xPk
        )
        XCTAssertEqual(headerBob.recipientCount, 2)
        XCTAssertEqual(headerBob.senderEdPk, alice.edPk)
        XCTAssertEqual(unwrappedBob, groupSecretV1)

        let (_, unwrappedCharlie) = try AsymmetricCrypto.parseAndUnwrapGroupKey(
            wrapV1,
            myXSk: charlie.xSk,
            myXPk: charlie.xPk
        )
        XCTAssertEqual(unwrappedCharlie, groupSecretV1)

        let (_, unwrappedEve) = try AsymmetricCrypto.parseAndUnwrapGroupKey(
            wrapV1,
            myXSk: eve.xSk,
            myXPk: eve.xPk
        )
        XCTAssertNil(unwrappedEve)

        // Step C: Rotate key (remove Charlie, keep Bob)
        let groupSecretV2 = SymmetricCrypto.randomBytes(32)
        XCTAssertNotEqual(groupSecretV1, groupSecretV2)
        let wrapV2 = try AsymmetricCrypto.createGroupKeyWrap(
            senderEdSk: alice.edSk,
            senderEdPk: alice.edPk,
            senderXSk: alice.xSk,
            senderXPk: alice.xPk,
            groupSecret: groupSecretV2,
            recipientXPks: [bob.xPk],
            timestamp: 300
        )
        let (_, rotatedBob) = try AsymmetricCrypto.parseAndUnwrapGroupKey(wrapV2, myXSk: bob.xSk, myXPk: bob.xPk)
        let (_, rotatedCharlie) = try AsymmetricCrypto.parseAndUnwrapGroupKey(wrapV2, myXSk: charlie.xSk, myXPk: charlie.xPk)
        XCTAssertEqual(rotatedBob, groupSecretV2)
        XCTAssertNil(rotatedCharlie)
    }

    // MARK: - 5. Symmetric Crypto, Argon2id & MediaCrypto

    func testSymmetricArgon2idAndMediaCrypto() throws {
        let salt = E2EProtocol.deriveChatSalt(chatId: -1001234567)
        XCTAssertEqual(salt.count, 16)

        let k1 = try SymmetricCrypto.deriveKey(password: "correct horse battery staple", salt: salt)
        let k2 = try SymmetricCrypto.deriveKey(password: "correct horse battery staple", salt: salt)
        let k3 = try SymmetricCrypto.deriveKey(password: "wrong password", salt: salt)
        XCTAssertEqual(k1.count, 32)
        XCTAssertEqual(k1, k2)
        XCTAssertNotEqual(k1, k3)

        let nonce = SymmetricCrypto.randomBytes(12)
        let aad = Data("chat-context".utf8)
        let plain = Data("Секретное сообщение для теста".utf8)
        let ct = try SymmetricCrypto.encrypt(key: k1, nonce: nonce, plaintext: plain, aad: aad)
        let decrypted = try SymmetricCrypto.decrypt(key: k1, nonce: nonce, ciphertextAndTag: ct, aad: aad)
        XCTAssertEqual(decrypted, plain)

        XCTAssertThrowsError(try SymmetricCrypto.decrypt(key: k1, nonce: nonce, ciphertextAndTag: ct, aad: Data("bad".utf8)))

        // MediaCrypto test (dummy PDF header + 0x8F 0x3D binaryMagic + nonce + ciphertext)
        let rawImage = SymmetricCrypto.randomBytes(512)
        let encryptedMedia = try MediaCrypto.encryptMediaBytes(rawImage, key: k1)
        XCTAssertEqual(encryptedMedia.prefix(4), Data("%PDF".utf8))
        XCTAssertNotNil(encryptedMedia.range(of: Data(MediaCrypto.binaryMagic)))
        let decryptedMedia = try MediaCrypto.decryptMediaBytes(encryptedMedia, key: k1)
        XCTAssertEqual(decryptedMedia, rawImage)

        let encryptedOgg = try MediaCrypto.encryptMediaBytes(rawImage, key: k1, dummyType: "ogg")
        XCTAssertEqual(encryptedOgg.prefix(4), Data("OggS".utf8))
        XCTAssertEqual(try MediaCrypto.decryptMediaBytes(encryptedOgg, key: k1), rawImage)

        var badMedia = encryptedMedia
        badMedia[badMedia.count - 5] ^= 0x01
        XCTAssertThrowsError(try MediaCrypto.decryptMediaBytes(badMedia, key: k1))
    }

    // MARK: - 6. Obfuscation

    func testChineseObfuscationAndBase64Fallback() throws {
        let payload = Data([0x20, 0x01, 0x02, 0x03, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF])
        let zhText = Obfuscation.obfuscateChinese(payload)
        XCTAssertTrue(Obfuscation.detectChinese(zhText))

        let decodedZh = Obfuscation.decodeEncryptedBytes(from: zhText)
        XCTAssertEqual(decodedZh?.mode, "zh")
        XCTAssertEqual(decodedZh?.bytes, payload)

        let rawText = Obfuscation.encodeEncryptedBytes(payload, mode: "none")
        XCTAssertFalse(Obfuscation.detectChinese(rawText))
        let decodedRaw = Obfuscation.decodeEncryptedBytes(from: rawText)
        XCTAssertEqual(decodedRaw?.mode, "raw")
        XCTAssertEqual(decodedRaw?.bytes, payload)
    }

    // MARK: - 7. E2E Protocol Pack / Unpack

    func testE2EProtocolModesAndDeflate() throws {
        let sessionKey = SymmetricCrypto.randomBytes(32)
        let chatId: Int64 = 777_888_999
        let password = "пароль-для-чата"

        // 1) Plain mode
        let packedPlain = try E2EProtocol.packMessage(payload: .text("plain text"))
        XCTAssertEqual(try E2EProtocol.unpackMessage(bytes: packedPlain), .text("plain text"))

        // 2) Session mode
        let packedSession = try E2EProtocol.packMessage(payload: .text("session secret"), sessionKey: sessionKey)
        XCTAssertEqual(
            try E2EProtocol.unpackMessage(bytes: packedSession, sessionKey: sessionKey),
            .text("session secret")
        )

        // 3) Password + raw deflate (> 64 bytes repetitive text)
        let longText = String(repeating: "Повторяющийся конфиденциальный текст для сжатия deflate. ", count: 5)
        let packedPwdDeflate = try E2EProtocol.packMessage(
            payload: .text(longText),
            password: password,
            chatId: chatId
        )
        let headerByte = packedPwdDeflate[0]
        XCTAssertTrue(E2EProtocol.Header.decode(headerByte).isCompressed)
        XCTAssertTrue(E2EProtocol.Header.decode(headerByte).hasPassword)
        XCTAssertEqual(
            try E2EProtocol.unpackMessage(bytes: packedPwdDeflate, password: password),
            .text(longText)
        )

        // 4) Both session + password layers + Media tuple
        let mediaJSON = """
        {"attach_index":0,"name":"voice.ogg","mime":"audio/ogg","media_type":"audio","size":4096,"duration":3.5,"wave":[1,5,20,40,12]}
        """
        let media = try JSONDecoder().decode(MediaDescriptor.self, from: Data(mediaJSON.utf8))
        let packedBothMedia = try E2EProtocol.packMessage(
            payload: .media(text: "Голосовое сообщение", media: media),
            sessionKey: sessionKey,
            password: password,
            chatId: chatId
        )
        let unpackedMedia = try E2EProtocol.unpackMessage(
            bytes: packedBothMedia,
            sessionKey: sessionKey,
            password: password
        )
        XCTAssertEqual(unpackedMedia, .media(text: "Голосовое сообщение", media: media))
        XCTAssertThrowsError(
            try E2EProtocol.unpackMessage(bytes: packedBothMedia, sessionKey: sessionKey, password: "wrong")
        )
    }

    // MARK: - 8. Call Encryption (SFrame-compatible Opus / VP8 / H.264 / P-256 ECDH / Group)

    func testCallEncryptionAudioVideoECDHAndGroup() throws {
        // Ephemeral P-256 ECDH agreement
        let callerKP = CallEncryptionSession.generateCallKeyPair()
        let calleeKP = CallEncryptionSession.generateCallKeyPair()
        let callerPub = CallEncryptionSession.exportPublicKeyBytes(callerKP)
        let calleePub = CallEncryptionSession.exportPublicKeyBytes(calleeKP)
        XCTAssertEqual(callerPub.count, 65)
        XCTAssertEqual(calleePub.count, 65)

        let secretCaller = try CallEncryptionSession.deriveSharedSecret(myPrivateKey: callerKP, peerPublicKeyBytes: calleePub)
        let secretCallee = try CallEncryptionSession.deriveSharedSecret(myPrivateKey: calleeKP, peerPublicKeyBytes: callerPub)
        XCTAssertEqual(secretCaller, secretCallee)

        let callerSession = CallEncryptionSession()
        let calleeSession = CallEncryptionSession()
        callerSession.initFromSecretData(secretCaller, conversationId: "conv-123", isOriginator: true)
        calleeSession.initFromSecretData(secretCallee, conversationId: "conv-123", isOriginator: false)
        XCTAssertEqual(callerSession.mode, .secure)
        XCTAssertEqual(callerSession.fingerprint, calleeSession.fingerprint)

        // Opus audio (TOC + payload) -> 1 byte unencrypted header + 16 tag + 12 IV + 0x0c 0x00 trailer
        let opusRaw = Data([0x78] + (0..<32).map { UInt8($0) })
        let opusEnc = callerSession.encryptFrame(opusRaw, kind: .audio)
        XCTAssertEqual(opusEnc.first, 0x78)
        XCTAssertEqual(opusEnc.suffix(2), Data([0x0c, 0x00]))
        XCTAssertEqual(opusEnc.count, opusRaw.count + 30)
        XCTAssertEqual(calleeSession.decryptFrame(opusEnc, kind: .audio), opusRaw)

        // VP8 keyframe (bit 0 == 0 -> 10 bytes header unencrypted)
        let vp8KeyRaw = Data([0x10, 0x00, 0x00, 0x9D, 0x01, 0x2A, 0x80, 0x02, 0xE0, 0x01] + Array(repeating: 0x55, count: 40))
        let vp8Enc = callerSession.encryptFrame(vp8KeyRaw, kind: .video)
        XCTAssertEqual(vp8Enc.prefix(10), vp8KeyRaw.prefix(10))
        XCTAssertEqual(calleeSession.decryptFrame(vp8Enc, kind: .video), vp8KeyRaw)

        // H.264 Annex-B (SPS + PPS + IDR slice)
        let h264IDR = Data([
            0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x1E, // SPS (nal 7)
            0x00, 0x00, 0x01, 0x68, 0xCE, 0x3C, 0x80,       // PPS (nal 8)
            0x00, 0x00, 0x00, 0x01, 0x65, 0x88,             // IDR (nal 5) + slice byte
        ] + Array(repeating: 0x7A, count: 64))
        let expectedH264Prefix = CallFrameHeader.unencryptedBytes(raw: h264IDR, kind: .video)
        XCTAssertEqual(expectedH264Prefix, 21)
        let h264Enc = callerSession.encryptFrame(h264IDR, kind: .video)
        XCTAssertEqual(h264Enc.prefix(21), h264IDR.prefix(21))
        XCTAssertEqual(calleeSession.decryptFrame(h264Enc, kind: .video), h264IDR)

        // Symmetric Group Call
        let groupSecretHex = SymmetricCrypto.randomBytes(32).hexString
        let g1 = CallEncryptionSession()
        let g2 = CallEncryptionSession()
        g1.initGroupFromSecret(groupSecretHex, conversationId: "grp-conv-1")
        g2.initGroupFromSecret(groupSecretHex, conversationId: "grp-conv-1")
        XCTAssertEqual(g1.fingerprint, g2.fingerprint)
        let gEnc = g1.encryptFrame(opusRaw, kind: .audio)
        XCTAssertEqual(g2.decryptFrame(gEnc, kind: .audio), opusRaw)
    }

    // MARK: - 9. SecureStore, TrackerBlocker & MaxClient Defaults

    func testSecureStorePersistenceAndWipe() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rms-max-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let store = SecureStore(baseDirectory: tmpDir)
        let account = MaxAccount(
            id: 12345,
            userId: 999,
            displayName: "Тест",
            phone: "+79001234567",
            token: "secret-token",
            identity: MaxIdentity.generateMobile()
        )
        try await store.saveAccounts([account], currentAccountId: account.id)
        let loaded = await store.loadAccounts()
        XCTAssertEqual(loaded.0, [account])
        XCTAssertEqual(loaded.1, account.id)

        var e2e = ChatE2ESettings()
        e2e.password = "секрет"
        e2e.obfuscation = "zh"
        try await store.saveChatSettings(e2e, accountId: 12345, chatId: -555)
        let loadedE2E = await store.loadChatSettings(accountId: 12345, chatId: -555)
        XCTAssertEqual(loadedE2E.password, "секрет")
        XCTAssertEqual(loadedE2E.obfuscation, "zh")

        await store.wipeAllData()
        let afterWipe = await store.loadAccounts()
        XCTAssertTrue(afterWipe.0.isEmpty)
        XCTAssertNil(afterWipe.1)
    }

    func testTrackerBlockerAndMaxClientDefaultTelemetry() async throws {
        XCTAssertTrue(TrackerBlocker.isBlocked(url: try XCTUnwrap(URL(string: "https://sdk-api.apptracer.ru/collect"))))
        XCTAssertTrue(TrackerBlocker.isBlocked(url: try XCTUnwrap(URL(string: "https://mc.yandex.ru/watch/123"))))
        XCTAssertTrue(TrackerBlocker.isBlocked(url: try XCTUnwrap(URL(string: "https://stat.oneme.ru/ping"))))
        XCTAssertFalse(TrackerBlocker.isBlocked(url: try XCTUnwrap(URL(string: "https://api2.oneme.ru/"))))

        let rulesData = Data(TrackerBlocker.webKitRuleListJSON().utf8)
        let parsed = try JSONSerialization.jsonObject(with: rulesData) as? [[String: Any]]
        XCTAssertFalse(parsed?.isEmpty ?? true)

        let client = MaxClient()
        let mode = await client.telemetryMode
        XCTAssertEqual(mode, "disabled")
    }

    func testE2EMediaAttachmentRoundTrip() throws {
        // Session key path: encrypt like sendAttachment, decrypt like localFile.
        let secret = SymmetricCrypto.randomBytes(32)
        var settings = ChatE2ESettings()
        settings.session = E2ESessionInfo(
            sharedSecretHex: secret.hexString, fingerprint: "x", peerEdPkHex: nil, peerXPkHex: nil,
            myEdSkHex: nil, myEdPkHex: nil, establishedAt: 0, isGroup: false, createdBySelf: true
        )
        let photo = Data((0..<5000).map { UInt8($0 % 251) })
        let key = MediaKeys.encryptionKey(for: settings)
        XCTAssertEqual(key, secret)
        let enc = try MediaCrypto.encryptMediaBytes(photo, key: key, dummyType: "docx")
        XCTAssertEqual(Array(enc.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "disguised as a zip/docx")
        let candidates = MediaKeys.decryptionKeys(for: settings)
        let dec = candidates.lazy.compactMap { try? MediaCrypto.decryptMediaBytes(enc, key: $0) }.first
        XCTAssertEqual(dec, photo)

        // No session: falls back to the maxplus fixed obfuscation key (SHA-256 of its constant).
        let fallback = MediaKeys.encryptionKey(for: ChatE2ESettings())
        XCTAssertEqual(fallback.hexString, SHA256.hash(data: Data("maxplus_media_obfuscation_fixed_key_v1".utf8)).map { String(format: "%02x", $0) }.joined())

        // Media descriptor survives the E2E packet.
        let desc = MediaDescriptor(attachIndex: 0, name: "cat.jpg", mime: "image/jpeg", mediaType: "PHOTO",
                                   size: 5000, width: 640, height: 480, duration: nil, wave: nil, videoType: nil, color: nil)
        let packed = try E2EProtocol.packMessage(payload: .media(text: "", media: desc), sessionKey: secret, password: nil, chatId: 42)
        guard case .media(let caption, let back) = try E2EProtocol.unpackMessage(bytes: packed, sessionKey: secret, password: nil) else {
            return XCTFail("expected media payload")
        }
        XCTAssertEqual(caption, "")
        XCTAssertEqual(back.name, "cat.jpg")
        XCTAssertEqual(back.mediaType, "PHOTO")
        XCTAssertEqual(back.width, 640)
    }

    func testAttachmentKindsAndLabels() {
        XCTAssertEqual(AttachmentKind.forUpload(mime: "image/png"), .photo)
        XCTAssertEqual(AttachmentKind.forUpload(mime: "video/mp4"), .video)
        XCTAssertEqual(AttachmentKind.forUpload(mime: "application/pdf"), .file)
        XCTAssertEqual(AttachmentKind.forUpload(mime: "image/gif"), .file)
        let att = MaxAttachment(id: "1", type: "FILE", title: "a.pdf", url: nil, fileId: 1, photoId: nil, videoId: nil,
                                width: nil, height: nil, durationMs: nil, mime: nil, size: nil)
        let msg = MaxMessage(id: "1", chatId: 1, senderId: 1, text: "", timeMs: 0, edited: false, deleted: false,
                             replyToMessageId: nil, attaches: [att], reactions: [], decrypted: nil)
        XCTAssertEqual(msg.displayText, "Файл: a.pdf")
        XCTAssertEqual(msg.bodyText, "")
    }

    func testOggOpusToCAFRemuxPlaysInAVFoundation() throws {
        // 1. Encode 2 s of a 440 Hz tone to Opus packets (20 ms frames) with the system codec.
        let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        var opusDesc = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        let opusFormat = AVAudioFormat(streamDescription: &opusDesc)!
        let converter = try XCTUnwrap(AVAudioConverter(from: pcmFormat, to: opusFormat))
        let totalFrames = 96_000
        let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(totalFrames))!
        pcm.frameLength = AVAudioFrameCount(totalFrames)
        for n in 0..<totalFrames { pcm.floatChannelData![0][n] = 0.3 * sin(2 * .pi * 440 * Float(n) / 48_000) }
        var fed = false
        var packets: [Data] = []
        while true {
            let out = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: 16, maximumPacketSize: 1500)
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, inStatus in
                if fed { inStatus.pointee = .endOfStream; return nil }
                fed = true; inStatus.pointee = .haveData; return pcm
            }
            XCTAssertNil(err)
            for k in 0..<Int(out.packetCount) {
                let d = out.packetDescriptions![k]
                packets.append(Data(bytes: out.data.advanced(by: Int(d.mStartOffset)), count: Int(d.mDataByteSize)))
            }
            if status == .endOfStream || status == .error || out.packetCount == 0 { break }
        }
        XCTAssertGreaterThan(packets.count, 50)

        // 2. Wrap them in a minimal Ogg/Opus stream (OpusHead, OpusTags, one packet per page).
        func page(_ payload: Data, granule: Int64, seq: UInt32, type: UInt8) -> Data {
            var d = Data("OggS".utf8); d.append(0); d.append(type)
            withUnsafeBytes(of: UInt64(bitPattern: granule).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(0x1234).littleEndian) { d.append(contentsOf: $0) }
            withUnsafeBytes(of: seq.littleEndian) { d.append(contentsOf: $0) }
            d.append(contentsOf: [0, 0, 0, 0])
            var lacing: [UInt8] = []; var rest = payload.count
            while rest >= 255 { lacing.append(255); rest -= 255 }
            lacing.append(UInt8(rest))
            d.append(UInt8(lacing.count)); d.append(contentsOf: lacing); d.append(payload)
            return d
        }
        var head = Data("OpusHead".utf8); head.append(1); head.append(1)
        head.append(contentsOf: [0x38, 0x01]); head.append(contentsOf: [0x80, 0xBB, 0, 0]); head.append(contentsOf: [0, 0, 0])
        var ogg = page(head, granule: 0, seq: 0, type: 2)
        ogg.append(page(Data("OpusTags".utf8) + Data(count: 8), granule: 0, seq: 1, type: 0))
        for (k, p) in packets.enumerated() {
            ogg.append(page(p, granule: Int64((k + 1) * 960), seq: UInt32(k + 2), type: 0))
        }
        XCTAssertTrue(OggOpusCAF.isOgg(ogg))

        // 3. Remux and let AVFoundation open it.
        let caf = try OggOpusCAF.remux(ogg)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("remux_\(UUID().uuidString).caf")
        try caf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        XCTAssertEqual(seconds, Double(packets.count * 960 - 312) / 48_000, accuracy: 0.05)
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(player.duration, 1.5)
    }

    func testOggOpusEncoderProducesValidOgg() throws {
        // Ogg CRC check value for "123456789" (poly 0x04C11DB7, init 0, no reflection, no xorout).
        XCTAssertEqual(OggOpusEncoder.oggCRC(Data("123456789".utf8)), 0x89A1_897F)

        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 72_000)!
        pcm.frameLength = 72_000
        for n in 0..<72_000 { pcm.floatChannelData![0][n] = 0.3 * sin(2 * .pi * 300 * Float(n) / 48_000) }
        let ogg = try OggOpusEncoder.encode(pcm: pcm)
        XCTAssertTrue(OggOpusCAF.isOgg(ogg))

        // Every page's CRC must verify.
        let bytes = [UInt8](ogg)
        var pos = 0, pages = 0
        while pos < bytes.count {
            let segs = Int(bytes[pos + 26])
            let len = 27 + segs + (0..<segs).reduce(0) { $0 + Int(bytes[pos + 27 + $1]) }
            var page = Data(bytes[pos..<pos + len])
            let stored = page[page.startIndex + 22..<page.startIndex + 26].enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            page.replaceSubrange(page.startIndex + 22..<page.startIndex + 26, with: [0, 0, 0, 0])
            XCTAssertEqual(OggOpusEncoder.oggCRC(page), stored, "page \(pages)")
            pos += len; pages += 1
        }
        XCTAssertGreaterThanOrEqual(pages, 4)

        // And it decodes back to ~1.5 s via the CAF path.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("enc_\(UUID().uuidString).caf")
        try OggOpusCAF.remux(ogg).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / 48_000, 1.5, accuracy: 0.05)
    }
}
