import Foundation

/// What a cache folder holds, derived from its key prefix (`photo_…`, `video_…`, `audio_…`, `file_…`/`enc_…`, `img`).
public enum MediaKind: String, CaseIterable, Identifiable, Sendable {
    case photo, video, voice, file, small
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .photo: return "Фото"
        case .video: return "Видео и кружки"
        case .voice: return "Голосовые"
        case .file: return "Файлы"
        case .small: return "Аватары и стикеры"
        }
    }

    static func of(key: String) -> MediaKind {
        if key.hasPrefix("photo_") { return .photo }
        if key.hasPrefix("video_") { return .video }
        if key.hasPrefix("audio_") { return .voice }
        if key.hasPrefix("file_") || key.hasPrefix("enc_") { return .file }
        return .small
    }
}

/// Auto-download rules, as in Telegram's «Данные и память».
public struct MediaAutoDownload: Equatable, Sendable {
    public var photos = true
    public var circles = true
    public var voice = true
    /// Regular videos up to this size (MB); 0 = never automatically.
    public var videoMaxMB = 20
    public var fileMaxMB = 10
    /// Metered networks (mobile data, personal hotspot): only voice messages.
    public var onMeteredNetwork = false

    public init() {}

    private enum K { static let photos = "rmsmaks.auto.photos", circles = "rmsmaks.auto.circles", voice = "rmsmaks.auto.voice"
        static let video = "rmsmaks.auto.videoMB", file = "rmsmaks.auto.fileMB", metered = "rmsmaks.auto.metered", limit = "rmsmaks.cache.limitMB" }

    public static var current: MediaAutoDownload {
        get {
            let d = UserDefaults.standard
            var s = MediaAutoDownload()
            s.photos = d.object(forKey: K.photos) as? Bool ?? true
            s.circles = d.object(forKey: K.circles) as? Bool ?? true
            s.voice = d.object(forKey: K.voice) as? Bool ?? true
            s.videoMaxMB = d.object(forKey: K.video) as? Int ?? 20
            s.fileMaxMB = d.object(forKey: K.file) as? Int ?? 10
            s.onMeteredNetwork = d.object(forKey: K.metered) as? Bool ?? false
            return s
        }
        set {
            let d = UserDefaults.standard
            d.set(newValue.photos, forKey: K.photos); d.set(newValue.circles, forKey: K.circles); d.set(newValue.voice, forKey: K.voice)
            d.set(newValue.videoMaxMB, forKey: K.video); d.set(newValue.fileMaxMB, forKey: K.file); d.set(newValue.onMeteredNetwork, forKey: K.metered)
        }
    }

    /// Cache size limit in MB; 0 = unlimited. Default 2 GB.
    public static var limitMB: Int {
        get { UserDefaults.standard.object(forKey: K.limit) as? Int ?? 2048 }
        set { UserDefaults.standard.set(newValue, forKey: K.limit) }
    }

    /// Should this attachment be fetched without the user asking?
    public func shouldDownload(_ a: MaxAttachment, metered: Bool = false) -> Bool {
        if metered && !onMeteredNetwork { return a.kind == .audio && voice }
        switch a.kind {
        case .photo: return photos
        case .audio: return voice
        case .video:
            if a.isVideoMessage { return circles }
            guard videoMaxMB > 0, let size = a.size else { return false }
            return size <= UInt64(videoMaxMB) * 1_048_576
        case .file:
            guard fileMaxMB > 0, let size = a.size else { return false }
            return size <= UInt64(fileMaxMB) * 1_048_576
        case .sticker, .other: return false
        }
    }
}

public extension MediaCache {
    struct Entry { let url: URL; let size: Int64; let date: Date; let kind: MediaKind }

    static func entries() -> [Entry] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        guard let dirs = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var out: [Entry] = []
        for d in dirs {
            let kind = MediaKind.of(key: d.lastPathComponent)
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: keys) else { continue }
            if files.isEmpty { try? fm.removeItem(at: d); continue } // leftovers of failed downloads
            for f in files {
                let v = try? f.resourceValues(forKeys: Set(keys))
                if v?.isDirectory == true { continue }
                out.append(Entry(url: f, size: Int64(v?.fileSize ?? 0), date: v?.contentModificationDate ?? .distantPast, kind: kind))
            }
        }
        return out
    }

    /// Bytes per kind.
    static func stats() -> [MediaKind: Int64] {
        entries().reduce(into: [:]) { $0[$1.kind, default: 0] += $1.size }
    }

    /// Removes the cached files of the given kinds (all kinds by default).
    static func clear(kinds: Set<MediaKind> = Set(MediaKind.allCases)) {
        for e in entries() where kinds.contains(e.kind) {
            try? FileManager.default.removeItem(at: e.url)
        }
        _ = entries() // drops the emptied folders
    }

    /// Deletes the least recently used files until the cache is below ~85 % of the limit.
    @discardableResult
    static func enforceLimit(_ limitBytes: Int64) -> Int {
        guard limitBytes > 0 else { return 0 }
        var all = entries()
        var total = all.reduce(Int64(0)) { $0 + $1.size }
        guard total > limitBytes else { return 0 }
        let target = Int64(Double(limitBytes) * 0.85)
        all.sort { $0.date < $1.date }
        var removed = 0
        for e in all where total > target {
            try? FileManager.default.removeItem(at: e.url)
            total -= e.size
            removed += 1
        }
        return removed
    }

    /// Marks a file as used just now.
    static func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private static let limitQueue = DispatchQueue(label: "dev.rms.maks.cache.limit", qos: .utility)
    nonisolated(unsafe) private static var limitCheckPending = false

    /// Debounced: a burst of downloads triggers a single check a few seconds later.
    static func scheduleLimitCheck() {
        limitQueue.async {
            guard !limitCheckPending else { return }
            limitCheckPending = true
            limitQueue.asyncAfter(deadline: .now() + 5) {
                limitCheckPending = false
                let mb = MediaAutoDownload.limitMB
                let removed = enforceLimit(Int64(mb) * 1_048_576)
                if removed > 0 { ProtocolLog.add("media cache: \(removed) old files removed (limit \(mb) MB)") }
            }
        }
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
