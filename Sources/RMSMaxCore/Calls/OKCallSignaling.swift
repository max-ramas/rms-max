// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 Maksim Ramzaev. Part of RMS MAKS; see LICENSE.

import Foundation

public enum CallSignalingError: Error, LocalizedError {
    case notConnected
    case timeout(String)
    case remote(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Нет соединения с сервером звонков"
        case .timeout(let c): return "Сервер звонков не ответил (\(c))"
        case .remote(let m): return "Сервер звонков: \(m)"
        case .closed: return "Соединение звонка закрыто"
        }
    }
}

/// WebSocket signaling of the OK Calls platform (the protocol the official Max clients speak).
/// Text frames: JSON commands `{command, sequence, ...}` answered by `{type:"response"|"error", sequence}`,
/// server `{type:"notification", notification, ...}` events, and bare "ping"/"pong" keep-alives.
/// Like the SDK's SignalingSession it survives network drops: it reconnects with `tgt=retry`,
/// `recoverTs` (last `stamp` seen) and our `peerId`, and the server replays what we missed.
public actor OKCallSignaling {
    public enum Event: Sendable {
        case notification(String, JSONValue)
        case reconnecting
        case reconnected(JSONValue)
        case closed(String?)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var baseURL: URL?
    private var sequence = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var connectionWaiter: CheckedContinuation<JSONValue, Error>?
    private var receiveLoop: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var isClosed = false
    private var established = false
    private var reconnecting = false
    private var lastStamp: Int64 = 0
    private var peerId: Int64?
    private var lastFrameAt = Date()
    private var activityTimeout: TimeInterval = 40
    private let log: @Sendable (String) -> Void

    /// Total time we keep trying to get the socket back before giving up on the call.
    public var reconnectWindow: TimeInterval = 60

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        var c: AsyncStream<Event>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        self.continuation = c
        self.log = log
    }

    /// Opens the socket and returns the server's `connection` notification (conversation snapshot).
    public func connect(url: URL, timeout: TimeInterval = 15) async throws -> JSONValue {
        baseURL = url
        let msg = try await open(url: url, timeout: timeout)
        startWatchdog()
        return msg
    }

    private func open(url: URL, timeout: TimeInterval) async throws -> JSONValue {
        teardownSocket()
        let s = URLSession(configuration: .ephemeral, delegate: MaxURLSessionDelegate.shared, delegateQueue: nil)
        let t = s.webSocketTask(with: url)
        t.maximumMessageSize = 8 * 1024 * 1024
        session = s
        task = t
        t.resume()
        log("signaling: connecting \(url.host ?? "?")")
        startReceiving(t)
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.failConnection(CallSignalingError.timeout("connection"))
        }
        defer { timer.cancel() }
        let msg = try await withCheckedThrowingContinuation { connectionWaiter = $0 }
        established = true
        lastFrameAt = Date()
        if let id = msg["peerId"]?["id"]?.int64Value { peerId = id }
        if let t = msg["conversationParams"]?["activityTimeout"]?.doubleValue, t > 0 {
            activityTimeout = max(20, min(t / 1000 / 2, 90))
        }
        return msg
    }

    /// Sends a command; when `needResponse` is false resolves as soon as the frame is written.
    @discardableResult
    public func send(_ command: String, _ params: [String: JSONValue] = [:], needResponse: Bool = true, timeout: TimeInterval = 10) async throws -> JSONValue {
        guard let task, !isClosed, !reconnecting else { throw CallSignalingError.notConnected }
        let seq = sequence
        sequence += 1
        var body = params
        body["command"] = .string(command)
        body["sequence"] = .int(Int64(seq))
        let text = String(decoding: try JSONEncoder().encode(JSONValue.object(body)), as: UTF8.self)
        log("signaling → \(command) #\(seq)")
        if !needResponse {
            try await task.send(.string(text))
            return .object(["type": .string("response"), "sequence": .int(Int64(seq))])
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[seq] = cont
            Task {
                do { try await task.send(.string(text)) } catch { self.resolve(seq, .failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.resolve(seq, .failure(CallSignalingError.timeout(command)))
            }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.cancel()
        teardownSocket()
        failAll(CallSignalingError.closed)
        continuation.yield(.closed(nil))
        continuation.finish()
    }

    /// Network path changed (Wi-Fi ⇄ cellular): drop the old socket now instead of waiting
    /// for the activity timeout, and reconnect over the new path.
    public func forceReconnect(reason: String = "смена сети") {
        guard established, !reconnecting, !isClosed else { return }
        socketLost(reason)
    }

    // MARK: - Reconnect (SDK SignalingSession._retry)

    /// URL for a retry attempt: same endpoint, `tgt=retry`, `recoverTs`, `peerId`.
    static func retryURL(from url: URL, lastStamp: Int64, peerId: Int64?) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        func set(_ k: String, _ v: String) {
            items.removeAll { $0.name == k }
            items.append(URLQueryItem(name: k, value: v))
        }
        set("tgt", "retry")
        if lastStamp > 0 { set("recoverTs", String(lastStamp)) }
        if let peerId { set("peerId", String(peerId)) }
        comps.queryItems = items
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return comps.url ?? url
    }

    private func socketLost(_ reason: String) {
        guard !isClosed else { return }
        guard established, let baseURL else {
            finishWithError(reason)
            return
        }
        guard !reconnecting else { return }
        reconnecting = true
        established = false
        log("signaling: lost (\(reason)) — reconnecting")
        failAll(CallSignalingError.notConnected)
        continuation.yield(.reconnecting)
        let deadline = Date().addingTimeInterval(reconnectWindow)
        Task { [weak self] in
            var attempt = 0
            while let self, Date() < deadline {
                if await self.isClosed { return }
                let url = await Self.retryURL(from: baseURL, lastStamp: self.lastStamp, peerId: self.peerId)
                do {
                    let msg = try await self.open(url: url, timeout: 10)
                    await self.didReconnect(msg)
                    return
                } catch {
                    attempt += 1
                    let delay = min(8.0, 0.5 * pow(2.0, Double(attempt)))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
            await self?.finishWithError("не удалось восстановить соединение")
        }
    }

    private func didReconnect(_ msg: JSONValue) {
        reconnecting = false
        log("signaling: reconnected")
        continuation.yield(.reconnected(msg))
        for m in msg["recoverMessages"]?.arrayValue ?? [] {
            if let s = m["stamp"]?.int64Value { lastStamp = max(lastStamp, s) }
            continuation.yield(.notification(m["notification"]?.stringValue ?? "", m))
        }
    }

    private func finishWithError(_ reason: String) {
        guard !isClosed else { return }
        isClosed = true
        watchdog?.cancel()
        teardownSocket()
        failAll(CallSignalingError.closed)
        continuation.yield(.closed(reason))
        continuation.finish()
    }

    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self?.checkActivity()
            }
        }
    }

    /// The server pings regularly; silence longer than the activity window means a dead socket.
    private func checkActivity() {
        guard established, !reconnecting, !isClosed else { return }
        if Date().timeIntervalSince(lastFrameAt) > activityTimeout {
            socketLost("нет активности \(Int(activityTimeout)) с")
        }
    }

    // MARK: - Internals

    private func teardownSocket() {
        receiveLoop?.cancel()
        receiveLoop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func resolve(_ seq: Int, _ result: Result<JSONValue, Error>) {
        guard let cont = pending.removeValue(forKey: seq) else { return }
        cont.resume(with: result)
    }

    private func failConnection(_ error: Error) {
        guard let w = connectionWaiter else { return }
        connectionWaiter = nil
        w.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        failConnection(error)
        let all = pending
        pending.removeAll()
        all.values.forEach { $0.resume(throwing: error) }
    }

    private func startReceiving(_ t: URLSessionWebSocketTask) {
        receiveLoop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await t.receive()
                    let text: String
                    switch message {
                    case .string(let s): text = s
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    await self?.handle(text, from: t)
                } catch {
                    await self?.socketDied(t, error)
                    break
                }
            }
        }
    }

    private func socketDied(_ t: URLSessionWebSocketTask, _ error: Error) {
        guard t === task else { return } // an older socket we already replaced
        if connectionWaiter != nil {
            failConnection(error)
            return
        }
        socketLost(error.localizedDescription)
    }

    private func handle(_ text: String, from t: URLSessionWebSocketTask) async {
        guard t === task else { return }
        lastFrameAt = Date()
        if text == "ping" {
            try? await task?.send(.string("pong"))
            return
        }
        if text == "pong" { return }
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
            log("signaling: unparsable frame")
            return
        }
        if let stamp = msg["stamp"]?.int64Value { lastStamp = max(lastStamp, stamp) }
        let seq = msg["sequence"]?.int64Value.map(Int.init)
        switch msg["type"]?.stringValue {
        case "response":
            if let seq { resolve(seq, .success(msg)) }
        case "error":
            let reason = msg["error"]?.stringValue ?? msg["message"]?.stringValue ?? "error"
            log("signaling ← error \(reason)")
            if let seq, pending[seq] != nil {
                resolve(seq, .failure(CallSignalingError.remote(reason)))
            } else if connectionWaiter != nil {
                failConnection(CallSignalingError.remote(reason))
            } else {
                continuation.yield(.notification("error", msg))
            }
        case "notification":
            let name = msg["notification"]?.stringValue ?? ""
            log("signaling ← \(name)")
            if name == "connection", let w = connectionWaiter {
                connectionWaiter = nil
                w.resume(returning: msg)
                if !reconnecting {
                    for m in msg["recoverMessages"]?.arrayValue ?? [] {
                        continuation.yield(.notification(m["notification"]?.stringValue ?? "", m))
                    }
                }
                return
            }
            continuation.yield(.notification(name, msg))
        default:
            log("signaling: unknown frame type")
        }
    }
}
