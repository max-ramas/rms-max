// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public enum LZ4Error: Error, LocalizedError {
    case truncatedInput
    case invalidMatchOffset
    case outputLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .truncatedInput: return "LZ4 block is truncated"
        case .invalidMatchOffset: return "Invalid LZ4 back-reference offset"
        case .outputLimitExceeded: return "LZ4 decompressed size exceeds allowed maximum"
        }
    }
}

public enum LZ4Block {
    public static func decompress(_ src: Data, maxSize: Int = 5 * 1024 * 1024) throws -> Data {
        let bytes = Array(src)
        var ip = 0
        var dst: [UInt8] = []
        dst.reserveCapacity(min(bytes.count * 2, maxSize))

        while ip < bytes.count {
            let token = bytes[ip]
            ip += 1

            var literalLength = Int(token >> 4)
            if literalLength == 15 {
                while true {
                    guard ip < bytes.count else { throw LZ4Error.truncatedInput }
                    let extra = bytes[ip]
                    ip += 1
                    literalLength += Int(extra)
                    if extra != 255 { break }
                }
            }

            if literalLength > 0 {
                guard ip + literalLength <= bytes.count else { throw LZ4Error.truncatedInput }
                guard dst.count + literalLength <= maxSize else { throw LZ4Error.outputLimitExceeded }
                dst.append(contentsOf: bytes[ip..<(ip + literalLength)])
                ip += literalLength
            }

            if ip >= bytes.count {
                break
            }

            guard ip + 2 <= bytes.count else { throw LZ4Error.truncatedInput }
            let offset = Int(bytes[ip]) | (Int(bytes[ip + 1]) << 8)
            ip += 2

            guard offset > 0, offset <= dst.count else {
                throw LZ4Error.invalidMatchOffset
            }

            var matchLength = Int(token & 0x0F)
            if matchLength == 15 {
                while true {
                    guard ip < bytes.count else { throw LZ4Error.truncatedInput }
                    let extra = bytes[ip]
                    ip += 1
                    matchLength += Int(extra)
                    if extra != 255 { break }
                }
            }
            matchLength += 4

            guard dst.count + matchLength <= maxSize else {
                throw LZ4Error.outputLimitExceeded
            }

            let matchStart = dst.count - offset
            for i in 0..<matchLength {
                dst.append(dst[matchStart + i])
            }
        }

        return Data(dst)
    }
}
