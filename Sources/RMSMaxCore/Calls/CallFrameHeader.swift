// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public enum CallMediaKind: String, Sendable {
    case audio
    case video
}

public enum CallFrameHeader {
    private static func findH264UnencryptedPrefix(_ raw: [UInt8]) -> Int? {
        var i = 0
        let count = raw.count
        var sawAnnexB = false

        while i + 3 < count {
            let startCodeLen: Int
            if raw[i] == 0x00 && raw[i + 1] == 0x00 {
                if raw[i + 2] == 0x01 {
                    startCodeLen = 3
                } else if i + 4 < count && raw[i + 2] == 0x00 && raw[i + 3] == 0x01 {
                    startCodeLen = 4
                } else {
                    i += 1
                    continue
                }
            } else {
                i += 1
                continue
            }

            sawAnnexB = true
            let nalHeaderIdx = i + startCodeLen
            guard nalHeaderIdx < count else { break }
            let nalType = raw[nalHeaderIdx] & 0x1F
            // Keep Annex-B start codes, SPS/PPS/SEI, and first VCL slice header (type 1 or 5) + 1 byte in clear.
            if nalType == 1 || nalType == 5 {
                let prefix = nalHeaderIdx + 2
                if prefix < count {
                    return prefix
                }
            }
            i = nalHeaderIdx + 1
        }

        return sawAnnexB ? min(10, count) : nil
    }

    /// Computes how many leading codec header bytes must remain unencrypted for SFU/WebKit routing.
    public static func unencryptedBytes(raw: Data, kind: CallMediaKind) -> Int {
        guard !raw.isEmpty else { return 0 }
        let bytes = Array(raw)
        if kind == .audio {
            return 1 // Preserve Opus TOC byte 0
        }
        if let h264Prefix = findH264UnencryptedPrefix(bytes) {
            return h264Prefix
        }
        let isKeyframe = (bytes[0] & 0x01) == 0 // VP8 frame_type == 0
        return isKeyframe ? 10 : 3
    }
}
