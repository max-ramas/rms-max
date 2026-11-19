import Foundation
import CryptoKit

// MARK: - Errors

public enum MediaError: Error, LocalizedError {
    case noUploadURL
    case uploadFailed(String)
    case noDownloadURL
    case downloadFailed(String)
    case decryptFailed
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .noUploadURL: return "Сервер не выдал адрес для загрузки"
        case .uploadFailed(let m): return "Не удалось загрузить файл: \(m)"
        case .noDownloadURL: return "Сервер не выдал ссылку на файл"
        case .downloadFailed(let m): return "Не удалось скачать файл: \(m)"
        case .decryptFailed: return "Не удалось расшифровать вложение (нет подходящего ключа)"
        case .unsupported(let m): return m
        }
    }
}

// MARK: - HTTP helpers (Max CDN may use the Mintsyfry root, so use the shared trust delegate)

enum MediaHTTP {
    static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.httpCookieStorage = nil
        cfg.urlCache = nil
        return URLSession(configuration: cfg, delegate: MaxURLSessionDelegate.shared, delegateQueue: nil)
    }()

    static func checkOK(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw MediaError.uploadFailed("нет HTTP-ответа") }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: body.prefix(200), encoding: .utf8) ?? ""
            throw MediaError.uploadFailed("HTTP \(http.statusCode) \(snippet)")
        }
    }

    static func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw MediaError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }
}

// MARK: - Upload / download API (mirrors rumax api/files.rs + messaging.rs)

extension MaxClient {
    /// opcode 80 → multipart POST → `photos.{id}.token`.
    public func uploadPhoto(data: Data, mime: String, profile: Bool = false) async throws -> String {
        let resp = try await getPhotoUploadURL(profile: profile)
        guard let urlStr = resp.payload["url"]?.stringValue ?? resp.payload["info"]?.arrayValue?.first?["url"]?.stringValue,
              let url = URL(string: urlStr)
        else { throw MediaError.noUploadURL }

        let ext = mime.split(separator: "/").last.map(String.init) ?? "jpg"
        let boundary = "----rmsmax\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"image.\(ext)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mime)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (respData, response) = try await MediaHTTP.session.upload(for: req, from: body)
        try MediaHTTP.checkOK(response, respData)

        guard let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any] else {
            throw MediaError.uploadFailed("непонятный ответ сервера")
        }
        if let photos = json["photos"] as? [String: Any] {
            for case let entry as [String: Any] in photos.values {
                if let token = entry["token"] as? String { return token }
            }
        }
        if let token = (json["photoToken"] ?? json["token"]) as? String { return token }
        throw MediaError.uploadFailed("сервер не вернул токен фото")
    }

    /// opcode 87 → raw POST with Content-Range → fileId.
    public func uploadFile(data: Data, fileName: String) async throws -> Int64 {
        let resp = try await getFileUploadURL(profile: false)
        guard let info = resp.payload["info"]?.arrayValue?.first,
              let urlStr = info["url"]?.stringValue, let url = URL(string: urlStr),
              let fileId = info["fileId"]?.int64Value
        else { throw MediaError.noUploadURL }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("attachment; filename=\(Self.headerSafe(fileName))", forHTTPHeaderField: "Content-Disposition")
        req.setValue("0-\(max(0, data.count - 1))/\(data.count)", forHTTPHeaderField: "Content-Range")
        let (respData, response) = try await MediaHTTP.session.upload(for: req, from: data)
        try MediaHTTP.checkOK(response, respData)
        return fileId
    }

    /// opcode 82 (uploaderType 0, type 0) → raw POST → (videoId, token).
    public func uploadVideo(data: Data) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: 0, type: 0)
    }

    /// Voice message: opcode 82 type 2. Like the official web client, non-Ogg audio (our AAC/M4A)
    /// goes through the processing uploader (uploaderType 0) so the server transcodes it; Ogg goes direct (1).
    public func uploadAudio(data: Data, isOgg: Bool = false) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: isOgg ? 1 : 0, type: 2)
    }

    private func uploadToVideoPlatform(data: Data, uploaderType: Int64, type: Int64) async throws -> (videoId: Int64, token: String) {
        let resp = try await sendAndWait(
            opcode: 82,
            payload: .object(["uploaderType": .int(uploaderType), "type": .int(type), "count": .int(1)])
        )
        guard let info = resp.payload["info"]?.arrayValue?.first,
              let urlStr = info["url"]?.stringValue, let url = URL(string: urlStr),
              let videoId = info["videoId"]?.int64Value
        else { throw MediaError.noUploadURL }
        var token = info["token"]?.stringValue ?? ""

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        let fname = String(Int64(Date().timeIntervalSince1970 * 1_000_000) & 0x7FFF_FFFF)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("attachment; filename=\"\(fname)\"", forHTTPHeaderField: "Content-Disposition")
        req.setValue("bytes 0-\(max(0, data.count - 1))/\(data.count)", forHTTPHeaderField: "Content-Range")
        let (respData, response) = try await MediaHTTP.session.upload(for: req, from: data)
        try MediaHTTP.checkOK(response, respData)
        let text = String(data: respData, encoding: .utf8) ?? ""
        if text.contains("error_msg") || text.contains("error_code") {
            throw MediaError.uploadFailed(String(text.prefix(200)))
        }
        if let json = try? JSONSerialization.jsonObject(with: respData) {
            if let arr = json as? [[String: Any]], let t = arr.compactMap({ $0["token"] as? String }).first {
                token = t
            } else if let obj = json as? [String: Any],
                      let t = (obj["token"] ?? obj["videoToken"]) as? String {
                token = t
            }
        }
        return (videoId, token)
    }

    /// opcode 88 → direct download URL for a FILE attach.
    public func fileDownloadURL(chatId: Int64, messageId: Int64, fileId: Int64) async throws -> URL {
        let resp = try await getFileDownloadInfo(chatId: chatId, messageId: messageId, fileId: fileId)
        guard let s = resp.payload["url"]?.stringValue, let url = URL(string: s) else { throw MediaError.noDownloadURL }
        return url
    }

    /// opcode 83 → best playable URL for a VIDEO / voice attach.
    public func videoPlaybackURL(chatId: Int64, messageId: Int64, videoId: Int64, token: String?, preferAudio: Bool = false) async throws -> URL {
        var obj: [String: JSONValue] = [
            "chatId": .int(chatId),
            "messageId": .int(messageId),
            "videoId": .int(videoId),
        ]
        if let token { obj["token"] = .string(token) }
        let resp = try await sendAndWait(opcode: 83, payload: .object(obj))
        // Apple players can't decode Ogg, so for voice prefer MP3/AAC renditions.
        let order = preferAudio
            ? ["MP3", "AUDIO", "MP4_720", "MP4_480", "MP4_360", "MP4_240", "MP4_144", "url", "OGG", "EXTERNAL", "HLS"]
            : ["MP4_720", "MP4_480", "MP4_360", "MP4_240", "MP4_144", "MP4_1080", "OGG", "MP3", "AUDIO", "EXTERNAL", "url", "HLS"]
        for key in order {
            if let s = resp.payload[key]?.stringValue, let url = URL(string: s), url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        if let obj = resp.payload.objectValue {
            for v in obj.values {
                if let s = v.stringValue, s.hasPrefix("http"), !s.hasSuffix(".jpg"), !s.hasSuffix(".png"), let url = URL(string: s) {
                    return url
                }
            }
        }
        throw MediaError.noDownloadURL
    }

    static func headerSafe(_ name: String) -> String {
        let cleaned = name.unicodeScalars.filter { $0.isASCII && $0 != "\"" && $0 != "\r" && $0 != "\n" }
        let s = String(String.UnicodeScalarView(cleaned))
        return s.isEmpty ? "file.bin" : s
    }
}

// MARK: - E2E media keys (compatible with maxplus get_media_crypto_key)

public enum MediaKeys {
    static let passwordSalt = Data("maxplus_media_salt_bytes".utf8)
    static let fixedKey = Data(SHA256.hash(data: Data("maxplus_media_obfuscation_fixed_key_v1".utf8)))

    /// Key used to encrypt outgoing media: active session secret, else chat password, else fixed obfuscation key.
    public static func encryptionKey(for settings: ChatE2ESettings) -> Data {
        if let hex = settings.session?.sharedSecretHex, let k = Data(hexString: hex), k.count == 32 { return k }
        if let pwd = settings.password, !pwd.isEmpty, let k = try? SymmetricCrypto.deriveKey(password: pwd, salt: passwordSalt) {
            return k
        }
        return fixedKey
    }

    /// All keys worth trying for incoming media (current + archived sessions, password, fixed).
    public static func decryptionKeys(for settings: ChatE2ESettings) -> [Data] {
        var keys = settings.allSessionSecrets
        if let pwd = settings.password, !pwd.isEmpty, let k = try? SymmetricCrypto.deriveKey(password: pwd, salt: passwordSalt) {
            keys.append(k)
        }
        keys.append(fixedKey)
        return keys
    }

    static let decoys: [(ext: String, mime: String, dummy: String)] = [
        ("pdf", "application/pdf", "pdf"),
        ("docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"),
        ("xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"),
    ]
    static let decoyBaseNames = ["document", "scan", "report", "notes", "invoice", "draft", "contract", "table"]
}

// MARK: - Local media cache

public enum MediaCache {
    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("RMSMaxMedia", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(key: String, fileName: String) -> URL {
        let safeKey = key.replacingOccurrences(of: "/", with: "_")
        let dir = directory.appendingPathComponent(safeKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(safeName.isEmpty ? "file" : safeName)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - App-level media flows

extension AppStore {
    /// Sends a local file as an attachment. In an active E2E chat the file is encrypted,
    /// disguised as a document and the real metadata travels inside the encrypted text.
    public func sendAttachment(
        chatId: Int64,
        data: Data,
        fileName: String,
        mime: String,
        caption: String = "",
        width: Int? = nil,
        height: Int? = nil,
        durationMs: Int? = nil,
        wave: [UInt8]? = nil
    ) async {
        isBusy = true
        defer { isBusy = false }
        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        let kind: AttachmentKind = wave != nil ? .audio : AttachmentKind.forUpload(mime: mime)
        do {
            var attaches: [JSONValue] = []
            var wireText = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            var localDecrypted: DecryptedMessageState?

            if settings.isActive {
                let decoy = MediaKeys.decoys.randomElement()!
                let decoyName = "\(MediaKeys.decoyBaseNames.randomElement()!).\(decoy.ext)"
                let encrypted = try MediaCrypto.encryptMediaBytes(
                    data, key: MediaKeys.encryptionKey(for: settings), dummyType: decoy.dummy
                )
                let fileId = try await client.uploadFile(data: encrypted, fileName: decoyName)
                attaches = [.object(["_type": .string("FILE"), "fileId": .int(fileId)])]

                let typeName: String = {
                    switch kind {
                    case .photo: return "PHOTO"
                    case .video: return "VIDEO"
                    case .audio: return "AUDIO"
                    default: return mime.hasPrefix("audio/") ? "AUDIO" : "FILE"
                    }
                }()
                let descriptor = MediaDescriptor(
                    attachIndex: 0, name: fileName, mime: mime, mediaType: typeName,
                    size: UInt64(data.count),
                    width: width.map { UInt32($0) }, height: height.map { UInt32($0) },
                    duration: durationMs.map { Double($0) }, wave: wave, videoType: nil, color: nil
                )
                let sKey = settings.session.flatMap { Data(hexString: $0.sharedSecretHex) }
                let packed = try E2EProtocol.packMessage(
                    payload: .media(text: wireText, media: descriptor),
                    sessionKey: sKey, password: settings.password, chatId: chatId
                )
                localDecrypted = DecryptedMessageState(
                    text: wireText, obfuscation: settings.obfuscation ?? "zh", isEncrypted: true,
                    media: descriptor, isHandshakeRequest: false, isHandshakeAccept: false,
                    isGroupAnnounce: false, isGroupKeyWrap: false, handshakeDataHex: nil, error: nil
                )
                wireText = Obfuscation.encodeEncryptedBytes(packed, mode: settings.obfuscation)
                // Keep a plaintext copy locally so our own message renders without a round trip.
                let cacheURL = MediaCache.url(key: "enc_\(fileId)", fileName: fileName)
                try? data.write(to: cacheURL, options: .atomic)
            } else {
                switch kind {
                case .photo:
                    let token = try await client.uploadPhoto(data: data, mime: mime)
                    attaches = [.object(["_type": .string("PHOTO"), "photoToken": .string(token)])]
                case .audio:
                    // Official client attach shape: audioId + duration (ms) + wave as raw bytes.
                    let a = try await client.uploadAudio(data: data, isOgg: mime.contains("ogg"))
                    var obj: [String: JSONValue] = [
                        "_type": .string("AUDIO"), "audioId": .int(a.videoId), "token": .string(a.token),
                        "duration": .int(Int64(max(durationMs ?? 0, 1000))),
                    ]
                    if let wave { obj["wave"] = .binary(Data(wave)) }
                    attaches = [.object(obj)]
                case .video:
                    do {
                        let v = try await client.uploadVideo(data: data)
                        attaches = [.object(["_type": .string("VIDEO"), "videoId": .int(v.videoId), "token": .string(v.token)])]
                    } catch {
                        let fileId = try await client.uploadFile(data: data, fileName: fileName)
                        attaches = [.object(["_type": .string("FILE"), "fileId": .int(fileId)])]
                    }
                default:
                    let fileId = try await client.uploadFile(data: data, fileName: fileName)
                    attaches = [.object(["_type": .string("FILE"), "fileId": .int(fileId)])]
                }
            }

            let resp = try await sendWithRetry(chatId: chatId, text: wireText, attaches: attaches)
            if let msgVal = resp.payload["message"] {
                var parsed = parseMessage(msgVal, chatId: chatId)
                if let localDecrypted { parsed.decrypted = localDecrypted }
                upsertMessage(parsed, inChat: chatId, isIncomingPush: false)
            }
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    /// The server needs a moment to process a fresh upload; it answers "attachment.not.ready" meanwhile.
    private func sendWithRetry(chatId: Int64, text: String, attaches: [JSONValue]) async throws -> MaxResponse {
        var lastError: Error?
        for attempt in 0..<6 {
            do {
                return try await client.sendMessage(chatId: chatId, text: text, attaches: attaches)
            } catch MaxTransportError.apiError(let payload) {
                let code = payload["error"]?.stringValue ?? ""
                lastError = MaxTransportError.apiError(payload)
                guard code.contains("not.ready") || code.contains("not_ready") else { throw lastError! }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000)
            }
        }
        throw lastError ?? MediaError.uploadFailed("сервер не принял вложение")
    }

    /// Returns a local file for an attachment, downloading (and for E2E media, decrypting) it when needed.
    public func localFile(for attachment: MaxAttachment, in message: MaxMessage) async throws -> URL {
        let chatId = message.chatId
        guard let messageId = Int64(message.id) else { throw MediaError.noDownloadURL }

        if let media = message.decrypted?.media, attachment.kind == .file, let fileId = attachment.fileId {
            let target = MediaCache.url(key: "enc_\(fileId)", fileName: media.name)
            let cafTarget = target.deletingPathExtension().appendingPathExtension("caf")
            if FileManager.default.fileExists(atPath: cafTarget.path) { return cafTarget }
            if FileManager.default.fileExists(atPath: target.path) {
                // Our own sent voice is cached as plain Ogg; convert once so Apple players can open it.
                if let cached = try? Data(contentsOf: target), OggOpusCAF.isOgg(cached), let caf = try? OggOpusCAF.remux(cached) {
                    try caf.write(to: cafTarget, options: .atomic)
                    return cafTarget
                }
                return target
            }
            let url = try await client.fileDownloadURL(chatId: chatId, messageId: messageId, fileId: fileId)
            let encrypted = try await MediaHTTP.get(url)
            let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
            for key in MediaKeys.decryptionKeys(for: settings) {
                if let plain = try? MediaCrypto.decryptMediaBytes(encrypted, key: key) {
                    if OggOpusCAF.isOgg(plain), let caf = try? OggOpusCAF.remux(plain) {
                        let cafTarget = target.deletingPathExtension().appendingPathExtension("caf")
                        try caf.write(to: cafTarget, options: .atomic)
                        return cafTarget
                    }
                    try plain.write(to: target, options: .atomic)
                    return target
                }
            }
            throw MediaError.decryptFailed
        }

        switch attachment.kind {
        case .file:
            guard let fileId = attachment.fileId else { throw MediaError.noDownloadURL }
            let target = MediaCache.url(key: "file_\(fileId)", fileName: attachment.title ?? "file_\(fileId)")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            let url = try await client.fileDownloadURL(chatId: chatId, messageId: messageId, fileId: fileId)
            try await MediaHTTP.get(url).write(to: target, options: .atomic)
            return target
        case .photo, .sticker:
            guard let s = attachment.url, let url = URL(string: s) else { throw MediaError.noDownloadURL }
            let key = "photo_\(attachment.photoId.map(String.init) ?? attachment.id)"
            let target = MediaCache.url(key: key, fileName: attachment.title ?? "photo.jpg")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            try await MediaHTTP.get(url).write(to: target, options: .atomic)
            return target
        case .audio:
            // Official voice messages carry a direct `url` to Ogg/Opus; Apple can't play Ogg,
            // so repackage it into CAF (same trick as the official web client on Safari).
            let key = "audio_\(attachment.videoId.map(String.init) ?? attachment.id)"
            let cafTarget = MediaCache.url(key: key, fileName: "voice.caf")
            if FileManager.default.fileExists(atPath: cafTarget.path) { return cafTarget }
            let raw: Data
            if let s = attachment.url, let url = URL(string: s) {
                raw = try await MediaHTTP.get(url)
            } else if let videoId = attachment.videoId {
                let url = try await client.videoPlaybackURL(
                    chatId: chatId, messageId: messageId, videoId: videoId, token: attachment.token, preferAudio: true
                )
                raw = try await MediaHTTP.get(url)
            } else {
                throw MediaError.noDownloadURL
            }
            if OggOpusCAF.isOgg(raw) {
                try OggOpusCAF.remux(raw).write(to: cafTarget, options: .atomic)
                return cafTarget
            }
            let plain = MediaCache.url(key: key, fileName: "voice.m4a")
            try raw.write(to: plain, options: .atomic)
            return plain
        case .video:
            guard let videoId = attachment.videoId else { throw MediaError.noDownloadURL }
            let target = MediaCache.url(key: "video_\(videoId)", fileName: "video.mp4")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            let url = try await client.videoPlaybackURL(
                chatId: chatId, messageId: messageId, videoId: videoId, token: attachment.token
            )
            try await MediaHTTP.get(url).write(to: target, options: .atomic)
            return target
        case .other:
            throw MediaError.unsupported("Этот тип вложения пока не поддерживается")
        }
    }
}
