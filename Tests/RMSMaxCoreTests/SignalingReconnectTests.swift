// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import XCTest
import Network
@testable import RMSMaxCore

/// Tiny local WebSocket server standing in for the calls platform's signaling.
private final class FakeSignalingServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake.signaling")
    private var connections: [NWConnection] = []
    private(set) var requestedURLs: [String] = []
    var onConnect: ((FakeSignalingServer, NWConnection, Int) -> Void)?
    var onText: ((FakeSignalingServer, NWConnection, String) -> Void)?

    init() throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(DispatchQueue(label: "fake.ws.req")) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func start() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { if case .ready = $0 { cont.resume() } }
            listener.start(queue: queue)
        }
    }

    private func accept(_ c: NWConnection) {
        connections.append(c)
        let index = connections.count
        c.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state else { return }
            if let meta = c.metadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata {
                _ = meta
            }
            self.onConnect?(self, c, index)
            self.receive(c)
        }
        c.start(queue: queue)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let text = String(data: data, encoding: .utf8) { self.onText?(self, c, text) }
            self.receive(c)
        }
    }

    func send(_ c: NWConnection, _ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "t", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, isComplete: true, completion: .idempotent)
    }

    func drop(_ c: NWConnection) { c.cancel() }

    func stop() {
        connections.forEach { $0.cancel() }
        listener.cancel()
    }
}

final class SignalingReconnectTests: XCTestCase {
    func testReconnectsWithRetryAndReplaysMissedMessages() async throws {
        let server = try FakeSignalingServer()
        server.onConnect = { s, c, index in
            if index == 1 {
                s.send(c, #"{"type":"notification","notification":"connection","stamp":10,"peerId":{"id":55},"conversation":{"id":"c1","topology":"DIRECT","participants":[]}}"#)
                s.send(c, #"{"type":"notification","notification":"media-settings-changed","stamp":11,"participantId":7,"mediaSettings":{"isVideoEnabled":true}}"#)
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { s.drop(c) }
            } else {
                s.send(c, #"{"type":"notification","notification":"connection","stamp":12,"peerId":{"id":55},"conversation":{"id":"c1","topology":"SERVER","participants":[]},"recoverMessages":[{"type":"notification","notification":"hungup","stamp":12,"participantId":7,"reason":"HUNGUP"}]}"#)
            }
        }
        // Echo responses for commands so `send` resolves.
        server.onText = { s, c, text in
            guard text != "pong",
                  let obj = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let seq = obj["sequence"] as? Int else { return }
            s.send(c, #"{"type":"response","sequence":\#(seq)}"#)
        }
        await server.start()
        defer { server.stop() }

        let signaling = OKCallSignaling()
        let url = URL(string: "ws://127.0.0.1:\(server.port)/ws?token=t&tgt=start")!
        let connection = try await signaling.connect(url: url)
        XCTAssertEqual(connection["conversation"]?["id"], .string("c1"))

        var seen: [String] = []
        var reconnectedTopology: String?
        for await event in signaling.events {
            switch event {
            case .notification(let name, _): seen.append(name)
            case .reconnecting: seen.append("<reconnecting>")
            case .reconnected(let msg):
                seen.append("<reconnected>")
                reconnectedTopology = msg["conversation"]?["topology"]?.stringValue
            case .closed: seen.append("<closed>")
            }
            if seen.contains("hungup") { break }
        }
        XCTAssertEqual(seen, ["media-settings-changed", "<reconnecting>", "<reconnected>", "hungup"])
        XCTAssertEqual(reconnectedTopology, "SERVER")

        // After reconnecting, commands work again.
        let resp = try await signaling.send("change-media-settings", ["mediaSettings": OKCalls.mediaSettings(audio: true, video: false)])
        XCTAssertEqual(resp["type"], .string("response"))
        await signaling.close()
    }
}
