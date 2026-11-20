import XCTest
import CryptoKit
@testable import RMSMaxCore

/// Uses the real published RMS MAKS 1.1.1 manifest and its production minisign signature.
final class UpdaterTests: XCTestCase {
    static let manifest = Data(base64Encoded: "ewogICJzY2hlbWEiOiAxLAogICJwcm9kdWN0IjogInJtcy1tYWtzIiwKICAidmVyc2lvbiI6ICIxLjEuMSIsCiAgInB1Ymxpc2hlZF9hdCI6ICIyMDI2LTExLTIwVDAwOjM2OjM2WiIsCiAgInNlcXVlbmNlIjogMjAyNjExMjAwMDM2MzYsCiAgImNoYW5uZWxzIjogWwogICAgInN0YWJsZSIKICBdLAogICJub3RlcyI6ICIjIyAxLjEuMVxuXG4jIyMg0JjQt9C80LXQvdC10L3QvlxuLSBtYWNPUzog0L/RgNC40LvQvtC20LXQvdC40LUg0LggRE1HINC90L7RgtCw0YDQuNC30L7QstCw0L3RiyBBcHBsZSDigJQg0L7RgtC60YDRi9Cy0LDRjtGC0YHRjyDQvtCx0YvRh9C90YvQvCDQtNCy0L7QudC90YvQvCDRidC10LvRh9C60L7QvCwg0LHQtdC3IMKr0L/RgNCw0LLRi9C5INC60LvQuNC6IOKGkiDQntGC0LrRgNGL0YLRjMK7LlxuXG7QpNGD0L3QutGG0LjQvtC90LDQu9GM0L3QvtGB0YLRjCDRgtCwINC20LUsINGH0YLQviDQsiAxLjEuMCAo0LfQstC+0L3QutC4LCDRgdGC0LjQutC10YDRiywg0L7Qv9GA0L7RgdGLLCDQv9Cw0L/QutC4LCDQsdC+0YLRiywg0LjRgdGC0L7RgNC40Lgg0Lgg0LTRgC4pLiDQn9GA0Lgg0L7QsdC90L7QstC70LXQvdC40Lgg0YEgUk1TIE1BWCDQvtC00LjQvSDRgNCw0Lcg0LLQvtC50LTQuNGC0LUg0LIg0LDQutC60LDRg9C90YIg0LfQsNC90L7QstC+LlxuIiwKICAiYXJ0aWZhY3RzIjogWwogICAgewogICAgICAicGxhdGZvcm0iOiAiZGFyd2luIiwKICAgICAgImFyY2giOiAidW5pdmVyc2FsIiwKICAgICAgImZvcm1hdCI6ICJkbWciLAogICAgICAiZmlsZSI6ICJSTVNNYWtzLTEuMS4xLmRtZyIsCiAgICAgICJzaXplIjogMTk5NTU1NzcsCiAgICAgICJzaGEyNTYiOiAiZjQ4OWQzNWIwNzk1NjQ3YjUyNTc5NTc5NGJkNmQwZTY5OTc5MGE4NzNhZDlkYzc0MmM0ZTJiMDA3MWFiMWUxMiIKICAgIH0sCiAgICB7CiAgICAgICJwbGF0Zm9ybSI6ICJpb3MiLAogICAgICAiYXJjaCI6ICJhcm02NCIsCiAgICAgICJmb3JtYXQiOiAiaXBhIiwKICAgICAgImZpbGUiOiAiUk1TTWFrcy0xLjEuMS5pcGEiLAogICAgICAic2l6ZSI6IDg5MjUzMjUsCiAgICAgICJzaGEyNTYiOiAiNzM2OTJjZmY0OTNhNzYxODIyODRhOTY1Y2JhYjZiZTU3NzQwYjQ2NDdkMWUxMWVjOGZiMzI0NWIzM2NhNzhkMSIKICAgIH0KICBdCn0K")!
    static let signature = """
untrusted comment: signature from rms-release
RUTzQ/pE7Yj4pvmwA3wqthjpylI6LT1Pa/7pcTrB6xqNB5TpYe66DDf9eswgOwRRevYVUDTHdOCYrKYjGh82//MbkcU2MQ0GTg8=
trusted comment: product:rms-maks version:1.1.1 sequence:20261120003636
OFxeV2PGG9v3A7p7EMjum1sXTQSOMgH2xTh7+I8WyrubRP3P5lIOmbKaWbWQkz++eHfhQBrA7M3Bg/t9vIySDA==
"""
    static let sha = "31d193ef94a0ed112db1433fa845af84698e549a95bde97df9e6b56a521dedd9"

    func testRealReleaseVerifies() throws {
        let u = try AppUpdater.verifiedUpdate(manifest: Self.manifest, signature: Self.signature, expectedSHA256: Self.sha, expectedVersion: "1.1.1")
        XCTAssertEqual(u.version, "1.1.1")
        XCTAssertEqual(u.file, "RMSMaks-1.1.1.dmg")
        XCTAssertEqual(u.sha256, "f489d35b0795647b525795794bd6d0e699790a873ad9dc742c4e2b0071ab1e12")
        XCTAssertEqual(u.url.absoluteString, "https://update.rms-ds.com/dl/rms-maks/1.1.1/RMSMaks-1.1.1.dmg")
        XCTAssertTrue(u.notes.contains("нотаризованы"))
    }

    func testTamperedManifestRejected() {
        var bad = Self.manifest
        bad[bad.count / 2] ^= 0x01
        let badSHA = SHA256.hash(data: bad).map { String(format: "%02x", $0) }.joined()
        XCTAssertThrowsError(try AppUpdater.verifiedUpdate(manifest: bad, signature: Self.signature, expectedSHA256: badSHA, expectedVersion: "1.1.1")) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertThrowsError(try AppUpdater.verifiedUpdate(manifest: Self.manifest, signature: Self.signature, expectedSHA256: String(repeating: "0", count: 64), expectedVersion: "1.1.1"))
        XCTAssertThrowsError(try AppUpdater.verifiedUpdate(manifest: Self.manifest, signature: Self.signature, expectedSHA256: Self.sha, expectedVersion: "9.9.9"))
    }

    func testForeignKeySignatureRejected() {
        // Valid minisign structure, but signed by another key → key id mismatch.
        let other = Self.signature.replacingOccurrences(of: "RUTzQ/pE7Yj4p", with: "RUTzQ/pE7Yj4q")
        XCTAssertFalse(Minisign.verify(message: Self.manifest, signatureFile: other, publicKey: AppUpdater.releasePublicKey).valid)
        XCTAssertTrue(Minisign.verify(message: Self.manifest, signatureFile: Self.signature, publicKey: AppUpdater.releasePublicKey).valid)
    }

    func testVersionCompare() {
        XCTAssertTrue(VersionCompare.isNewer("1.2.0", than: "1.1.1"))
        XCTAssertTrue(VersionCompare.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(VersionCompare.isNewer("1.1.1", than: "1.1.1"))
        XCTAssertFalse(VersionCompare.isNewer("1.1.0", than: "1.1.1"))
        XCTAssertTrue(VersionCompare.isNewer("1.2.0", than: "1.2.0-beta"))
    }
}

#if os(macOS)
/// Downloads the real published DMG; run with RMS_NETWORK_TESTS=1 (skipped otherwise).
final class UpdaterNetworkTests: XCTestCase {
    private func realUpdate() async throws -> AvailableUpdate {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RMS_NETWORK_TESTS"] == "1", "network test")
        let found = try await AppUpdater.check(currentVersion: "1.0.0")
        return try XCTUnwrap(found)
    }

    func testCheckAndStageRealRelease() async throws {
        let u = try await realUpdate()
        XCTAssertTrue(VersionCompare.isNewer(u.version, than: "1.1.0"))
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rmsmaks-update-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        // The downloaded app must carry the same Developer ID requirement as an app we signed ourselves.
        let ours = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/dd-mac/Build/Products/Release/RMS MAKS.app")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ours.path), "local Developer ID build missing")
        let staged = try await AppUpdater.stage(u, into: work, expectedBundleID: "dev.rms.maks.macos", runningApp: ours)
        XCTAssertEqual(Bundle(url: staged)?.infoDictionary?["CFBundleShortVersionString"] as? String, u.version)
    }

    func testStageRejectsOtherSignerAndBadChecksum() async throws {
        let u = try await realUpdate()
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("rmsmaks-update-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            _ = try await AppUpdater.stage(u, into: work, expectedBundleID: "dev.rms.maks.macos",
                                           runningApp: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
            XCTFail("must refuse a different signer")
        } catch let e as UpdateError {
            XCTAssertEqual(e, .install("подпись нового приложения отличается от установленного"))
        }
        let bad = AvailableUpdate(version: u.version, notes: "", file: u.file, url: u.url, size: u.size, sha256: String(repeating: "a", count: 64))
        do {
            _ = try await AppUpdater.stage(bad, into: work, expectedBundleID: "dev.rms.maks.macos",
                                           runningApp: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
            XCTFail("must refuse a wrong checksum")
        } catch let e as UpdateError {
            XCTAssertEqual(e, .checksumMismatch)
        }
    }
}
#endif
