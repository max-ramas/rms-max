import Foundation

/// At most `limit` downloads at a time; the rest waits.
actor PrefetchGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { free = limit }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Downloads media in advance, like Telegram: circles, voice messages and photos of the opened chat and of new incoming
/// messages are on the device before the user taps them. Rules and size limits come from `MediaAutoDownload`.
public extension AppStore {
    /// Where the media of an attachment is cached when it is already there (no network).
    func cachedMediaFile(for a: MaxAttachment) -> URL? {
        let key: String
        let name: String
        switch a.kind {
        case .video: guard let id = a.videoId else { return nil }; key = "video_\(id)"; name = "video.mp4"
        case .audio:
            let id = a.videoId.map(String.init) ?? a.id
            key = "audio_\(id)"
            let caf = MediaCache.url(key: key, fileName: "voice.caf")
            if FileManager.default.fileExists(atPath: caf.path) { return caf }
            let m4a = MediaCache.url(key: key, fileName: "voice.m4a")
            return FileManager.default.fileExists(atPath: m4a.path) ? m4a : nil
        default: return nil
        }
        let url = MediaCache.url(key: key, fileName: name)
        guard FileManager.default.fileExists(atPath: url.path), (a.kind != .video || MediaHTTP.fileLooksLikeVideo(url)) else { return nil }
        return url
    }

    /// Queues the downloads the rules allow for these messages (newest first). End-to-end messages are never cached in
    /// the clear in advance.
    func prefetchMedia(_ messages: [MaxMessage]) {
        let rules = MediaAutoDownload.current
        for m in messages.suffix(40).reversed() where m.decrypted == nil || m.decrypted?.media == nil {
            for a in m.attaches where rules.shouldDownload(a, metered: networkIsMetered) {
                let key = "\(m.chatId)_\(m.id)_\(a.id)"
                guard !mediaReady.contains(key), prefetchInFlight.insert(key).inserted else { continue }
                if cachedMediaFile(for: a) != nil { mediaReady.insert(key); prefetchInFlight.remove(key); continue }
                Task { [weak self] in
                    guard let self else { return }
                    await self.prefetchGate.acquire()
                    defer { Task { await self.prefetchGate.release() } }
                    do {
                        _ = try await self.localFile(for: a, in: m)
                        self.mediaReady.insert(key)
                    } catch {
                        ProtocolLog.add("prefetch \(a.kind) failed: \(error.localizedDescription)")
                    }
                    self.prefetchInFlight.remove(key)
                }
            }
        }
    }

    func isMediaReady(chatId: Int64, messageId: String, attachment: MaxAttachment) -> Bool {
        mediaReady.contains("\(chatId)_\(messageId)_\(attachment.id)") || cachedMediaFile(for: attachment) != nil
    }
}
