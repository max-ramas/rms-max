import Foundation

public enum MsgPackError: Error, LocalizedError {
    case unexpectedEndOfInput
    case invalidTag(UInt8)
    case invalidUTF8
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .unexpectedEndOfInput: return "Unexpected end of MessagePack input"
        case .invalidTag(let tag): return String(format: "Unsupported MessagePack tag 0x%02x", tag)
        case .invalidUTF8: return "Invalid UTF-8 string in MessagePack payload"
        case .unsupportedType(let msg): return msg
        }
    }
}

public enum MsgPack {
    private static let binaryArrayKeys: Set<String> = [
        "mode",
        "chatCacheFingerprint",
        "chatsCountGroups",
        "wave",
        "previewData",
    ]

    // MARK: - Encode

    public static func encode(_ value: JSONValue) throws -> Data {
        var out = Data()
        try encodeValue(value, into: &out, parentKey: nil)
        return out
    }

    private static func encodeValue(_ value: JSONValue, into out: inout Data, parentKey: String?) throws {
        switch value {
        case .null:
            out.append(0xc0)
        case .bool(let b):
            out.append(b ? 0xc3 : 0xc2)
        case .int(let i):
            encodeInt(i, into: &out)
        case .double(let d):
            out.append(0xcb)
            var bits = d.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        case .string(let s):
            if let key = parentKey, key == "wave" || key == "previewData" {
                encodeBinary(Data(s.utf8), into: &out)
            } else {
                encodeString(s, into: &out)
            }
        case .binary(let data):
            encodeBinary(data, into: &out)
        case .array(let arr):
            if let key = parentKey, binaryArrayKeys.contains(key) {
                let bytes = arr.compactMap { el -> UInt8? in
                    guard let v = el.int64Value else { return nil }
                    return UInt8(truncatingIfNeeded: v)
                }
                encodeBinary(Data(bytes), into: &out)
                return
            }
            encodeArrayHeader(arr.count, into: &out)
            for item in arr {
                try encodeValue(item, into: &out, parentKey: nil)
            }
        case .object(let map):
            encodeMapHeader(map.count, into: &out)
            for (k, v) in map {
                encodeString(k, into: &out)
                try encodeValue(v, into: &out, parentKey: k)
            }
        }
    }

    public static func encodeInt(_ value: Int64, into out: inout Data) {
        if value >= 0 {
            let u = UInt64(value)
            if u <= 0x7f {
                out.append(UInt8(u))
            } else if u <= UInt64(UInt8.max) {
                out.append(0xcc)
                out.append(UInt8(u))
            } else if u <= UInt64(UInt16.max) {
                out.append(0xcd)
                appendBE(UInt16(u), into: &out)
            } else if u <= UInt64(UInt32.max) {
                out.append(0xce)
                appendBE(UInt32(u), into: &out)
            } else {
                out.append(0xcf)
                appendBE(u, into: &out)
            }
        } else {
            if value >= -32 {
                out.append(UInt8(bitPattern: Int8(value)))
            } else if value >= Int64(Int8.min) {
                out.append(0xd0)
                out.append(UInt8(bitPattern: Int8(value)))
            } else if value >= Int64(Int16.min) {
                out.append(0xd1)
                appendBE(Int16(value), into: &out)
            } else if value >= Int64(Int32.min) {
                out.append(0xd2)
                appendBE(Int32(value), into: &out)
            } else {
                out.append(0xd3)
                appendBE(value, into: &out)
            }
        }
    }

    public static func encodeString(_ string: String, into out: inout Data) {
        let utf8 = Data(string.utf8)
        let len = utf8.count
        if len <= 31 {
            out.append(0xa0 | UInt8(len))
        } else if len <= Int(UInt8.max) {
            out.append(0xd9)
            out.append(UInt8(len))
        } else if len <= Int(UInt16.max) {
            out.append(0xda)
            appendBE(UInt16(len), into: &out)
        } else {
            out.append(0xdb)
            appendBE(UInt32(len), into: &out)
        }
        out.append(utf8)
    }

    public static func encodeBinary(_ data: Data, into out: inout Data) {
        let len = data.count
        if len <= Int(UInt8.max) {
            out.append(0xc4)
            out.append(UInt8(len))
        } else if len <= Int(UInt16.max) {
            out.append(0xc5)
            appendBE(UInt16(len), into: &out)
        } else {
            out.append(0xc6)
            appendBE(UInt32(len), into: &out)
        }
        out.append(data)
    }

    public static func encodeArrayHeader(_ count: Int, into out: inout Data) {
        if count <= 15 {
            out.append(0x90 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            out.append(0xdc)
            appendBE(UInt16(count), into: &out)
        } else {
            out.append(0xdd)
            appendBE(UInt32(count), into: &out)
        }
    }

    public static func encodeMapHeader(_ count: Int, into out: inout Data) {
        if count <= 15 {
            out.append(0x80 | UInt8(count))
        } else if count <= Int(UInt16.max) {
            out.append(0xde)
            appendBE(UInt16(count), into: &out)
        } else {
            out.append(0xdf)
            appendBE(UInt32(count), into: &out)
        }
    }

    private static func appendBE<T: FixedWidthInteger>(_ v: T, into out: inout Data) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { out.append(contentsOf: $0) }
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> JSONValue {
        var offset = data.startIndex
        return try decodeValue(from: data, offset: &offset)
    }

    private static func readByte(_ data: Data, offset: inout Data.Index) throws -> UInt8 {
        guard offset < data.endIndex else { throw MsgPackError.unexpectedEndOfInput }
        let b = data[offset]
        offset = data.index(after: offset)
        return b
    }

    private static func readSlice(_ data: Data, count: Int, offset: inout Data.Index) throws -> Data {
        guard count >= 0, let end = data.index(offset, offsetBy: count, limitedBy: data.endIndex) else {
            throw MsgPackError.unexpectedEndOfInput
        }
        let sub = data[offset..<end]
        offset = end
        return Data(sub)
    }

    private static func readInt<T: FixedWidthInteger>(_ data: Data, as type: T.Type, offset: inout Data.Index) throws -> T {
        let slice = try readSlice(data, count: MemoryLayout<T>.size, offset: &offset)
        var raw: T = 0
        _ = withUnsafeMutableBytes(of: &raw) { slice.copyBytes(to: $0) }
        return T(bigEndian: raw)
    }

    private static func decodeValue(from data: Data, offset: inout Data.Index) throws -> JSONValue {
        let tag = try readByte(data, offset: &offset)

        switch tag {
        case 0x00...0x7f:
            return .int(Int64(tag))
        case 0xe0...0xff:
            return .int(Int64(Int8(bitPattern: tag)))
        case 0x80...0x8f:
            return try decodeMap(count: Int(tag & 0x0f), from: data, offset: &offset)
        case 0x90...0x9f:
            return try decodeArray(count: Int(tag & 0x0f), from: data, offset: &offset)
        case 0xa0...0xbf:
            return try decodeString(count: Int(tag & 0x1f), from: data, offset: &offset)
        case 0xc0:
            return .null
        case 0xc2:
            return .bool(false)
        case 0xc3:
            return .bool(true)
        case 0xc4:
            let len = Int(try readByte(data, offset: &offset))
            return try .string(decodeBinaryLossy(count: len, from: data, offset: &offset))
        case 0xc5:
            let len = Int(try readInt(data, as: UInt16.self, offset: &offset))
            return try .string(decodeBinaryLossy(count: len, from: data, offset: &offset))
        case 0xc6:
            let len = Int(try readInt(data, as: UInt32.self, offset: &offset))
            return try .string(decodeBinaryLossy(count: len, from: data, offset: &offset))
        case 0xc7:
            let len = Int(try readByte(data, offset: &offset))
            _ = try readByte(data, offset: &offset)
            _ = try readSlice(data, count: len, offset: &offset)
            return .null
        case 0xc8:
            let len = Int(try readInt(data, as: UInt16.self, offset: &offset))
            _ = try readByte(data, offset: &offset)
            _ = try readSlice(data, count: len, offset: &offset)
            return .null
        case 0xc9:
            let len = Int(try readInt(data, as: UInt32.self, offset: &offset))
            _ = try readByte(data, offset: &offset)
            _ = try readSlice(data, count: len, offset: &offset)
            return .null
        case 0xca:
            let bits = try readInt(data, as: UInt32.self, offset: &offset)
            return .double(Double(Float(bitPattern: bits)))
        case 0xcb:
            let bits = try readInt(data, as: UInt64.self, offset: &offset)
            return .double(Double(bitPattern: bits))
        case 0xcc:
            return .int(Int64(try readByte(data, offset: &offset)))
        case 0xcd:
            return .int(Int64(try readInt(data, as: UInt16.self, offset: &offset)))
        case 0xce:
            return .int(Int64(try readInt(data, as: UInt32.self, offset: &offset)))
        case 0xcf:
            let u = try readInt(data, as: UInt64.self, offset: &offset)
            if u <= UInt64(Int64.max) {
                return .int(Int64(u))
            }
            return .string(String(u))
        case 0xd0:
            return .int(Int64(Int8(bitPattern: try readByte(data, offset: &offset))))
        case 0xd1:
            return .int(Int64(try readInt(data, as: Int16.self, offset: &offset)))
        case 0xd2:
            return .int(Int64(try readInt(data, as: Int32.self, offset: &offset)))
        case 0xd3:
            return .int(try readInt(data, as: Int64.self, offset: &offset))
        case 0xd4:
            _ = try readSlice(data, count: 2, offset: &offset)
            return .null
        case 0xd5:
            _ = try readSlice(data, count: 3, offset: &offset)
            return .null
        case 0xd6:
            _ = try readSlice(data, count: 5, offset: &offset)
            return .null
        case 0xd7:
            _ = try readSlice(data, count: 9, offset: &offset)
            return .null
        case 0xd8:
            _ = try readSlice(data, count: 17, offset: &offset)
            return .null
        case 0xd9:
            let len = Int(try readByte(data, offset: &offset))
            return try decodeString(count: len, from: data, offset: &offset)
        case 0xda:
            let len = Int(try readInt(data, as: UInt16.self, offset: &offset))
            return try decodeString(count: len, from: data, offset: &offset)
        case 0xdb:
            let len = Int(try readInt(data, as: UInt32.self, offset: &offset))
            return try decodeString(count: len, from: data, offset: &offset)
        case 0xdc:
            let count = Int(try readInt(data, as: UInt16.self, offset: &offset))
            return try decodeArray(count: count, from: data, offset: &offset)
        case 0xdd:
            let count = Int(try readInt(data, as: UInt32.self, offset: &offset))
            return try decodeArray(count: count, from: data, offset: &offset)
        case 0xde:
            let count = Int(try readInt(data, as: UInt16.self, offset: &offset))
            return try decodeMap(count: count, from: data, offset: &offset)
        case 0xdf:
            let count = Int(try readInt(data, as: UInt32.self, offset: &offset))
            return try decodeMap(count: count, from: data, offset: &offset)
        default:
            throw MsgPackError.invalidTag(tag)
        }
    }

    private static func decodeString(count: Int, from data: Data, offset: inout Data.Index) throws -> JSONValue {
        let bytes = try readSlice(data, count: count, offset: &offset)
        return .string(String(decoding: bytes, as: UTF8.self))
    }

    private static func decodeBinaryLossy(count: Int, from data: Data, offset: inout Data.Index) throws -> String {
        let bytes = try readSlice(data, count: count, offset: &offset)
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func decodeArray(count: Int, from data: Data, offset: inout Data.Index) throws -> JSONValue {
        var result: [JSONValue] = []
        result.reserveCapacity(min(count, 4096))
        for _ in 0..<count {
            result.append(try decodeValue(from: data, offset: &offset))
        }
        return .array(result)
    }

    private static func decodeMap(count: Int, from data: Data, offset: inout Data.Index) throws -> JSONValue {
        var result: [String: JSONValue] = [:]
        result.reserveCapacity(min(count, 1024))
        for _ in 0..<count {
            let keyVal = try decodeValue(from: data, offset: &offset)
            let key = keyVal.stringValue ?? "unknown"
            let val = try decodeValue(from: data, offset: &offset)
            result[key] = val
        }
        return .object(result)
    }
}
