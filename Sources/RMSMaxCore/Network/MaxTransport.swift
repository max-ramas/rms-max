import Foundation
import Network
import Security

public enum MaxTransportError: Error, LocalizedError {
    case connectionFailed(String)
    case connectionClosed(String)
    case sendFailed(String)
    case invalidPayload(String)
    case requestTimeout
    case notConnected
    case apiError(JSONValue)
    /// The server rejected this opcode earlier (`proto.opcode`): not sent again, because MAX drops the connection on it.
    case unsupportedOpcode(UInt16)

    public var errorDescription: String? {
        switch self {
        case .unsupportedOpcode: return "Эта функция недоступна в мобильном протоколе MAX"
        case .connectionFailed(let msg): return "Ошибка подключения: \(msg)"
        case .connectionClosed(let msg): return "Соединение закрыто: \(msg)"
        case .sendFailed(let msg): return "Ошибка отправки: \(msg)"
        case .invalidPayload(let msg): return "Ошибка формата ответа: \(msg)"
        case .requestTimeout: return "Превышено время ожидания ответа от сервера"
        case .notConnected: return "Нет подключения к серверу"
        case .apiError(let val):
            if let msg = val["localizedMessage"]?.stringValue ?? val["message"]?.stringValue {
                return msg
            }
            if let code = val["error"]?.stringValue {
                return code
            }
            return "Ошибка API"
        }
    }
}

public protocol MaxTransport: Sendable {
    func send(_ request: MaxRequest) async throws
    func receiveMessages() -> AsyncThrowingStream<MaxResponse, Error>
    func close() async
}

// MARK: - Mintsyfry Russian Trusted Root CA

public enum MaxTrustEvaluator {
    private static let rootCAPEM = """
    -----BEGIN CERTIFICATE-----
    MIIFwjCCA6qgAwIBAgICEAAwDQYJKoZIhvcNAQELBQAwcDELMAkGA1UEBhMCUlUx
    PzA9BgNVBAoMNlRoZSBNaW5pc3RyeSBvZiBEaWdpdGFsIERldmVsb3BtZW50IGFu
    ZCBDb21tdW5pY2F0aW9uczEgMB4GA1UEAwwXUnVzc2lhbiBUcnVzdGVkIFJvb3Qg
    Q0EwHhcNMjIwMzAxMjEwNDE1WhcNMzIwMjI3MjEwNDE1WjBwMQswCQYDVQQGEwJS
    VTE/MD0GA1UECgw2VGhlIE1pbmlzdHJ5IG9mIERpZ2l0YWwgRGV2ZWxvcG1lbnQg
    YW5kIENvbW11bmljYXRpb25zMSAwHgYDVQQDDBdSdXNzaWFuIFRydXN0ZWQgUm9v
    dCBDQTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMfFOZ8pUAL3+r2n
    qqE0Zp52selXsKGFYoG0GM5bwz1bSFtCt+AZQMhkWQheI3poZAToYJu69pHLKS6Q
    XBiwBC1cvzYmUYKMYZC7jE5YhEU2bSL0mX7NaMxMDmH2/NwuOVRj8OImVa5s1F4U
    zn4Kv3PFlDBjjSjXKVY9kmjUBsXQrIHeaqmUIsPIlNWUnimXS0I0abExqkbdrXbX
    YwCOXhOO2pDUx3ckmJlCMUGacUTnylyQW2VsJIyIGA8V0xzdaeUXg0VZ6ZmNUr5Y
    Ber/EAOLPb8NYpsAhJe2mXjMB/J9HNsoFMBFJ0lLOT/+dQvjbdRZoOT8eqJpWnVD
    U+QL/qEZnz57N88OWM3rabJkRNdU/Z7x5SFIM9FrqtN8xewsiBWBI0K6XFuOBOTD
    4V08o4TzJ8+Ccq5XlCUW2L48pZNCYuBDfBh7FxkB7qDgGDiaftEkZZfApRg2E+M9
    G8wkNKTPLDc4wH0FDTijhgxR3Y4PiS1HL2Zhw7bD3CbslmEGgfnnZojNkJtcLeBH
    BLa52/dSwNU4WWLubaYSiAmA9IUMX1/RpfpxOxd4Ykmhz97oFbUaDJFipIggx5sX
    ePAlkTdWnv+RWBxlJwMQ25oEHmRguNYf4Zr/Rxr9cS93Y+mdXIZaBEE0KS2iLRqa
    OiWBki9IMQU4phqPOBAaG7A+eP8PAgMBAAGjZjBkMB0GA1UdDgQWBBTh0YHlzlpf
    BKrS6badZrHF+qwshzAfBgNVHSMEGDAWgBTh0YHlzlpfBKrS6badZrHF+qwshzAS
    BgNVHRMBAf8ECDAGAQH/AgEEMA4GA1UdDwEB/wQEAwIBhjANBgkqhkiG9w0BAQsF
    AAOCAgEAALIY1wkilt/urfEVM5vKzr6utOeDWCUczmWX/RX4ljpRdgF+5fAIS4vH
    tmXkqpSCOVeWUrJV9QvZn6L227ZwuE15cWi8DCDal3Ue90WgAJJZMfTshN4OI8cq
    W9E4EG9wglbEtMnObHlms8F3CHmrw3k6KmUkWGoa+/ENmcVl68u/cMRl1JbW2bM+
    /3A+SAg2c6iPDlehczKx2oa95QW0SkPPWGuNA/CE8CpyANIhu9XFrj3RQ3EqeRcS
    AQQod1RNuHpfETLU/A2gMmvn/w/sx7TB3W5BPs6rprOA37tutPq9u6FTZOcG1Oqj
    C/B7yTqgI7rbyvox7DEXoX7rIiEqyNNUguTk/u3SZ4VXE2kmxdmSh3TQvybfbnXV
    4JbCZVaqiZraqc7oZMnRoWrXRG3ztbnbes/9qhRGI7PqXqeKJBztxRTEVj8ONs1d
    WN5szTwaPIvhkhO3CO5ErU2rVdUr89wKpNXbBODFKRtgxUT70YpmJ46VVaqdAhOZ
    D9EUUn4YaeLaS8AjSF/h7UkjOibNc4qVDiPP+rkehFWM66PVnP1Msh93tc+taIfC
    EYVMxjh8zNbFuoc7fzvvrFILLe7ifvEIUqSVIC/AzplM/Jxw7buXFeGP1qVCBEHq
    391d/9RAfaZ12zkwFsl+IKwE/OZxW8AHa9i1p4GO0YSNuczzEm4=
    -----END CERTIFICATE-----
    """

    public static let mintsyfryCertificate: SecCertificate? = {
        let b64 = rootCAPEM
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
            .joined()
        guard let der = Data(base64Encoded: b64) else { return nil }
        return SecCertificateCreateWithData(nil, der as CFData)
    }()

    static let maxDomains = ["oneme.ru", "max.ru", "okcdn.ru", "mycdn.me"]

    static func isMaxHost(_ host: String) -> Bool {
        let h = host.lowercased()
        return maxDomains.contains { h == $0 || h.hasSuffix("." + $0) }
    }

    public static func evaluateServerTrust(_ secTrust: SecTrust, host: String) -> Bool {
        let policy = SecPolicyCreateSSL(true, host as CFString)
        SecTrustSetPolicies(secTrust, policy)
        if SecTrustEvaluateWithError(secTrust, nil) {
            return true
        }
        // The Mintsyfry root is accepted only for Max's own hosts, never for arbitrary hosts.
        guard isMaxHost(host), let cert = mintsyfryCertificate else { return false }
        SecTrustSetAnchorCertificates(secTrust, [cert] as CFArray)
        SecTrustSetAnchorCertificatesOnly(secTrust, false)
        return SecTrustEvaluateWithError(secTrust, nil)
    }
}

public final class MaxURLSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    public static let shared = MaxURLSessionDelegate()

    public func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            if MaxTrustEvaluator.evaluateServerTrust(trust, host: challenge.protectionSpace.host) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Binary TCP/TLS Mobile Transport (api2.oneme.ru:443 + MsgPack + LZ4)

public final class MobileTLSTransport: MaxTransport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.rms.maks.mobile.tls", qos: .userInitiated)
    private let host: String

    private init(connection: NWConnection, host: String) {
        self.connection = connection
        self.host = host
    }

    public static func connect(
        host: String = MaxConstants.mobileHost,
        port: UInt16 = MaxConstants.mobilePort
    ) async throws -> MobileTLSTransport {
        let tlsOptions = NWProtocolTLS.Options()
        let secOpts = tlsOptions.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOpts, .TLSv12)
        sec_protocol_options_set_tls_server_name(secOpts, host)
        let evalQueue = DispatchQueue(label: "dev.rms.maks.tls.verify")
        sec_protocol_options_set_verify_block(secOpts, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let ok = MaxTrustEvaluator.evaluateServerTrust(secTrust, host: host)
            complete(ok)
        }, evalQueue)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.noDelay = true
        tcpOptions.enableKeepalive = true

        let params = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MaxTransportError.connectionFailed("Invalid port \(port)")
        }

        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
        let transport = MobileTLSTransport(connection: conn, host: host)

        final class OnceGate: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false

            func tryEnter() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return false }
                done = true
                return true
            }
        }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = OnceGate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.tryEnter() else { return }
                    conn.stateUpdateHandler = nil
                    cont.resume()
                case .failed(let err):
                    guard gate.tryEnter() else { return }
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: MaxTransportError.connectionFailed(err.localizedDescription))
                case .cancelled:
                    guard gate.tryEnter() else { return }
                    conn.stateUpdateHandler = nil
                    cont.resume(throwing: MaxTransportError.connectionClosed("Cancelled"))
                default:
                    break
                }
            }
            conn.start(queue: transport.queue)
        }

        return transport
    }

    public func send(_ request: MaxRequest) async throws {
        let payloadData: Data
        do {
            payloadData = try MsgPack.encode(request.payload)
        } catch {
            throw MaxTransportError.sendFailed(error.localizedDescription)
        }

        guard payloadData.count <= 0xFF_FFFF else {
            throw MaxTransportError.sendFailed("Payload too large")
        }

        var frame = Data(capacity: 10 + payloadData.count)
        frame.append(request.ver)
        frame.append(request.cmd)
        var seqBE = request.seq.bigEndian
        withUnsafeBytes(of: &seqBE) { frame.append(contentsOf: $0) }
        var opBE = request.opcode.bigEndian
        withUnsafeBytes(of: &opBE) { frame.append(contentsOf: $0) }
        var packedLenBE = (UInt32(payloadData.count) & 0x00FF_FFFF).bigEndian
        withUnsafeBytes(of: &packedLenBE) { frame.append(contentsOf: $0) }
        frame.append(payloadData)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { err in
                if let err {
                    cont.resume(throwing: MaxTransportError.sendFailed(err.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func receiveMessages() -> AsyncThrowingStream<MaxResponse, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let header = try await self.readExact(10)
                        let ver = header[0]
                        let cmd = header[1]
                        let seq = (UInt16(header[2]) << 8) | UInt16(header[3])
                        let opcode = (UInt16(header[4]) << 8) | UInt16(header[5])
                        let packedRaw =
                            (UInt32(header[6]) << 24)
                            | (UInt32(header[7]) << 16)
                            | (UInt32(header[8]) << 8)
                            | UInt32(header[9])
                        let compFlag = packedRaw >> 24
                        let payloadLen = Int(packedRaw & 0x00FF_FFFF)

                        if payloadLen == 0 {
                            continuation.yield(MaxResponse(ver: ver, cmd: cmd, seq: seq, opcode: opcode, payload: .null))
                            continue
                        }

                        let rawPayload = try await self.readExact(payloadLen)
                        let finalBytes: Data = compFlag != 0
                            ? try LZ4Block.decompress(rawPayload, maxSize: 8 * 1024 * 1024)
                            : rawPayload

                        if finalBytes.isEmpty {
                            continuation.yield(MaxResponse(ver: ver, cmd: cmd, seq: seq, opcode: opcode, payload: .null))
                            continue
                        }

                        let decoded = try MsgPack.decode(finalBytes)
                        continuation.yield(MaxResponse(ver: ver, cmd: cmd, seq: seq, opcode: opcode, payload: decoded))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func readExact(_ length: Int) async throws -> Data {
        var collected = Data()
        collected.reserveCapacity(length)
        while collected.count < length {
            let remaining = length - collected.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: MaxTransportError.connectionClosed(error.localizedDescription))
                        return
                    }
                    if let data, !data.isEmpty {
                        cont.resume(returning: data)
                        return
                    }
                    if isComplete {
                        cont.resume(throwing: MaxTransportError.connectionClosed("EOF"))
                        return
                    }
                    cont.resume(returning: Data())
                }
            }
            if chunk.isEmpty {
                throw MaxTransportError.connectionClosed("EOF")
            }
            collected.append(chunk)
        }
        return collected
    }

    public func close() async {
        connection.cancel()
    }
}

// MARK: - WebSocket Web Transport (wss://ws-api.oneme.ru/websocket)

public final class WebSocketTransport: MaxTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    private init(session: URLSession, task: URLSessionWebSocketTask) {
        self.session = session
        self.task = task
    }

    public static func connect(uri: String = MaxConstants.webSocketURI) async throws -> WebSocketTransport {
        guard let url = URL(string: uri) else {
            throw MaxTransportError.connectionFailed("Invalid WebSocket URL")
        }
        var req = URLRequest(url: url)
        req.setValue(MaxConstants.originHeader, forHTTPHeaderField: "Origin")
        req.setValue(MaxConstants.webUserAgent, forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: .default, delegate: MaxURLSessionDelegate.shared, delegateQueue: nil)
        let wsTask = session.webSocketTask(with: req)
        wsTask.maximumMessageSize = 8 * 1024 * 1024
        wsTask.resume()
        return WebSocketTransport(session: session, task: wsTask)
    }

    public func send(_ request: MaxRequest) async throws {
        let data = try JSONEncoder().encode(request)
        guard let text = String(data: data, encoding: .utf8) else {
            throw MaxTransportError.sendFailed("UTF-8 serialization error")
        }
        try await task.send(.string(text))
    }

    public func receiveMessages() -> AsyncThrowingStream<MaxResponse, Error> {
        AsyncThrowingStream { continuation in
            let runner = Task {
                do {
                    while !Task.isCancelled {
                        let msg = try await self.task.receive()
                        let data: Data
                        switch msg {
                        case .string(let s): data = Data(s.utf8)
                        case .data(let d): data = d
                        @unknown default: continue
                        }
                        let resp = try JSONDecoder().decode(MaxResponse.self, from: data)
                        continuation.yield(resp)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                runner.cancel()
            }
        }
    }

    public func close() async {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

// MARK: - VoiceChannel WS2 Signaling (Calls & Conferences)

public actor MaxVoiceChannel {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var seq: Int = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var receiverTask: Task<Void, Never>?
    private var notificationHandler: (@Sendable (String, JSONValue) -> Void)?

    public init() {}

    public func setNotificationHandler(_ handler: @escaping @Sendable (String, JSONValue) -> Void) {
        self.notificationHandler = handler
    }

    public func connect(urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw MaxTransportError.connectionFailed("Некорректный WS2 URL")
        }
        let s = URLSession(configuration: .default, delegate: MaxURLSessionDelegate.shared, delegateQueue: nil)
        let t = s.webSocketTask(with: url)
        t.resume()
        self.session = s
        self.task = t

        receiverTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let task = await self?.task else { break }
                do {
                    let message = try await task.receive()
                    let text: String
                    switch message {
                    case .string(let str): text = str
                    case .data(let d): text = String(decoding: d, as: UTF8.self)
                    @unknown default: continue
                    }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed == "ping" {
                        try? await task.send(.string("pong"))
                        continue
                    }
                    if trimmed == "pong" { continue }
                    guard let val = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
                        continue
                    }
                    await self?.dispatch(val)
                } catch {
                    await self?.failAllPending(error)
                    break
                }
            }
        }
    }

    private func dispatch(_ msg: JSONValue) {
        if let seqNum = msg["sequence"]?.int64Value.map(Int.init), let cont = pending.removeValue(forKey: seqNum) {
            if msg["type"]?.stringValue == "error" || msg["error"] != nil {
                cont.resume(throwing: MaxTransportError.apiError(msg))
            } else {
                cont.resume(returning: msg)
            }
            return
        }
        if let name = msg["notification"]?.stringValue ?? msg["type"]?.stringValue {
            notificationHandler?(name, msg)
        }
    }

    private func failAllPending(_ error: Error) {
        let copy = pending
        pending.removeAll()
        for (_, cont) in copy {
            cont.resume(throwing: error)
        }
    }

    public func send(command: String, extra: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let task else { throw MaxTransportError.notConnected }
        let currentSeq = seq
        seq += 1
        var obj = extra
        obj["command"] = .string(command)
        obj["sequence"] = .int(Int64(currentSeq))
        let encoded = try JSONEncoder().encode(JSONValue.object(obj))
        guard let str = String(data: encoded, encoding: .utf8) else {
            throw MaxTransportError.sendFailed("UTF-8 encoding error")
        }
        return try await withCheckedThrowingContinuation { cont in
            pending[currentSeq] = cont
            Task {
                do {
                    try await task.send(.string(str))
                } catch {
                    self.removePendingAndFail(seq: currentSeq, error: error)
                }
            }
        }
    }

    private func removePendingAndFail(seq: Int, error: Error) {
        if let cont = pending.removeValue(forKey: seq) {
            cont.resume(throwing: error)
        }
    }

    public func sendQuiet(command: String, extra: [String: JSONValue] = [:]) async {
        guard let task else { return }
        let currentSeq = seq
        seq += 1
        var obj = extra
        obj["command"] = .string(command)
        obj["sequence"] = .int(Int64(currentSeq))
        if let encoded = try? JSONEncoder().encode(JSONValue.object(obj)),
           let str = String(data: encoded, encoding: .utf8) {
            try? await task.send(.string(str))
        }
    }

    public func close() {
        receiverTask?.cancel()
        receiverTask = nil
        failAllPending(MaxTransportError.connectionClosed("VoiceChannel closed"))
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }
}
