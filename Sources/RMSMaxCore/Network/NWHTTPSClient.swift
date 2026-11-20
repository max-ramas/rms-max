import Foundation
import Network

/// Minimal HTTP/1.1 over TLS on Network.framework — the same stack and the same trust rule (MaxTrustEvaluator) as the
/// MAX API connection, which works where URLSession/CFNetwork uploads failed with `-1200 / -9802` on the user's Mac.
/// Also gives the real HTTP status and error body of the media server instead of an opaque TLS error.
enum NWHTTPSClient {
    struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    enum ClientError: Error, LocalizedError {
        case unsupportedScheme, closedEarly, badResponse, timeout
        var errorDescription: String? {
            switch self {
            case .unsupportedScheme: return "Адрес загрузки не https"
            case .closedEarly: return "Сервер закрыл соединение до ответа"
            case .badResponse: return "Непонятный ответ сервера загрузки"
            case .timeout: return "Сервер загрузки не ответил вовремя"
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func enter() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// GET with up to 4 redirects.
    static func get(url: URL, headers: [String: String] = [:], ipv4Only: Bool = false, timeout: TimeInterval = 180) async throws -> Response {
        var current = url
        for _ in 0..<5 {
            let r = try await request(method: "GET", url: current, headers: headers, body: Data(), timeout: timeout, ipv4Only: ipv4Only)
            if [301, 302, 303, 307, 308].contains(r.status), let loc = r.headers["location"], let next = URL(string: loc, relativeTo: current)?.absoluteURL {
                current = next
                continue
            }
            return r
        }
        throw ClientError.badResponse
    }

    static func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval = 180) async throws -> Response {
        try await request(method: "POST", url: url, headers: headers, body: body, timeout: timeout)
    }

    private static func request(method: String, url: URL, headers: [String: String], body: Data, timeout: TimeInterval, ipv4Only: Bool = false) async throws -> Response {
        guard url.scheme?.lowercased() == "https", let host = url.host else { throw ClientError.unsupportedScheme }
        let port = UInt16(url.port ?? 443)
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var target = comps?.percentEncodedPath ?? "/"
        if target.isEmpty { target = "/" }
        if let q = comps?.percentEncodedQuery, !q.isEmpty { target += "?" + q }

        let conn = try makeConnection(host: host, port: port, ipv4Only: ipv4Only)
        defer { conn.cancel() }
        let queue = DispatchQueue(label: "dev.rms.maks.upload.tls")
        try await connect(conn, queue: queue)

        var head = "\(method) \(target) HTTP/1.1\r\nHost: \(url.port.map { "\(host):\($0)" } ?? host)\r\n"
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) { head += "User-Agent: RMS-MAKS\r\n" }
        head += "Accept: */*\r\nConnection: close\r\n"
        if method != "GET" { head += "Content-Length: \(body.count)\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        return try await withThrowingTaskGroup(of: Response.self) { group in
            group.addTask {
                var payload = Data(head.utf8)
                payload.append(body)
                try await send(conn, payload)
                return try await readResponse(conn)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                conn.cancel()
                throw ClientError.timeout
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: - Connection

    private static func makeConnection(host: String, port: UInt16, ipv4Only: Bool = false) throws -> NWConnection {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_tls_server_name(sec, host)
        sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            complete(MaxTrustEvaluator.evaluateServerTrust(secTrust, host: host))
        }, DispatchQueue(label: "dev.rms.maks.upload.verify"))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        guard let p = NWEndpoint.Port(rawValue: port) else { throw ClientError.badResponse }
        let params = NWParameters(tls: tls, tcp: tcp)
        if ipv4Only, let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        return NWConnection(host: NWEndpoint.Host(host), port: p, using: params)
    }

    private static func connect(_ conn: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let gate = Gate()
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if gate.enter() { conn.stateUpdateHandler = nil; cont.resume() }
                case .failed(let e):
                    if gate.enter() { conn.stateUpdateHandler = nil; cont.resume(throwing: e) }
                case .cancelled:
                    if gate.enter() { conn.stateUpdateHandler = nil; cont.resume(throwing: ClientError.closedEarly) }
                default: break
                }
            }
            conn.start(queue: queue)
        }
    }

    private static func send(_ conn: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    private static func receive(_ conn: NWConnection) async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, isComplete)) }
            }
        }
    }

    // MARK: - Response

    private static func readResponse(_ conn: NWConnection) async throws -> Response {
        var buffer = Data()
        let sep = Data("\r\n\r\n".utf8)
        var headEnd: Range<Data.Index>?
        var eof = false
        while headEnd == nil {
            if eof { throw ClientError.closedEarly }
            let (d, done) = try await receive(conn)
            if let d { buffer.append(d) }
            eof = done
            headEnd = buffer.range(of: sep)
        }
        let headText = String(decoding: buffer[..<headEnd!.lowerBound], as: UTF8.self)
        var body = Data(buffer[headEnd!.upperBound...])
        let (status, headers) = try parseHead(headText)

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            while true {
                if let decoded = decodeChunked(body) { body = decoded; break }
                if eof { break }
                let (d, done) = try await receive(conn)
                if let d { body.append(d) }
                eof = done
            }
        } else if let len = headers["content-length"].flatMap(Int.init) {
            while body.count < len, !eof {
                let (d, done) = try await receive(conn)
                if let d { body.append(d) }
                eof = done
            }
        } else {
            while !eof {
                let (d, done) = try await receive(conn)
                if let d { body.append(d) }
                eof = done
            }
        }
        return Response(status: status, headers: headers, body: body)
    }

    static func parseHead(_ text: String) throws -> (Int, [String: String]) {
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("HTTP/"),
              let code = first.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else { throw ClientError.badResponse }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let i = line.firstIndex(of: ":") else { continue }
            headers[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        return (code, headers)
    }

    /// Returns the decoded body once the terminating zero-size chunk has arrived, nil while incomplete.
    static func decodeChunked(_ raw: Data) -> Data? {
        var out = Data()
        var i = raw.startIndex
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = raw.range(of: crlf, in: i..<raw.endIndex) else { return nil }
            let sizeText = String(decoding: raw[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { return nil }
            i = lineEnd.upperBound
            if size == 0 { return out }
            guard raw.distance(from: i, to: raw.endIndex) >= size + 2 else { return nil }
            out.append(raw[i..<raw.index(i, offsetBy: size)])
            i = raw.index(i, offsetBy: size + 2)
        }
    }
}
