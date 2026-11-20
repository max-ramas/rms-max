import XCTest
@testable import RMSMaxCore

final class NWHTTPSClientTests: XCTestCase {
    func testChunkedDecoding() {
        let raw = Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)
        XCTAssertEqual(NWHTTPSClient.decodeChunked(raw).map { String(decoding: $0, as: UTF8.self) }, "Wikipedia")
        XCTAssertNil(NWHTTPSClient.decodeChunked(Data("4\r\nWi".utf8)), "incomplete chunk must wait for more data")
    }

    func testHeadParsing() throws {
        let (code, h) = try NWHTTPSClient.parseHead("HTTP/1.1 400 Bad Request\r\nContent-Length: 151\r\nServer: Apache")
        XCTAssertEqual(code, 400)
        XCTAssertEqual(h["content-length"], "151")
    }

    /// Live: the real media host answers a POST over our Network.framework client (needs the network).
    func testLiveAudioUploadEndpoint() async throws {
        guard ProcessInfo.processInfo.environment["RMS_NETWORK_TESTS"] == "1" else { throw XCTSkip("network") }
        let url = URL(string: "https://au2.oneme.ru/uploadAudio?probe=1")!
        let r = try await NWHTTPSClient.post(url: url, headers: ["Content-Type": "application/octet-stream",
                                                                 "Content-Disposition": "attachment; filename=voice.ogg"],
                                             body: Data(count: 9533))
        print("PROBE nw HTTP", r.status, r.body.count)
        XCTAssertEqual(r.status, 400, "garbage upload without a valid signature is refused by the server, over a working TLS session")
    }
}

extension NWHTTPSClientTests {
    func testLiveGetOverNetworkFramework() async throws {
        guard ProcessInfo.processInfo.environment["RMS_NETWORK_TESTS"] == "1" else { throw XCTSkip("network") }
        let r = try await NWHTTPSClient.get(url: URL(string: "https://au2.oneme.ru/")!)
        XCTAssertEqual(r.status, 404)
        XCTAssertGreaterThan(r.body.count, 0)
    }
}
