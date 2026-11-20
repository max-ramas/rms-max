import Foundation

// MARK: - Dynamic JSON / MsgPack Value

public enum JSONValue: Sendable, Equatable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case binary(Data)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let b):
            try container.encode(b)
        case .int(let i):
            try container.encode(i)
        case .double(let d):
            try container.encode(d)
        case .string(let s):
            try container.encode(s)
        case .binary(let data):
            try container.encode(Array(data))
        case .array(let arr):
            try container.encode(arr)
        case .object(let obj):
            try container.encode(obj)
        }
    }

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let map) = self else { return nil }
            return map[key]
        }
        set {
            guard case .object(var map) = self else { return }
            if let v = newValue {
                map[key] = v
            } else {
                map.removeValue(forKey: key)
            }
            self = .object(map)
        }
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, index >= 0, index < arr.count else { return nil }
        return arr[index]
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var int64Value: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int64(d)
        case .string(let s): return Int64(s)
        default: return nil
        }
    }

    public var uint64Value: UInt64? {
        switch self {
        case .int(let i) where i >= 0: return UInt64(i)
        case .string(let s): return UInt64(s)
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let arr) = self { return arr }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let obj) = self { return obj }
        return nil
    }

    public var bytesValue: [UInt8]? {
        switch self {
        case .binary(let d): return Array(d)
        case .array(let arr):
            var out: [UInt8] = []
            out.reserveCapacity(arr.count)
            for el in arr {
                guard let v = el.int64Value, v >= 0, v <= 255 else { return nil }
                out.append(UInt8(v))
            }
            return out
        default: return nil
        }
    }
}

// MARK: - Protocol Identity & Wire Envelopes

public struct MaxUserAgent: Codable, Sendable, Equatable {
    public var deviceType: String
    public var appVersion: String
    public var osVersion: String
    public var timezone: String
    public var screen: String
    public var pushDeviceType: String?
    public var arch: String?
    public var locale: String
    public var buildNumber: Int32
    public var deviceName: String
    public var deviceLocale: String
    public var release: Int32?
    public var headerUserAgent: String?

    public init(
        deviceType: String,
        appVersion: String,
        osVersion: String,
        timezone: String,
        screen: String,
        pushDeviceType: String? = nil,
        arch: String? = nil,
        locale: String,
        buildNumber: Int32,
        deviceName: String,
        deviceLocale: String,
        release: Int32? = nil,
        headerUserAgent: String? = nil
    ) {
        self.deviceType = deviceType
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.timezone = timezone
        self.screen = screen
        self.pushDeviceType = pushDeviceType
        self.arch = arch
        self.locale = locale
        self.buildNumber = buildNumber
        self.deviceName = deviceName
        self.deviceLocale = deviceLocale
        self.release = release
        self.headerUserAgent = headerUserAgent
    }

    public func toJSONValue() -> JSONValue {
        var map: [String: JSONValue] = [
            "deviceType": .string(deviceType),
            "appVersion": .string(appVersion),
            "osVersion": .string(osVersion),
            "timezone": .string(timezone),
            "locale": .string(locale),
            "buildNumber": .int(Int64(buildNumber)),
            "deviceName": .string(deviceName),
            "deviceLocale": .string(deviceLocale),
        ]
        if !screen.isEmpty { map["screen"] = .string(screen) }
        if let pushDeviceType { map["pushDeviceType"] = .string(pushDeviceType) }
        if let arch { map["arch"] = .string(arch) }
        if let release { map["release"] = .int(Int64(release)) }
        if let headerUserAgent { map["headerUserAgent"] = .string(headerUserAgent) }
        return .object(map)
    }
}

public struct MaxIdentity: Codable, Sendable, Equatable {
    public var deviceId: String
    public var mtInstance: String
    public var userAgent: MaxUserAgent

    public init(deviceId: String, mtInstance: String, userAgent: MaxUserAgent) {
        self.deviceId = deviceId
        self.mtInstance = mtInstance
        self.userAgent = userAgent
    }

    public static func generateMobile() -> MaxIdentity {
        let profiles: [(String, String, String)] = [
            ("Pixel 8", "Android 14", "428dpi 428dpi 1080x2400"),
            ("Samsung SM-S911B", "Android 14", "425dpi 425dpi 1080x2340"),
            ("Xiaomi 23049PCD8G", "Android 14", "446dpi 446dpi 1220x2712"),
            ("OnePlus CPH2449", "Android 14", "451dpi 451dpi 1240x2772"),
        ]
        let chosen = profiles.randomElement() ?? profiles[0]
        let tz = TimeZone.current.identifier.isEmpty ? "Europe/Moscow" : TimeZone.current.identifier
        let mtInstance = UUID().uuidString.lowercased()
        let deviceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        return MaxIdentity(
            deviceId: deviceId,
            mtInstance: mtInstance,
            userAgent: MaxUserAgent(
                deviceType: "ANDROID",
                appVersion: "26.31.0",
                osVersion: chosen.1,
                timezone: tz,
                screen: chosen.2,
                pushDeviceType: "GCM",
                arch: "arm64-v8a",
                locale: "ru",
                buildNumber: 6822,
                deviceName: chosen.0,
                deviceLocale: "ru"
            )
        )
    }

    /// The official MAX desktop client (Qt, ru.oneme.desktop) — see docs/official-desktop-protocol.md.
    /// The server enables the desktop opcode set (stories 219, invite links 221-223, call history 163, presence 35)
    /// for this device type, and code requests need no Android fingerprint.
    public static let desktopAppVersion = "26.41.1"
    public static let desktopBuildNumber: Int32 = 83827

    public static func generateDesktop() -> MaxIdentity {
        let tz = TimeZone.current.identifier.isEmpty ? "Europe/Moscow" : TimeZone.current.identifier
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        let os = "macOS \(v.majorVersion).\(v.minorVersion)"
        let name = "Mac"
        #else
        let os = "iOS \(v.majorVersion).\(v.minorVersion)"
        let name = "iPhone"
        #endif
        let lang = Locale.current.language.languageCode?.identifier ?? "ru"
        return MaxIdentity(
            deviceId: UUID().uuidString.lowercased(),
            mtInstance: "",
            userAgent: MaxUserAgent(
                deviceType: "DESKTOP",
                appVersion: desktopAppVersion,
                osVersion: os,
                timezone: tz,
                screen: "",
                locale: "ru",
                buildNumber: desktopBuildNumber,
                deviceName: name,
                deviceLocale: lang
            )
        )
    }

    public var isDesktop: Bool { userAgent.deviceType.uppercased().hasPrefix("DESKTOP") }

    public static func generateWeb() -> MaxIdentity {
        let tz = TimeZone.current.identifier.isEmpty ? "Europe/Moscow" : TimeZone.current.identifier
        let mtInstance = UUID().uuidString.lowercased()
        let deviceId = UUID().uuidString.lowercased()
        return MaxIdentity(
            deviceId: deviceId,
            mtInstance: mtInstance,
            userAgent: MaxUserAgent(
                deviceType: "WEB",
                appVersion: "26.31.0",
                osVersion: "macOS",
                timezone: tz,
                screen: "1440x900 2.0x",
                locale: "ru",
                buildNumber: 6822,
                deviceName: "Safari",
                deviceLocale: "ru",
                headerUserAgent: MaxConstants.webUserAgent
            )
        )
    }
}

public enum MaxConstants {
    public static let webSocketURI = "wss://ws-api.oneme.ru/websocket"
    public static let mobileHost = "api2.oneme.ru"
    public static let mobilePort: UInt16 = 443
    public static let originHeader = "https://web.max.ru"
    public static let webUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    public static let pingIntervalSeconds: TimeInterval = 30
    public static let requestTimeoutSeconds: TimeInterval = 12
}

public struct MaxRequest: Sendable, Codable {
    public let ver: UInt8
    public let cmd: UInt8
    public let seq: UInt16
    public let opcode: UInt16
    public let payload: JSONValue

    public init(ver: UInt8 = 10, cmd: UInt8 = 0, seq: UInt16, opcode: UInt16, payload: JSONValue) {
        self.ver = ver
        self.cmd = cmd
        self.seq = seq
        self.opcode = opcode
        self.payload = payload
    }
}

public struct MaxResponse: Sendable, Codable {
    public let ver: UInt8
    public let cmd: UInt8
    public let seq: UInt16
    public let opcode: UInt16
    public let payload: JSONValue

    public init(ver: UInt8, cmd: UInt8, seq: UInt16, opcode: UInt16, payload: JSONValue) {
        self.ver = ver
        self.cmd = cmd
        self.seq = seq
        self.opcode = opcode
        self.payload = payload
    }
}

public struct SyncState: Codable, Sendable, Equatable {
    public var chatsSync: Int64 = -1
    public var contactsSync: Int64 = -1
    public var draftsSync: Int64 = -1
    public var presenceSync: Int64 = -1
    public var configHash: JSONValue?

    public init(
        chatsSync: Int64 = -1,
        contactsSync: Int64 = -1,
        draftsSync: Int64 = -1,
        presenceSync: Int64 = -1,
        configHash: JSONValue? = nil
    ) {
        self.chatsSync = chatsSync
        self.contactsSync = contactsSync
        self.draftsSync = draftsSync
        self.presenceSync = presenceSync
        self.configHash = configHash
    }
}

// MARK: - Domain Models

public enum ChatType: String, Codable, Sendable {
    case dialog = "DIALOG"
    case chat = "CHAT"
    case channel = "CHANNEL"
    case unknown
}

public struct MaxReactionCount: Codable, Sendable, Equatable, Hashable {
    public let reaction: String
    public let count: Int
}

public struct MaxAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let title: String?
    public let url: String?
    public let fileId: Int64?
    public let photoId: Int64?
    public let videoId: Int64?
    public let width: Int?
    public let height: Int?
    public let durationMs: Double?
    public let mime: String?
    public let size: UInt64?
    /// Video/audio access token returned by the server alongside `videoId`.
    public var token: String? = nil
    /// Voice waveform (0…120 per sample) when the server provides it.
    public var wave: [UInt8]? = nil
    /// `_type: POLL` attachments.
    public var poll: MaxPoll? = nil
    /// `_type: INLINE_KEYBOARD` (bot buttons).
    public var keyboard: BotKeyboard? = nil
    /// `_type: SHARE` link preview.
    public var share: LinkShare? = nil
    /// `_type: CONTROL` service event (`event`, `userIds`, `title`).
    public var control: ControlEvent? = nil
    /// `_type: CONTACT`.
    public var contactId: Int64? = nil
    /// `_type: LOCATION`.
    public var latitude: Double? = nil
    public var longitude: Double? = nil

    public var kind: AttachmentKind { AttachmentKind(rawType: type) }
}

public struct LinkShare: Codable, Sendable, Equatable {
    public var url: String
    public var title: String?
    public var description: String?
    public var host: String?
    public var imageURL: String?

    public init(url: String, title: String?, description: String?, host: String?, imageURL: String?) {
        self.url = url; self.title = title; self.description = description; self.host = host; self.imageURL = imageURL
    }
}

public struct ControlEvent: Codable, Sendable, Equatable {
    public var event: String
    public var userIds: [Int64]
    public var title: String?
    /// `system`: server-provided text; `privacyWarning`: screenshot | screencast.
    public var message: String? = nil
    public var kind: String? = nil

    /// Short text for chat-list previews (no names).
    public var summary: String {
        switch event {
        case "new": return "Чат создан"
        case "add": return "Новые участники"
        case "remove": return "Участник исключён"
        case "leave": return "Участник вышел"
        case "joinByLink": return "Вступление по ссылке"
        case "title": return title.map { "Новое название: \($0)" } ?? "Изменено название"
        case "icon": return "Изменено фото чата"
        case "pin": return "Закреплено сообщение"
        case "botStarted": return "Бот запущен"
        case "system": return message ?? "Системное сообщение"
        case "hello": return "Теперь в MAX"
        case "privacyWarning": return kind == "screencast" ? "Идёт запись экрана" : "Сделан снимок экрана"
        case "sendContact": return "Предложение обменяться контактами"
        default: return "Служебное сообщение"
        }
    }
}

public struct BotKeyboard: Codable, Sendable, Equatable {
    public struct Button: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(type)|\(text)|\(payload ?? url ?? "")" }
        public let type: String    // LINK CALLBACK CHAT CLIPBOARD MESSAGE REQUEST_CONTACT REQUEST_GEO_LOCATION OPEN_APP
        public let text: String
        public let payload: String?
        public let url: String?
    }
    public let callbackId: String
    public let rows: [[Button]]

    public static func parse(_ a: JSONValue) -> BotKeyboard? {
        guard let cb = a["callbackId"]?.stringValue else { return nil }
        let rows = (a["keyboard"]?["buttons"]?.arrayValue ?? []).map { row in
            (row.arrayValue ?? []).map { b in
                Button(type: b["type"]?.stringValue ?? "CALLBACK", text: b["text"]?.stringValue ?? "",
                       payload: b["payload"]?.stringValue, url: b["url"]?.stringValue)
            }
        }
        return BotKeyboard(callbackId: cb, rows: rows)
    }
}

public struct MaxPoll: Codable, Sendable, Equatable {
    public struct Answer: Codable, Sendable, Equatable, Identifiable {
        public let id: Int
        public let text: String
        public var votes: Int
        public var percent: Int?
        public var votedByMe: Bool
    }
    public let pollId: Int64
    public let title: String
    public let settings: Int
    public var answers: [Answer]
    public var total: Int

    public var isAnonymous: Bool { settings & 1 != 0 }
    public var isMultiple: Bool { settings & 2 != 0 }
    public var canRevote: Bool { settings & 4 != 0 }
    public var isClosed: Bool { settings & 8 != 0 }
    public var isQuiz: Bool { settings & 16 != 0 }
    public var hasVoted: Bool { answers.contains(where: \.votedByMe) }

    /// From the attachment (`answers`) plus its `state.result`.
    public static func parse(_ a: JSONValue) -> MaxPoll? {
        guard let id = a["pollId"]?.int64Value else { return nil }
        var poll = MaxPoll(
            pollId: id,
            title: a["title"]?.stringValue ?? "Опрос",
            settings: Int(a["settings"]?.int64Value ?? 0),
            answers: (a["answers"]?.arrayValue ?? []).map {
                Answer(id: Int($0["answerId"]?.int64Value ?? 0), text: $0["text"]?.stringValue ?? "", votes: 0, percent: nil, votedByMe: false)
            },
            total: 0
        )
        poll.apply(state: a["state"])
        return poll
    }

    /// `state: {total, result: [{answerId, voteCount, rate, options(bit 1 = my vote)}]}`.
    public mutating func apply(state: JSONValue?) {
        guard let state else { return }
        total = Int(state["total"]?.int64Value ?? Int64(total))
        for r in state["result"]?.arrayValue ?? [] {
            let aid = Int(r["answerId"]?.int64Value ?? 0)
            guard let i = answers.firstIndex(where: { $0.id == aid }) else { continue }
            answers[i].votes = Int(r["voteCount"]?.int64Value ?? 0)
            answers[i].percent = r["rate"]?.int64Value.map(Int.init)
            answers[i].votedByMe = (r["options"]?.int64Value ?? 0) & 1 != 0
        }
    }
}

public enum AttachmentKind: String, Sendable {
    case photo, video, audio, file, sticker, other

    public init(rawType: String) {
        switch rawType.uppercased() {
        case "PHOTO": self = .photo
        case "VIDEO": self = .video
        case "AUDIO": self = .audio
        case "FILE": self = .file
        case "STICKER": self = .sticker
        default: self = .other
        }
    }

    public func label(name: String?) -> String {
        switch self {
        case .photo: return "Фото"
        case .video: return "Видео"
        case .audio: return "Голосовое сообщение"
        case .sticker: return "Стикер"
        case .file: return name.map { "Файл: \($0)" } ?? "Файл"
        case .other: return "Вложение"
        }
    }

    /// Classifies a local file to the Max attach type used when sending.
    public static func forUpload(mime: String) -> AttachmentKind {
        let m = mime.lowercased()
        if ["image/jpeg", "image/png", "image/webp", "image/heic"].contains(m) { return .photo }
        if m.hasPrefix("video/") { return .video }
        return .file
    }
}

public struct MediaDescriptor: Codable, Sendable, Equatable {
    public var attachIndex: Int
    public var name: String
    public var mime: String
    public var mediaType: String
    public var size: UInt64
    public var width: UInt32?
    public var height: UInt32?
    public var duration: Double?
    public var wave: [UInt8]?
    public var videoType: Int32?
    public var color: String?

    enum CodingKeys: String, CodingKey {
        case attachIndex = "attach_index"
        case name
        case mime
        case mediaType = "media_type"
        case size
        case width
        case height
        case duration
        case wave
        case videoType = "video_type"
        case color
    }
}

public struct DecryptedMessageState: Codable, Sendable, Equatable {
    public var text: String
    public let obfuscation: String?
    public let isEncrypted: Bool
    public let media: MediaDescriptor?
    public let isHandshakeRequest: Bool
    public let isHandshakeAccept: Bool
    public let isGroupAnnounce: Bool
    public let isGroupKeyWrap: Bool
    public let handshakeDataHex: String?
    public let error: String?
}

public struct MaxMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let chatId: Int64
    public let senderId: Int64
    public var text: String
    public let timeMs: Int64
    public var edited: Bool
    public var deleted: Bool
    public var replyToMessageId: String?
    public var attaches: [MaxAttachment]
    public var reactions: [MaxReactionCount]
    public var decrypted: DecryptedMessageState?
    /// Author of the original message when this one is a forward (`link.type == FORWARD`).
    public var forwardedFromId: Int64? = nil

    /// Text body only (decrypted when E2E), without attachment placeholders.
    public var bodyText: String {
        decrypted?.text ?? text
    }

    /// Text for previews and lists: body, or a label describing the attachment.
    public var displayText: String {
        let body = bodyText
        if !body.isEmpty { return body }
        if let media = decrypted?.media {
            return "🔒 " + AttachmentKind(rawType: media.mediaType).label(name: media.name)
        }
        if let share = attaches.first(where: { $0.share != nil })?.share {
            return share.title ?? share.url
        }
        if let first = attaches.first(where: { $0.keyboard == nil }) {
            if let c = first.control { return c.summary }
            if first.contactId != nil { return "Контакт" }
            if first.latitude != nil { return "Геопозиция" }
            if first.poll != nil { return "Опрос" }
            return first.kind.label(name: first.title)
        }
        return body
    }

    public var date: Date {
        Date(timeIntervalSince1970: TimeInterval(timeMs) / 1000.0)
    }
}

public struct MaxContact: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public var isBlocked: Bool? = nil
    public var isInContacts: Bool? = nil
    public var isBot: Bool? = nil
    public var name: String
    public var firstName: String
    public var lastName: String
    public var phone: String?
    public var avatarURL: String?
    public var description: String?
    public var isOnline: Bool
    public var lastSeenMs: Int64?
    /// Public profile link (max.ru/<nick>), registration time (ms), gender.
    public var link: String? = nil
    public var registrationTime: Int64? = nil
    public var gender: String? = nil
    /// The user's own profile name when I renamed them (names[type=ONEME] differs from CUSTOM).
    public var profileName: String? = nil
}

/// A group call running in a chat (`chat.videoConversation`).
public struct ChatActiveCall: Codable, Sendable, Equatable {
    public var conversationId: String
    public var joinLink: String
    public var startedAt: Int64?
    public var participantsCount: Int?
    public var isVideo: Bool

    public init(conversationId: String, joinLink: String, startedAt: Int64?, participantsCount: Int?, isVideo: Bool) {
        self.conversationId = conversationId
        self.joinLink = joinLink
        self.startedAt = startedAt
        self.participantsCount = participantsCount
        self.isVideo = isVideo
    }
}

public struct MaxChat: Codable, Sendable, Equatable, Identifiable {
    public let id: Int64
    public var type: ChatType
    public var title: String
    public var avatarURL: String?
    public var lastEventTime: Int64
    public var newMessages: Int
    public var dontDisturbUntil: Int64
    public var participants: [Int64: Int64]
    public var lastMessage: MaxMessage?
    public var pinnedMessageId: String?
    public var activeCall: ChatActiveCall? = nil
    // Group info (chat schema): owner, admins, private link, description, counters, options.
    public var ownerId: Int64? = nil
    public var adminIds: [Int64] = []
    public var link: String? = nil
    public var chatDescription: String? = nil
    public var participantsCount: Int? = nil
    public var pendingJoinRequests: Int = 0
    public var options: [String: Bool] = [:]
    public var hasBots: Bool = false

    public var isMuted: Bool {
        if dontDisturbUntil < 0 { return true }
        if dontDisturbUntil > 0 {
            return Double(dontDisturbUntil) > Date().timeIntervalSince1970 * 1000.0
        }
        return false
    }
}

public struct MaxAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: UInt64
    public var userId: Int64?
    public var displayName: String
    public var phone: String?
    public var avatarURL: String?
    public var token: String
    public var identity: MaxIdentity
    public var useMobileTransport: Bool
    public var telemetryMode: String
    public var biometricLockEnabled: Bool

    public init(
        id: UInt64,
        userId: Int64? = nil,
        displayName: String = "Пользователь",
        phone: String? = nil,
        avatarURL: String? = nil,
        token: String,
        identity: MaxIdentity,
        useMobileTransport: Bool = true,
        telemetryMode: String = "disabled",
        biometricLockEnabled: Bool = false
    ) {
        self.id = id
        self.userId = userId
        self.displayName = displayName
        self.phone = phone
        self.avatarURL = avatarURL
        self.token = token
        self.identity = identity
        self.useMobileTransport = useMobileTransport
        self.telemetryMode = telemetryMode
        self.biometricLockEnabled = biometricLockEnabled
    }
}

public struct MaxSessionInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String { client + "_" + String(time) }
    public let client: String
    public let location: String
    public let time: Int64
    public let current: Bool
    public let info: String
}

// MARK: - Chat E2E Settings

public struct E2ESessionInfo: Codable, Sendable, Equatable {
    public var sharedSecretHex: String
    public var fingerprint: String
    public var peerEdPkHex: String?
    public var peerXPkHex: String?
    public var myEdSkHex: String?
    public var myEdPkHex: String?
    public var establishedAt: Int64
    public var isGroup: Bool
    public var createdBySelf: Bool
}

public struct ArchivedSessionKey: Codable, Sendable, Equatable {
    public var sharedSecretHex: String
    public var fingerprint: String
    public var messageFrom: Int64
    public var messageUntil: Int64
}

public struct KeypairBundleHex: Codable, Sendable, Equatable {
    public var edSkHex: String
    public var edPkHex: String
    public var xSkHex: String
    public var xPkHex: String
    public var timestamp: Int64?
}

public struct GroupMemberKeyInfo: Codable, Sendable, Equatable {
    public var edPkHex: String
    public var xPkHex: String
    public var updatedAt: Int64
}

public struct ChatE2ESettings: Codable, Sendable, Equatable {
    public var session: E2ESessionInfo?
    public var archivedKeys: [ArchivedSessionKey] = []
    public var pending: KeypairBundleHex?
    public var groupIdentity: KeypairBundleHex?
    public var groupMembers: [String: GroupMemberKeyInfo] = [:]
    public var password: String?
    public var obfuscation: String? // "zh" | "none"
    public var handledHandshakes: [String] = []
    public var rejectedHandshakes: [String] = []

    public init() {}

    public var isActive: Bool {
        session != nil || !(password?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    public var allSessionSecrets: [Data] {
        var result: [Data] = []
        if let activeHex = session?.sharedSecretHex, let data = Data(hexString: activeHex), data.count == 32 {
            result.append(data)
        }
        for item in archivedKeys {
            if let data = Data(hexString: item.sharedSecretHex), data.count == 32, !result.contains(data) {
                result.append(data)
            }
        }
        return result
    }
}

public struct PendingE2ERequest: Sendable, Equatable, Identifiable {
    public var id: String { "\(chatId):\(messageId)" }
    public let chatId: Int64
    public let messageId: String
    public let handshakeDataHex: String
    public let isGroup: Bool
}

// MARK: - Calls State

public enum CallPhase: String, Sendable {
    case idle
    case connecting
    case ringing
    case active
    case ended
}

public enum CallSecureStatus: String, Sendable {
    case plain
    case pending
    case active
    case unsupported
}

public struct CallChatMessage: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let senderName: String
    public let text: String
    public let date: Date
    public let mine: Bool
    public let direct: Bool

    public init(senderName: String, text: String, date: Date = Date(), mine: Bool, direct: Bool = false) {
        id = UUID()
        self.senderName = senderName
        self.text = text
        self.date = date
        self.mine = mine
        self.direct = direct
    }
}

/// A remote participant of the current call (ids are calls-platform ids, not Max ids).
public struct CallParticipantInfo: Identifiable, Equatable, Sendable {
    public var id: Int64
    public var maxUserId: Int64?
    public var name: String
    public var videoEnabled: Bool = false
    public var audioEnabled: Bool = true
    public var speaking: Bool = false
    public var joined: Bool = false
    public var handRaised: Bool = false
    public var screenSharing: Bool = false
    public var roles: [String] = []
    public var isAdmin: Bool { roles.contains("ADMIN") || roles.contains("CREATOR") }

    public init(id: Int64, maxUserId: Int64?, name: String) {
        self.id = id
        self.maxUserId = maxUserId
        self.name = name
    }
}

public struct ActiveCallState: Sendable, Equatable {
    public var phase: CallPhase = .idle
    public var isIncoming: Bool = false
    public var conversationId: String = ""
    public var chatId: Int64?
    public var peerId: Int64?
    public var peerName: String = ""
    public var isVideo: Bool = false
    public var isGroup: Bool = false
    public var isMuted: Bool = false
    public var cameraEnabled: Bool = false
    public var remoteVideoEnabled: Bool = false
    public var remoteMuted: Bool = false
    public var speakerOn: Bool = false
    /// "DIRECT" (peer-to-peer, possibly via TURN) or "SERVER" (platform SFU).
    public var topology: String = "DIRECT"
    public var participants: [CallParticipantInfo] = []
    // In-call features (official calls platform): chat, hand, roles, recording, waiting hall.
    public var chat: [CallChatMessage] = []
    public var unreadChat: Int = 0
    public var handRaised: Bool = false
    public var myRoles: [String] = []
    public var isAdmin: Bool { myRoles.contains("ADMIN") || myRoles.contains("CREATOR") }
    public var recording: Bool = false
    public var options: [String] = []
    public var waitingHall: [CallParticipantInfo] = []
    public var mutedByAdmin: Bool = false
    public var sharingScreen: Bool = false
    public var secureStatus: CallSecureStatus = .plain
    public var fingerprint: String?
    public var inviteLink: String?
    public var wsEndpoint: String?
    public var startedAt: Date?
    public var statusMessage: String?

    public init() {}
}

// MARK: - Hex Utilities

public extension Data {
    init?(hexString: String) {
        let clean = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count % 2 == 0 else { return nil }
        var bytes = Data()
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let nextIndex = clean.index(index, offsetBy: 2)
            guard let b = UInt8(clean[index..<nextIndex], radix: 16) else { return nil }
            bytes.append(b)
            index = nextIndex
        }
        self = bytes
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
