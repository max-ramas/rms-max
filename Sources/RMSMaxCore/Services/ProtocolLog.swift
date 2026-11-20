// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

/// Local diagnostics: protocol errors and connection events only — opcode, server error code and
/// message, never message contents, phone numbers or tokens. Kept on this device (last 300 lines);
/// the user can copy it from Settings to report a problem.
public enum ProtocolLog {
    private static let queue = DispatchQueue(label: "rms.maks.protocol-log")
    private static var lines: [String] = load()

    private static var file: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RMSMaks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("protocol.log")
    }

    private static func load() -> [String] {
        (try? String(contentsOf: file, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }

    public static func add(_ line: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        queue.async {
            lines.append("\(stamp) \(line)")
            if lines.count > 300 { lines.removeFirst(lines.count - 300) }
            try? lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        }
    }

    public static var text: String {
        let header = "RMS MAKS \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))"
        return queue.sync { ([header] + lines).joined(separator: "\n") }
    }

    public static func clear() {
        queue.sync { lines.removeAll(); try? FileManager.default.removeItem(at: file) }
    }
}
