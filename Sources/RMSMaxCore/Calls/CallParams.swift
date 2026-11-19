import Foundation

/// Parameters of the OK Calls platform that official Max clients use for audio/video calls.
/// Reconstructed from the official web client (web.max.ru, embedded OK Calls SDK); only what a
/// 1:1 call needs — none of the SDK's statistics/log-upload endpoints are ever contacted.
public enum OKCalls {
    /// Application key the official web client passes to the calls platform (`CNHIJPLGDIHBABABA`).
    public static let webAppKey = "CNHIJPLGDIHBABABA"
    public static let webSdkVersion = "2.8.13-beta.14"
    /// Signaling protocol version (5 unless joining from multiple devices).
    public static let protocolVersion = 5
    /// Capability bitmask, hex: producerScreenTrack | waitingHall | filteredMessages |
    /// consumerScreenTrack | muteNotificationForAdmins — the always-on flags of the web SDK.
    public static let capabilities = "3D"
    /// Calls API base (`<base>/fb.do`) when the server config has no `calls-endpoint`.
    public static let defaultApiBase = "https://calls.okcdn.ru"
    /// Max app opcodes involved in calls.
    public enum Opcode {
        public static let startCall: UInt16 = 78        // → internalCallerParams
        public static let hangup: UInt16 = 167
        public static let callsToken: UInt16 = 158      // → OK Calls auth token
        public static let incomingCallPush: UInt16 = 137
    }

    public static let defaultMediaSettings: [String: JSONValue] = [
        "isAudioEnabled": .bool(true),
        "isVideoEnabled": .bool(false),
        "isScreenSharingEnabled": .bool(false),
        "isFastScreenSharingEnabled": .bool(false),
        "isAudioSharingEnabled": .bool(false),
        "isAnimojiEnabled": .bool(false),
    ]

    public static func mediaSettings(audio: Bool, video: Bool) -> JSONValue {
        var m = defaultMediaSettings
        m["isAudioEnabled"] = .bool(audio)
        m["isVideoEnabled"] = .bool(video)
        return .object(m)
    }
}

public struct CallIceServer: Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// Everything needed to open the signaling socket of one conversation.
public struct CallConnectParams: Equatable, Sendable {
    public var endpoint: String
    public var token: String
    public var iceServers: [CallIceServer]
    public var clientType: String?
    public var isConcurrent: Bool

    public init(endpoint: String, token: String, iceServers: [CallIceServer], clientType: String? = nil, isConcurrent: Bool = false) {
        self.endpoint = endpoint
        self.token = token
        self.iceServers = iceServers
        self.clientType = clientType
        self.isConcurrent = isConcurrent
    }
}

public enum CallParamsError: Error, LocalizedError, Equatable {
    case malformed(String)
    public var errorDescription: String? {
        if case .malformed(let m) = self { return "Некорректные параметры звонка: \(m)" }
        return nil
    }
}

public enum CallParamsCodec {
    /// Mirrors the SDK: dedupe/trim URLs; TURN gets an extra `?transport=tcp` variant of its last URL.
    public static func iceServers(stun: JSONValue?, turn: JSONValue?) -> [CallIceServer] {
        func normalize(_ v: JSONValue?) -> CallIceServer? {
            guard let v else { return nil }
            var urls: [String] = []
            for u in v["urls"]?.arrayValue ?? [] {
                guard let s = u.stringValue?.trimmingCharacters(in: .whitespaces), !s.isEmpty, !urls.contains(s) else { continue }
                urls.append(s)
            }
            guard !urls.isEmpty else { return nil }
            return CallIceServer(urls: urls, username: v["username"]?.stringValue, credential: v["credential"]?.stringValue)
        }
        var out: [CallIceServer] = []
        if let s = normalize(stun) { out.append(s) }
        if var t = normalize(turn) {
            t.urls.append("\(t.urls[t.urls.count - 1])?transport=tcp")
            out.append(t)
        }
        return out
    }

    /// Outgoing call: the `internalCallerParams` JSON string returned by Max opcode 78.
    public static func parseInternalCallerParams(_ json: String) throws -> CallConnectParams {
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)),
              let endpoint = obj["endpoint"]?.stringValue, !endpoint.isEmpty
        else { throw CallParamsError.malformed("нет endpoint") }
        let token = URLComponents(string: endpoint)?.queryItems?.first(where: { $0.name == "token" })?.value ?? ""
        let ice = iceServers(stun: obj["stun"], turn: obj["turn"])
        guard !ice.isEmpty else { throw CallParamsError.malformed("нет STUN/TURN") }
        return CallConnectParams(
            endpoint: endpoint,
            token: token,
            iceServers: ice,
            clientType: obj["clientType"]?.stringValue,
            isConcurrent: obj["isConcurrent"]?.boolValue ?? false
        )
    }

    /// Incoming call: the `vcp` field of Max push 137 — "<originalLength>:<base64 LZ4 block>"
    /// holding `{srcp, stne, tkn, trne, trnp, trnu, wse, wte}`.
    public static func decodeVCP(_ vcp: String) throws -> CallConnectParams {
        let parts = vcp.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let length = Int(parts[0]), length > 0,
              let packed = Data(base64Encoded: parts[1], options: .ignoreUnknownCharacters)
        else { throw CallParamsError.malformed("формат vcp") }
        let raw = try LZ4Block.decompress(packed, maxSize: max(length, 1024)).prefix(length)
        guard let obj = try? JSONDecoder().decode(JSONValue.self, from: Data(raw)),
              let endpoint = obj["wse"]?.stringValue, let token = obj["tkn"]?.stringValue
        else { throw CallParamsError.malformed("содержимое vcp") }
        func split(_ key: String) -> [JSONValue] {
            (obj[key]?.stringValue ?? "").split(separator: ",").map { .string(String($0)) }
        }
        var turn: [String: JSONValue] = ["urls": .array(split("trne"))]
        if let u = obj["trnu"]?.stringValue { turn["username"] = .string(u) }
        if let p = obj["trnp"]?.stringValue { turn["credential"] = .string(p) }
        let ice = iceServers(stun: .object(["urls": .array(split("stne"))]), turn: .object(turn))
        return CallConnectParams(endpoint: endpoint, token: token, iceServers: ice, clientType: obj["srcp"]?.stringValue)
    }

    /// `internalParams` the client hands to Max opcode 78 (the server forwards it to the calls platform).
    public static func internalParams(deviceId: String) -> String {
        let obj: JSONValue = .object([
            "deviceId": .string(deviceId),
            "sdkVersion": .string(OKCalls.webSdkVersion),
            "clientAppKey": .string(OKCalls.webAppKey),
            "platform": .string("WEB"),
            "protocolVersion": .int(Int64(OKCalls.protocolVersion)),
            "capabilities": .string(OKCalls.capabilities),
        ])
        return String(decoding: (try? JSONEncoder().encode(obj)) ?? Data("{}".utf8), as: UTF8.self)
    }

    public enum ConnectionType: String, Sendable {
        case start, accept, join, retry
    }

    /// Final signaling WebSocket URL: the SDK's `_buildSignalingEndpoint` (incoming only) + `_buildUrl`.
    public static func signalingURL(
        endpoint: String,
        connectionType: ConnectionType,
        appVersion: String,
        clientType: String?,
        incoming: (userId: Int64?, conversationId: String, token: String)? = nil
    ) throws -> URL {
        guard var comps = URLComponents(string: endpoint) else { throw CallParamsError.malformed("endpoint") }
        var items = comps.queryItems ?? []
        func set(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }
        if let incoming {
            if let uid = incoming.userId { set("userId", String(uid)) }
            set("entityType", "USER")
            set("deviceIdx", "0")
            set("conversationId", incoming.conversationId)
            set("token", incoming.token)
        }
        set("platform", "WEB")
        set("appVersion", appVersion)
        set("version", String(OKCalls.protocolVersion))
        set("device", "browser")
        set("capabilities", OKCalls.capabilities)
        set("clientType", clientType ?? "PORTAL")
        set("tgt", connectionType.rawValue)
        comps.queryItems = items
        // URLComponents leaves "+" unescaped in queries; the token is base64-ish, so be strict.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { throw CallParamsError.malformed("endpoint") }
        return url
    }

    /// Reply of `auth.anonymLogin`: `{uid, session_key, external_user_id, ...}` or `{error_code, error_msg}`.
    public static func parseAnonymLogin(_ resp: JSONValue) throws -> (uid: Int64, externalUserId: String?) {
        if let msg = resp["error_msg"]?.stringValue { throw CallParamsError.malformed("anonymLogin: \(msg)") }
        guard let uid = resp["uid"]?.int64Value ?? resp["uid"]?.stringValue.flatMap({ Int64($0) }) else {
            throw CallParamsError.malformed("anonymLogin без uid")
        }
        let ext = resp["external_user_id"]?.stringValue ?? resp["external_user_id"]?.int64Value.map(String.init)
        return (uid, ext)
    }

    /// The OK user id embedded in an endpoint URL (outgoing endpoints carry `userId`).
    public static func userId(inEndpoint endpoint: String) -> Int64? {
        URLComponents(string: endpoint)?.queryItems?.first(where: { $0.name == "userId" })?.value.flatMap { Int64($0) }
    }
}

/// A participant reference as the signaling protocol spells it.
public struct CallParticipantRef: Hashable, Sendable {
    public var id: Int64
    public var type: String
    public var deviceIdx: Int

    public init(id: Int64, type: String = "USER", deviceIdx: Int = 0) {
        self.id = id
        self.type = type
        self.deviceIdx = deviceIdx
    }

    /// From a conversation participant object (`{id, idType, deviceIdx, ...}`).
    public init?(participant v: JSONValue) {
        guard let id = v["id"]?.int64Value ?? v["id"]?.stringValue.flatMap({ Int64($0) }) else { return nil }
        self.init(id: id, type: v["idType"]?.stringValue ?? "USER", deviceIdx: Int(v["deviceIdx"]?.int64Value ?? 0))
    }

    /// From a notification (`{participantId, participantType, deviceIdx}` or nested `participant`).
    public init?(message v: JSONValue) {
        if let p = v["participant"], let ref = CallParticipantRef(participant: p) { self = ref; return }
        guard let id = v["participantId"]?.int64Value ?? v["participantId"]?.stringValue.flatMap({ Int64($0) }) else { return nil }
        self.init(id: id, type: v["participantType"]?.stringValue ?? "USER", deviceIdx: Int(v["deviceIdx"]?.int64Value ?? 0))
    }

    /// Fields to merge into a command addressed to this participant.
    public var commandFields: [String: JSONValue] {
        var f: [String: JSONValue] = ["participantId": .int(id), "participantType": .string(type)]
        if deviceIdx != 0 { f["deviceIdx"] = .int(Int64(deviceIdx)) }
        return f
    }
}
