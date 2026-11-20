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
    /// Official client (web bundle `Ise`): `/uploadImage|uploadAudio|uploadVideo` are plain «max-media» POSTs without
    /// Content-Range; every other upload URL is a resumable «range» upload that needs `Content-Range: bytes 0-(n-1)/n`.
    static func isMaxMediaUpload(_ url: URL) -> Bool {
        url.path.range(of: "^/upload(Image|Audio|Video)$", options: .regularExpression) != nil
    }

    /// RFC 3986 unreserved set, like JS `encodeURIComponent`.
    static func encodeFileName(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")) ?? "file"
    }

    /// POST of raw bytes exactly as the official client sends them; failures are logged with host/path and error codes.
    static func rawUpload(to url: URL, data: Data, fileName: String) async throws -> (Data, URLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("attachment; filename=\(encodeFileName(fileName))", forHTTPHeaderField: "Content-Disposition")
        let plain = isMaxMediaUpload(url)
        if !plain { req.setValue("bytes 0-\(max(0, data.count - 1))/\(data.count)", forHTTPHeaderField: "Content-Range") }
        let tag = plain ? "max-media" : "range"
        // 1) Network.framework — the stack that carries the MAX API connection; reports the real HTTP status.
        do {
            var headers = ["Content-Type": "application/octet-stream",
                           "Content-Disposition": "attachment; filename=\(encodeFileName(fileName))"]
            if !plain { headers["Content-Range"] = "bytes 0-\(max(0, data.count - 1))/\(data.count)" }
            let r = try await NWHTTPSClient.post(url: url, headers: headers, body: data)
            let note = (200...299).contains(r.status) ? "" : " body=\(String(decoding: r.body.prefix(200), as: UTF8.self))"
            ProtocolLog.add("upload[nw] \(tag) \(url.host ?? "?")\(url.path) \(data.count) B -> HTTP \(r.status)\(note)")
            if let http = HTTPURLResponse(url: url, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers) {
                return (r.body, http)
            }
        } catch {
            ProtocolLog.add("upload[nw] \(tag) \(url.host ?? "?")\(url.path) failed: \(error.localizedDescription) — retrying with URLSession")
        }
        // 2) URLSession fallback.
        do {
            let r = try await session.upload(for: req, from: data)
            ProtocolLog.add("upload[urlsession] \(tag) \(url.host ?? "?")\(url.path) \(data.count) B -> HTTP \((r.1 as? HTTPURLResponse)?.statusCode ?? -1)")
            return r
        } catch {
            let ns = error as NSError
            let stream = ns.userInfo["_kCFStreamErrorCodeKey"].map { " stream=\($0)" } ?? ""
            ProtocolLog.add("upload[urlsession] \(tag) \(url.scheme ?? "?")://\(url.host ?? "?"):\(url.port ?? 443)\(url.path) \(data.count) B failed: \(ns.domain)/\(ns.code)\(stream)")
            throw error
        }
    }

    /// MP4/MOV/3GP («ftyp» at byte 4), WebM/Matroska, Ogg: anything else (an HTML page, a JSON error) is not a video.
    static func looksLikeVideo(_ d: Data) -> Bool {
        guard d.count > 12 else { return false }
        if d[4...7].elementsEqual(Array("ftyp".utf8)) || d[4...7].elementsEqual(Array("moov".utf8)) || d[4...7].elementsEqual(Array("mdat".utf8)) { return true }
        if d.prefix(4).elementsEqual([0x1A, 0x45, 0xDF, 0xA3]) { return true }
        return d.prefix(4).elementsEqual(Array("OggS".utf8))
    }

    static func fileLooksLikeVideo(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        return looksLikeVideo((try? h.read(upToCount: 16)) ?? Data())
    }

    private static let chromeUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"

    /// Video links are signed for a client class: `srcAg` (we saw UNKNOWN for a desktop identity without a browser agent)
    /// and the address family. The CDN answers `400 10` for any other agent, so the right one is searched once, in order
    /// of likelihood (the official desktop plays with libavformat → «Lavf/…»), and the winner is remembered.
    private static let agentCandidates: [(label: String, ua: String)] = [
        ("lavf", "Lavf/61.7.100"),
        ("none", ""),
        ("max-desktop", "MAX/26.41.1"),
        ("coremedia", "AppleCoreMedia/1.0.0.24F74 (Macintosh; U; Intel Mac OS X 15_5; ru_ru)"),
        ("safari", "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"),
        ("chrome", chromeUA),
        ("curl", "curl/8.7.1"),
        ("rms", "RMS-MAKS"),
    ]
    private static let agentKey = "rmsmaks.video.agent"

    static func getVideo(_ url: URL) async throws -> Data {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let open: Set<String> = ["pr", "srcAg", "type", "ct", "clientType", "subId"]
        ProtocolLog.add("video url params: " + items.map { open.contains($0.name) ? "\($0.name)=\($0.value ?? "")" : $0.name }.joined(separator: ","))
        var order = agentCandidates
        if let saved = UserDefaults.standard.string(forKey: agentKey), let i = order.firstIndex(where: { $0.label == saved }) {
            order.insert(order.remove(at: i), at: 0)
        }
        var last = "?"
        for ipv4 in [false, true] {
            for (label, ua) in order {
                do {
                    let r = try await NWHTTPSClient.get(url: url, headers: ["User-Agent": ua], ipv4Only: ipv4)
                    if (200...299).contains(r.status), looksLikeVideo(r.body) {
                        ProtocolLog.add("video agent '\(label)'\(ipv4 ? " over IPv4" : "") accepted")
                        UserDefaults.standard.set(label, forKey: agentKey)
                        return r.body
                    }
                    last = "HTTP \(r.status) \(String(decoding: r.body.prefix(40), as: UTF8.self))"
                } catch {
                    last = error.localizedDescription
                }
            }
            ProtocolLog.add("video: no agent accepted\(ipv4 ? " (IPv4)" : ""): \(last)")
        }
        throw MediaError.downloadFailed(last)
    }

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
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let note = String(decoding: data.prefix(120), as: UTF8.self).replacingOccurrences(of: "\n", with: " ")
                throw MediaError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) \(note)")
            }
            return data
        } catch let e as MediaError {
            throw e
        } catch {
            // The system stack failed (TLS on some CDN hosts): retry over Network.framework.
            ProtocolLog.add("download \(url.host ?? "?")\(url.path) failed (\((error as NSError).code)); retrying over Network.framework")
            let r = try await NWHTTPSClient.get(url: url)
            guard (200...299).contains(r.status) else { throw MediaError.downloadFailed("HTTP \(r.status)") }
            return r.body
        }
    }
}

// MARK: - Upload / download API (mirrors rumax api/files.rs + messaging.rs)

extension MaxClient {
    /// opcode 80 → multipart POST → `photos.{id}.token`.
    public func uploadPhoto(data: Data, mime: String, profile: Bool = false, story: Bool = false) async throws -> String {
        let resp = try await getPhotoUploadURL(profile: profile, story: story)
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

        let (respData, response) = try await MediaHTTP.rawUpload(to: url, data: data, fileName: fileName)
        try MediaHTTP.checkOK(response, respData)
        return fileId
    }

    /// Story video: opcode 82 `{uploaderType: 0, type: 3}`.
    public func uploadStoryVideo(data: Data, fileName: String) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: 0, type: 3, fileName: fileName)
    }

    /// opcode 82 `type: 1` — round video message («кружок»), processed on the server (uploaderType 0).
    public func uploadVideoMessage(data: Data) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: 0, type: 1, fileName: "video-message.mp4")
    }

    /// opcode 82 (uploaderType 0, type 0) → raw POST → (videoId, token).
    public func uploadVideo(data: Data) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: 0, type: 0, fileName: "video.mp4")
    }

    /// Voice message: opcode 82 type 2. Like the official web client, non-Ogg audio (our AAC/M4A)
    /// goes through the processing uploader (uploaderType 0) so the server transcodes it; Ogg goes direct (1).
    public func uploadAudio(data: Data, isOgg: Bool = false) async throws -> (videoId: Int64, token: String) {
        try await uploadToVideoPlatform(data: data, uploaderType: isOgg ? 1 : 0, type: 2, fileName: isOgg ? "voice.ogg" : "voice.m4a")
    }

    private func uploadToVideoPlatform(data: Data, uploaderType: Int64, type: Int64, fileName: String) async throws -> (videoId: Int64, token: String) {
        let resp = try await sendAndWait(
            opcode: 82,
            payload: .object(["uploaderType": .int(uploaderType), "type": .int(type), "count": .int(1)])
        )
        guard let info = resp.payload["info"]?.arrayValue?.first,
              let urlStr = info["url"]?.stringValue, let url = URL(string: urlStr),
              let videoId = info["videoId"]?.int64Value
        else { throw MediaError.noUploadURL }
        var token = info["token"]?.stringValue ?? ""

        let (respData, response) = try await MediaHTTP.rawUpload(to: url, data: data, fileName: fileName)
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
    /// Every playable address of a video in order of preference (op 83 answers several renditions: MP4_144…MP4_1080, EXTERNAL…).
    /// The response keys are logged (names only, no tokens) so that a wrong guess can be diagnosed from the diagnostics log.
    public func videoPlaybackCandidates(chatId: Int64, messageId: Int64, videoId: Int64, token: String?) async throws -> [(key: String, url: URL)] {
        var obj: [String: JSONValue] = ["chatId": .int(chatId), "messageId": .int(messageId), "videoId": .int(videoId)]
        if let token { obj["token"] = .string(token) }
        let resp = try await sendAndWait(opcode: 83, payload: .object(obj))
        let all = resp.payload.objectValue ?? [:]
        ProtocolLog.add("video op=83 keys: " + all.keys.sorted().map { k in
            let v = all[k]; let isURL = v?.stringValue?.hasPrefix("http") == true
            return isURL ? "\(k)=url" : k
        }.joined(separator: ","))
        // EXTERNAL is a web page (m.ok.ru/video/…), not a file — never a candidate for a download.
        let order = ["MP4_480", "MP4_720", "MP4_360", "MP4_240", "MP4_144", "MP4_1080", "url", "MP4", "OGG", "MP3", "AUDIO"]
        var out: [(String, URL)] = []
        var seen = Set<String>()
        func add(_ k: String) {
            guard let str = all[k]?.stringValue, let u = URL(string: str), u.scheme?.hasPrefix("http") == true, seen.insert(str).inserted else { return }
            if u.path.hasSuffix(".m3u8") { return } // HLS cannot be saved as one file
            out.append((k, u))
        }
        order.forEach(add)
        for k in all.keys.sorted() where !order.contains(k) && !["EXTERNAL", "HLS", "O_HLS", "DASH", "O_DASH"].contains(k) { add(k) }
        guard !out.isEmpty else { throw MediaError.noDownloadURL }
        return out
    }

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

    /// Remote image bytes (stickers, avatars) cached on disk by URL hash; fetched through the
    /// Max-aware session (Max CDNs may use the Russian Trusted CA).
    public static func remoteImage(_ urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let key = SHA256.hash(data: Data(urlString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let file = self.url(key: "img", fileName: key)
        if let data = try? Data(contentsOf: file) { return data }
        guard let data = try? await MediaHTTP.get(url) else { return nil }
        try? data.write(to: file, options: .atomic)
        return data
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
            recordFailedSend(
                chatId: chatId, text: caption.trimmingCharacters(in: .whitespacesAndNewlines), replyToId: nil,
                attachment: FailedSend.Attachment(data: data, fileName: fileName, mime: mime, width: width, height: height,
                                                  durationMs: durationMs, wave: wave),
                error: error
            )
        }
    }

    /// The server needs a moment to process a fresh upload; it answers "attachment.not.ready" meanwhile.
    func sendWithRetry(chatId: Int64, text: String, attaches: [JSONValue]) async throws -> MaxResponse {
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
            if FileManager.default.fileExists(atPath: target.path) {
                if MediaHTTP.fileLooksLikeVideo(target) { return target }
                try? FileManager.default.removeItem(at: target) // an earlier build cached a web page here
            }
            let candidates = try await client.videoPlaybackCandidates(chatId: chatId, messageId: messageId, videoId: videoId, token: attachment.token)
            var lastError: Error = MediaError.noDownloadURL
            for (key, url) in candidates {
                do {
                    let data = try await MediaHTTP.getVideo(url)
                    try data.write(to: target, options: .atomic)
                    ProtocolLog.add("video \(key) \(url.host ?? "?")\(url.path) \(data.count) B downloaded")
                    return target
                } catch {
                    lastError = error
                    ProtocolLog.add("video \(key) \(url.host ?? "?")\(url.path) failed: \(error.localizedDescription)")
                }
            }
            throw lastError
        case .other:
            throw MediaError.unsupported("Этот тип вложения пока не поддерживается")
        }
    }
}

public extension AppStore {
    /// Round video message: op 82 `{count:1, type:1, uploaderType:0}` (server-side processing), then a `VIDEO` attach with
    /// `videoType: 1` and the duration. In an end-to-end chat the clip goes as a normal encrypted video instead.
    func sendVideoMessage(chatId: Int64, data: Data, durationMs: Int, width: Int = 480, height: Int = 480) async {
        let settings = chatSettingsByChat[chatId] ?? ChatE2ESettings()
        if settings.isActive {
            await sendAttachment(chatId: chatId, data: data, fileName: "video-message.mp4", mime: "video/mp4",
                                 width: width, height: height, durationMs: durationMs)
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let v = try await client.uploadVideoMessage(data: data)
            var attach: [String: JSONValue] = [
                "_type": .string("VIDEO"), "videoId": .int(v.videoId), "videoType": .int(1), "duration": .int(Int64(durationMs)),
            ]
            if !v.token.isEmpty { attach["token"] = .string(v.token) }
            let resp = try await sendWithRetry(chatId: chatId, text: "", attaches: [.object(attach)])
            if let msg = resp.payload["message"] { upsertMessage(parseMessage(msg, chatId: chatId), inChat: chatId, isIncomingPush: false) }
        } catch {
            recordFailedSend(
                chatId: chatId, text: "", replyToId: nil,
                attachment: FailedSend.Attachment(data: data, fileName: "video-message.mp4", mime: "video/mp4", width: width, height: height,
                                                  durationMs: durationMs, wave: nil, isVideoMessage: true),
                error: error
            )
        }
    }
}
