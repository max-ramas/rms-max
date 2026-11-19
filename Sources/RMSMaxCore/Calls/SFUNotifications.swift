import Foundation

/// A stream description as the SFU spells it: `u123[:d1][:sCAMERA][:mName]`.
public struct SFUStreamDescription: Equatable, Sendable {
    public var participant: CallParticipantRef
    public var mediaType: String?

    public init?(_ text: String) {
        var parts = text.split(separator: ":").map(String.init)
        guard !parts.isEmpty else { return nil }
        let head = parts.removeFirst()
        guard let kind = head.first, kind == "u" || kind == "g", let id = Int64(head.dropFirst()) else { return nil }
        var device = 0
        var media: String?
        for p in parts {
            switch p.first {
            case "s": media = String(p.dropFirst())
            case "d": device = Int(p.dropFirst()) ?? 0
            case "m": break
            default: return nil
            }
        }
        participant = CallParticipantRef(id: id, type: kind == "g" ? "GROUP" : "USER", deviceIdx: device)
        mediaType = media
    }

    /// Key used in `update-display-layout` (SDK `La`): composite id plus `:s<MEDIA>`.
    public static func layoutKey(_ p: CallParticipantRef, mediaType: String = "CAMERA") -> String {
        let base = (p.type == "GROUP" ? "g" : "u") + String(p.id) + (p.deviceIdx != 0 ? ":d\(p.deviceIdx)" : "")
        return base + ":s" + mediaType
    }
}

/// Decoder for the SFU's binary `producerNotification` data channel (SDK ParticipantIdRegistry):
/// first byte = type, rest = MsgPack. Type 1 announces compact ids, 7 binds pooled video
/// tracks (`pat-N`) to participants, 2/3 report who is talking.
public final class SFUNotificationDecoder: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        /// `streamId` (as in the SDP, e.g. "pat-0") now carries this participant's media (nil = freed).
        case trackBound(streamId: String, participant: CallParticipantRef?, mediaType: String?)
        case speaker(CallParticipantRef?)
        case active([CallParticipantRef])
        /// Type 5: the SFU caps our upload (maxBitrate in bits/s, maxDimension px; media 0 = camera).
        case videoQuality(maxBitrate: Int, maxDimension: Int, screen: Bool)
    }

    private var byCompactId: [Int64: SFUStreamDescription] = [:]
    private let lock = NSLock()

    public init() {}

    public func decode(_ frame: Data) -> [Event] {
        guard let type = frame.first, let body = try? MsgPack.decode(Data(frame.dropFirst())) else { return [] }
        lock.lock(); defer { lock.unlock() }
        switch type {
        case 1:
            for (text, compact) in body.objectValue ?? [:] {
                if let id = compact.int64Value, let d = SFUStreamDescription(text) { byCompactId[id] = d }
            }
            return []
        case 2:
            return [.active((body.arrayValue ?? []).compactMap { $0.int64Value.flatMap { byCompactId[$0]?.participant } })]
        case 3:
            return [.speaker(body.int64Value.flatMap { byCompactId[$0]?.participant })]
        case 5:
            guard let arr = body.arrayValue, arr.count >= 2 else { return [] }
            return [.videoQuality(
                maxBitrate: Int(arr[0].int64Value ?? 0),
                maxDimension: Int(arr[1].int64Value ?? 0),
                screen: arr.count > 2 && arr[2].int64Value == 1
            )]
        case 7:
            var out: [Event] = []
            for (slot, info) in body.objectValue ?? [:] {
                let compact = info[0]?.int64Value
                let d = compact.flatMap { byCompactId[$0] }
                out.append(.trackBound(streamId: "pat-\(slot)", participant: d?.participant, mediaType: d?.mediaType))
            }
            return out.sorted { "\($0)" < "\($1)" }
        default:
            return []
        }
    }
}

public extension OKCalls {
    /// `allocate-consumer` capabilities (SDK ConsumerCapabilities.get) for what we implement:
    /// mixed audio, unified plan, one session, on-demand video tracks; no simulcast/screen/animoji.
    static func consumerCapabilities(videoTracks: Int = 9) -> JSONValue {
        .object([
            "estimatedPerformanceIndex": .int(2),
            "audioMix": .bool(true),
            "consumerUpdate": .bool(true),
            "producerNotificationDataChannelVersion": .int(8),
            "producerCommandDataChannelVersion": .int(3),
            "consumerScreenDataChannelVersion": .int(1),
            "producerScreenDataChannelVersion": .int(1),
            "asrDataChannelVersion": .int(0),
            "animojiDataChannelVersion": .int(1),
            "animojiBackendRender": .bool(true),
            "onDemandTracks": .bool(true),
            "unifiedPlan": .bool(true),
            "singleSession": .bool(true),
            "videoTracksCount": .int(Int64(videoTracks)),
            "red": .bool(true),
            "audioShare": .bool(false),
            "fastScreenShare": .bool(false),
            "videoSuspend": .bool(false),
            "simulcast": .bool(false),
            "simulcastNativeOrder": .bool(true),
            "consumerFastScreenShare": .bool(false),
            "consumerFastScreenShareQualityOnDemand": .bool(false),
            "transparentAudio": .bool(false),
        ])
    }
}
