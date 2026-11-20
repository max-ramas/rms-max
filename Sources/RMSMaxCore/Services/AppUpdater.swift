import Foundation
import CryptoKit
#if os(macOS)
import AppKit
#endif

/// minisign signature check (the format rms-release signs `release.json` with).
/// Algorithms: `ED` = Ed25519 over BLAKE2b-512(message) (prehashed, used by rms-release), `Ed` = legacy raw.
public enum Minisign {
    public static func verify(message: Data, signatureFile: String, publicKey: String) -> (valid: Bool, trustedComment: String?) {
        guard let pk = decodePublicKey(publicKey) else { return (false, nil) }
        let lines = signatureFile.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard lines.count >= 4,
              let sigBlob = Data(base64Encoded: lines[1]), sigBlob.count == 74,
              lines[2].hasPrefix("trusted comment: "),
              let globalSig = Data(base64Encoded: lines[3]), globalSig.count == 64
        else { return (false, nil) }
        let alg = sigBlob.prefix(2)
        let keyId = sigBlob.subdata(in: 2..<10)
        let signature = sigBlob.subdata(in: 10..<74)
        guard keyId == pk.keyId, let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pk.key) else { return (false, nil) }
        let signed: Data
        switch alg {
        case Data("ED".utf8): signed = BLAKE2b.hash(message, outLength: 64)
        case Data("Ed".utf8): signed = message
        default: return (false, nil)
        }
        guard key.isValidSignature(signature, for: signed) else { return (false, nil) }
        let comment = String(lines[2].dropFirst("trusted comment: ".count))
        guard key.isValidSignature(globalSig, for: signature + Data(comment.utf8)) else { return (false, nil) }
        return (true, comment)
    }

    /// Accepts the base64 line or the whole `.pub` file.
    static func decodePublicKey(_ text: String) -> (keyId: Data, key: Data)? {
        let line = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.hasPrefix("untrusted comment") } ?? ""
        guard let blob = Data(base64Encoded: line), blob.count == 42, blob.prefix(2) == Data("Ed".utf8) else { return nil }
        return (blob.subdata(in: 2..<10), blob.subdata(in: 10..<42))
    }
}

/// Plain numeric semver compare (a pre-release sorts before its release).
public enum VersionCompare {
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.numbers.count, b.numbers.count) {
            let x = i < a.numbers.count ? a.numbers[i] : 0
            let y = i < b.numbers.count ? b.numbers[i] : 0
            if x != y { return x > y }
        }
        return a.pre.isEmpty && !b.pre.isEmpty
    }

    private static func parse(_ v: String) -> (numbers: [Int], pre: String) {
        let parts = v.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        return (parts[0].split(separator: ".").map { Int($0) ?? 0 }, parts.count > 1 ? String(parts[1]) : "")
    }
}

public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let file: String
    public let url: URL
    public let size: Int64
    public let sha256: String
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case server(String)
    case badSignature
    case checksumMismatch
    case notInstallable(String)
    case install(String)

    public var errorDescription: String? {
        switch self {
        case .server(let m): return "Сервер обновлений недоступен: \(m)"
        case .badSignature: return "Обновление не прошло проверку подписи и не будет установлено"
        case .checksumMismatch: return "Скачанный файл повреждён (контрольная сумма не совпала)"
        case .notInstallable(let m): return m
        case .install(let m): return "Не удалось установить обновление: \(m)"
        }
    }
}

/// Updates from update.rms-ds.com (product `rms-maks`). The check sends nothing about the user:
/// a plain GET of the public catalog. Everything installed is verified twice — the release manifest
/// by its minisign signature (production key release-key, pinned here) and the file by the SHA-256 in
/// that signed manifest; on macOS the new app must also carry the same Developer ID as this one.
public enum AppUpdater {
    public static let product = "rms-maks"
    public static let server = URL(string: "https://update.rms-ds.com")!
    /// minisign public key `A6F888ED44FA43F3` (kid release-key).
    public static let releasePublicKey = "RWTzQ/pE7Yj4phFhGzE5d1fPXTUULnZzQYpeULlnjPSr/g0qrGFVrl3m"

    public static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    static var target: (platform: String, arch: String, format: String) {
        #if os(macOS)
        return ("darwin", "universal", "dmg")
        #else
        return ("ios", "arm64", "ipa")
        #endif
    }

    /// nil when this is the newest version.
    public static func check(currentVersion: String = AppUpdater.currentVersion,
                             session: URLSession = .shared) async throws -> AvailableUpdate? {
        var comps = URLComponents(url: server.appendingPathComponent("v1/\(product)/latest"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "channel", value: "stable"), .init(name: "platform", value: target.platform),
            .init(name: "arch", value: target.arch), .init(name: "format", value: target.format),
        ]
        let latest = try await getJSON(comps.url!, session: session)
        guard let version = latest["version"]?.stringValue,
              let releaseURL = latest["release_url"]?.stringValue.flatMap(URL.init(string:)),
              let releaseSHA = latest["release_sha256"]?.stringValue
        else { throw UpdateError.server("неполный ответ") }
        guard VersionCompare.isNewer(version, than: currentVersion) else { return nil }

        let manifestData = try await get(releaseURL, session: session)
        let sigData = try await get(releaseURL.appendingPathExtension("minisig"), session: session)
        return try verifiedUpdate(manifest: manifestData, signature: String(decoding: sigData, as: UTF8.self),
                                  expectedSHA256: releaseSHA, expectedVersion: version)
    }

    /// Pure verification step (unit-tested with a real signed release).
    static func verifiedUpdate(manifest: Data, signature: String, expectedSHA256: String, expectedVersion: String) throws -> AvailableUpdate {
        guard hex(SHA256.hash(data: manifest)) == expectedSHA256.lowercased() else { throw UpdateError.badSignature }
        let check = Minisign.verify(message: manifest, signatureFile: signature, publicKey: releasePublicKey)
        guard check.valid else { throw UpdateError.badSignature }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: manifest),
              json["product"]?.stringValue == product, json["version"]?.stringValue == expectedVersion,
              check.trustedComment?.contains("product:\(product)") == true,
              check.trustedComment?.contains("version:\(expectedVersion)") == true
        else { throw UpdateError.badSignature }
        let t = target
        guard let art = (json["artifacts"]?.arrayValue ?? []).first(where: {
            $0["platform"]?.stringValue == t.platform && $0["arch"]?.stringValue == t.arch && $0["format"]?.stringValue == t.format
        }), let file = art["file"]?.stringValue, let sha = art["sha256"]?.stringValue, sha.count == 64
        else { throw UpdateError.server("в выпуске нет файла для этого устройства") }
        let url = server.appendingPathComponent("dl/\(product)/\(expectedVersion)/\(file)")
        return AvailableUpdate(version: expectedVersion, notes: json["notes"]?.stringValue ?? "", file: file, url: url,
                               size: art["size"]?.int64Value ?? 0, sha256: sha.lowercased())
    }

    /// Public download page for platforms that cannot self-install (iOS → SideStore).
    public static var downloadPage: URL { server.appendingPathComponent("get/\(product)/\(target.format)") }

    #if os(macOS)
    /// Downloads, verifies and installs the update, then quits; a detached script swaps the bundle
    /// after exit and rolls back if the new version does not keep running.
    public static func install(_ update: AvailableUpdate, session: URLSession = .shared) async throws {
        let running = Bundle.main.bundleURL
        let parent = running.deletingLastPathComponent()
        guard running.pathExtension == "app", FileManager.default.isWritableFile(atPath: parent.path),
              !running.path.contains("/AppTranslocation/"), !running.path.hasPrefix("/Volumes/")
        else {
            throw UpdateError.notInstallable("Переместите RMS MAKS в папку «Программы» и запустите оттуда — тогда обновление установится само.")
        }
        let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RMSMaks/Updates/\(update.version)", isDirectory: true)
        let staged = try await stage(update, into: work, expectedBundleID: Bundle.main.bundleIdentifier ?? "", runningApp: running, session: session)

        // 4. Swap after quit.
        let script = work.appendingPathComponent("swap.sh")
        try swapScript.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let backup = work.appendingPathComponent("previous/\(running.lastPathComponent)")
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        let log = work.appendingPathComponent("install.log")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh \"$0\" \"$@\" >> \"$RMS_LOG\" 2>&1 &", script.path,
                             String(ProcessInfo.processInfo.processIdentifier), running.path, staged.path, backup.path]
        process.environment = ProcessInfo.processInfo.environment.merging(["RMS_LOG": log.path]) { _, n in n }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.install("не запустился установщик") }
        await MainActor.run { NSApp.terminate(nil) }
    }

    /// Download → SHA-256 → unpack from DMG → same bundle id, version and Developer ID requirement
    /// as `runningApp`. Returns the verified bundle; changes nothing installed.
    static func stage(_ update: AvailableUpdate, into work: URL, expectedBundleID: String, runningApp: URL,
                      session: URLSession = .shared) async throws -> URL {
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        // 1. Download and check the signed checksum.
        let (tmp, response) = try await session.download(from: update.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.server("загрузка не удалась") }
        let dmg = work.appendingPathComponent(update.file)
        try FileManager.default.moveItem(at: tmp, to: dmg)
        let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
        guard hex(SHA256.hash(data: data)) == update.sha256 else { throw UpdateError.checksumMismatch }

        // 2. Unpack the app from the DMG.
        let mount = work.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]).status == 0 else {
            throw UpdateError.install("не открылся DMG")
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let appName = try FileManager.default.contentsOfDirectory(atPath: mount.path).first(where: { $0.hasSuffix(".app") }) else {
            throw UpdateError.install("в DMG нет приложения")
        }
        let staged = work.appendingPathComponent(appName)
        guard run("/usr/bin/ditto", [mount.appendingPathComponent(appName).path, staged.path]).status == 0 else {
            throw UpdateError.install("не удалось распаковать")
        }

        // 3. Same app, newer version, same Developer ID.
        let info = Bundle(url: staged)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == expectedBundleID else { throw UpdateError.install("чужое приложение") }
        guard info?["CFBundleShortVersionString"] as? String == update.version else { throw UpdateError.install("версия не совпадает") }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]).status == 0 else { throw UpdateError.badSignature }
        guard let a = designatedRequirement(staged), let b = designatedRequirement(runningApp), a == b else {
            throw UpdateError.install("подпись нового приложения отличается от установленного")
        }

        return staged
    }

    static func designatedRequirement(_ app: URL) -> String? {
        let r = run("/usr/bin/codesign", ["-d", "-r-", app.path])
        guard r.status == 0 else { return nil }
        return (r.out + "\n" + r.err).split(separator: "\n")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            .first { $0.hasPrefix("designated =>") }
    }

    /// Args: pid, target, staged, backup. Keeps the old bundle and restores it if the new one dies.
    static let swapScript = """
    #!/bin/sh
    PID="$1"; TARGET="$2"; STAGED="$3"; BACKUP="$4"
    echo "$(date '+%F %T') swap start pid=$PID target=$TARGET"
    i=0
    while kill -0 "$PID" 2>/dev/null && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done
    if kill -0 "$PID" 2>/dev/null; then echo "app still running, aborting"; exit 1; fi
    rm -rf "$BACKUP"
    mv "$TARGET" "$BACKUP" || { echo "cannot move old bundle"; exit 1; }
    if ditto "$STAGED" "$TARGET"; then
      xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
      open "$TARGET"
      sleep 6
      if pgrep -f "$TARGET/Contents/MacOS/" >/dev/null 2>&1; then echo "update installed"; exit 0; fi
      echo "new version did not stay running, rolling back"
    else
      echo "copy failed, rolling back"
    fi
    rm -rf "$TARGET"
    mv "$BACKUP" "$TARGET" && open "$TARGET"
    echo "rolled back"
    exit 2
    """

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return (-1, "", "\(error)") }
        let od = o.fileHandleForReading.readDataToEndOfFile(), ed = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: od, as: UTF8.self), String(decoding: ed, as: UTF8.self))
    }
    #endif

    // MARK: - helpers

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("RMS MAKS updater", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await session.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.server("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        return data
    }

    private static func getJSON(_ url: URL, session: URLSession) async throws -> JSONValue {
        let data = try await get(url, session: session)
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw UpdateError.server("непонятный ответ") }
        return v
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
