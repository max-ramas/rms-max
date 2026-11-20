// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation
import CryptoKit

public struct ApkBuildFingerprint: Codable, Sendable, Equatable {
    public let signatureScheme: String
    public let certificateCount: Int
    public let certificateMetaSha256: String
    public let certificateSha256: [String]
    public let dexMetaSha256: String
    public let soMetaSha256: [String: String]
    public let buildNumber: Int

    public static let embeddedVersions: [String: ApkBuildFingerprint] = [
        "26.31.0": ApkBuildFingerprint(
            signatureScheme: "v3",
            certificateCount: 1,
            certificateMetaSha256: "1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93",
            certificateSha256: ["1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93"],
            dexMetaSha256: "9affa687874d88ea80b298949f826bcf8c1bba36f24d48c44b8f54cdbf01c96f",
            soMetaSha256: [
                "arm64-v8a": "38e2e5de3d4a9010ea1053eb28573593683c5b2bb16b09914a8822476c8aab8c",
                "armeabi-v7a": "f60cb2576885e0af5350c98fe88355a2f26008a372c998c193b6222f717e274f",
                "x86": "80bd04964e7d0492740113047ff20ebdf88ba6e6eb48d8765cbd5fe678283065",
                "x86_64": "96173e7c2d9449c1ab4474265b410f37ce45f560b0974460a75c7c6000ca22fd",
            ],
            buildNumber: 6822
        ),
        "26.30.1": ApkBuildFingerprint(
            signatureScheme: "v3",
            certificateCount: 1,
            certificateMetaSha256: "1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93",
            certificateSha256: ["1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93"],
            dexMetaSha256: "f0478d38a9d9172a7bf055f7a3bbf5a878ea9e4df8196a1c9e788ad3c35e95b7",
            soMetaSha256: [
                "arm64-v8a": "9a7d6c3f2d3d01ca5e8692f254be92306d37fadb074692479bdf961943675f7a",
                "armeabi-v7a": "bfc5ac5df34357fa817c4a8ce4696cd95b2c34f903d91ef15ea86463c600befa",
                "x86": "918eacab4fa4e04d90a7fa666bc39633ae47fbba70b6817b5dfd1f62233fab8e",
                "x86_64": "ae38786d2c0541c4d2c3050265e30bde68df16302aebc5302432813ff20f858c",
            ],
            buildNumber: 6819
        ),
        "26.30.0": ApkBuildFingerprint(
            signatureScheme: "v3",
            certificateCount: 1,
            certificateMetaSha256: "1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93",
            certificateSha256: ["1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93"],
            dexMetaSha256: "d13689c99becd8d94d5b9a57418b792928915064e6192731763a96625157ec01",
            soMetaSha256: [
                "arm64-v8a": "9a7d6c3f2d3d01ca5e8692f254be92306d37fadb074692479bdf961943675f7a",
            ],
            buildNumber: 6810
        ),
        "26.11.1": ApkBuildFingerprint(
            signatureScheme: "v3",
            certificateCount: 1,
            certificateMetaSha256: "1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93",
            certificateSha256: ["1684414033eb263e2c615f8b7df5ed8793850a07656304997fbf07e9e21e1e93"],
            dexMetaSha256: "17e5ebaa23b199c6b8efae0d8d95e162d7c682d9e80f68959af36a7e3fc1bd35",
            soMetaSha256: [
                "arm64-v8a": "f6d815f5a30e99c08186bb3faef1386bfc2843c475b6d85c31fbe737d3b76a5b",
            ],
            buildNumber: 6665
        ),
    ]

    public static func resolve(version: String) -> ApkBuildFingerprint? {
        embeddedVersions[version] ?? embeddedVersions["26.31.0"]
    }
}

public enum FingerprintGenerator {
    public static func generate(
        versionData: ApkBuildFingerprint,
        deviceId: String,
        callsSeed: Int64,
        arch: String = "arm64-v8a"
    ) -> Data? {
        guard
            let soHashHex = versionData.soMetaSha256[arch] ?? versionData.soMetaSha256["arm64-v8a"],
            let certMetaBytes = Data(hexString: versionData.certificateMetaSha256),
            let dexMetaBytes = Data(hexString: versionData.dexMetaSha256),
            let soMetaBytes = Data(hexString: soHashHex)
        else {
            return nil
        }

        var seedBE = callsSeed.bigEndian
        let seedBytes = Data(bytes: &seedBE, count: MemoryLayout<Int64>.size)
        let deviceBytes = Data(deviceId.utf8)

        func sha256Block(_ prefix: Data) -> Data {
            var hasher = SHA256()
            hasher.update(data: prefix)
            hasher.update(data: seedBytes)
            hasher.update(data: deviceBytes)
            return Data(hasher.finalize())
        }

        var out = Data(capacity: 96)
        out.append(sha256Block(certMetaBytes))
        out.append(sha256Block(dexMetaBytes))
        out.append(sha256Block(soMetaBytes))
        return out
    }
}
