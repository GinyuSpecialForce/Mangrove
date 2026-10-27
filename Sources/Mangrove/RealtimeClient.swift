import CryptoKit
import Foundation
import Network
import Security

// MARK: - socket.io 0.9 framing

/// The subset of socket.io 0.9 that this client needs.
///
/// Overleaf pins a fork of socket.io 0.9 (`0.9.19-overleaf-12`), which predates
/// Engine.IO entirely. That has three consequences, all verified against the
/// live service:
///
///   * the handshake is a plain `GET /socket.io/1/?t=…&projectId=…` that answers
///     `sid:heartbeat:closeTimeout:transports`;
///   * the transport is `wss://<host>/socket.io/1/websocket/<sid>`;
///   * frames are text packets shaped `type:id:endpoint:data`, for example
///     `5:::{"name":"joinProjectResponse","args":[…]}`, and several packets in
///     one payload are length-prefixed with U+FFFD.
enum SocketIO09 {
    static let packetNames = [
        "disconnect", "connect", "heartbeat", "message",
        "json", "event", "ack", "error", "noop",
    ]

    struct Packet: Equatable {
        let type: String
        let id: String
        let endpoint: String
        let data: String
    }

    /// Mirrors the server's `/^([^:]+):([0-9]+)?(\+)?:([^:]+)?:?([\s\S]*)?/`.
    static func decode(_ raw: String) -> Packet? {
        guard let first = raw.firstIndex(of: ":") else { return nil }
        guard let typeIndex = Int(raw[raw.startIndex..<first]),
              typeIndex >= 0, typeIndex < packetNames.count else { return nil }

        let afterType = raw.index(after: first)
        guard let second = raw[afterType...].firstIndex(of: ":") else { return nil }

        var id = String(raw[afterType..<second])
        if id.hasSuffix("+") { id.removeLast() }

        let rest = raw[raw.index(after: second)...]
        var endpoint = ""
        var data = ""
        if let third = rest.firstIndex(of: ":") {
            endpoint = String(rest[rest.startIndex..<third])
            data = String(rest[rest.index(after: third)...])
        } else {
            endpoint = String(rest)
        }
        return Packet(type: packetNames[typeIndex], id: id, endpoint: endpoint, data: data)
    }

    /// Splits a payload that may hold several `\ufffd<length>\ufffd<packet>` frames.
    static func splitPayload(_ raw: String) -> [String] {
        guard raw.contains("\u{FFFD}") else { return [raw] }
        var packets: [String] = []
        var rest = Substring(raw)
        while let start = rest.firstIndex(of: "\u{FFFD}") {
            let afterStart = rest.index(after: start)
            guard let end = rest[afterStart...].firstIndex(of: "\u{FFFD}") else { break }
            guard let length = Int(rest[afterStart..<end]) else { break }
            let bodyStart = rest.index(after: end)
            guard let bodyEnd = rest.index(bodyStart, offsetBy: length, limitedBy: rest.endIndex) else {
                packets.append(String(rest[bodyStart...]))
                break
            }
            packets.append(String(rest[bodyStart..<bodyEnd]))
            rest = rest[bodyEnd...]
        }
        return packets.isEmpty ? [raw] : packets
    }

    /// `name` and `args` of an `event` packet.
    static func event(in packet: Packet) -> (name: String, args: [Any])? {
        guard packet.type == "event",
              let payload = packet.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let name = json["name"] as? String else { return nil }
        return (name, json["args"] as? [Any] ?? [])
    }
}

/// The reply to `GET /socket.io/1/`.
struct SocketHandshake: Equatable {
    let sid: String
    let heartbeatInterval: TimeInterval
    let closeTimeout: TimeInterval
    let transports: [String]

    static func parse(_ text: String) -> SocketHandshake? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fields = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 4, !fields[0].isEmpty else { return nil }
        return SocketHandshake(
            sid: fields[0],
            heartbeatInterval: TimeInterval(fields[1]) ?? 60,
            closeTimeout: TimeInterval(fields[2]) ?? 60,
            transports: fields[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        )
    }
}

// MARK: - Project identity from the realtime channel

/// What a save actually needs from the socket: the id of the project's root
/// folder. `POST /Project/:id/upload` requires `folder_id` even for a file at
/// the top level, and no HTTP route exposes folder ids — only `joinProject`
/// does.
struct ProjectJoin: Equatable {
    let rootFolderId: String?
    let rootDocId: String?
}

enum ProjectTreeIds {
    static func rootFolderId(fromJoinPayload payload: [String: Any]) -> String? {
        guard let project = payload["project"] as? [String: Any] else { return nil }
        let roots = project["rootFolder"] as? [[String: Any]] ?? []
        for root in roots {
            if let id = firstFolderId(in: root) { return id }
        }
        return nil
    }

    static func rootDocId(fromJoinPayload payload: [String: Any]) -> String? {
        guard let project = payload["project"] as? [String: Any] else { return nil }
        return (project["rootDoc_id"] as? String) ?? (project["rootDocId"] as? String)
    }

    private static func firstFolderId(in node: [String: Any]) -> String? {
        if let id = node["_id"] as? String, !id.isEmpty { return id }
        for child in node["folders"] as? [[String: Any]] ?? [] {
            if let id = firstFolderId(in: child) { return id }
        }
        return nil
    }
}

// MARK: - Raw HTTP/1.1 WebSocket

enum WebSocketFailure: LocalizedError {
    case connectionFailed(String)
    case handshakeStatus(Int, String)
    case unexpectedReply
    case closed

    var errorDescription: String? {
        switch self {
        case let .connectionFailed(detail):
            return "Could not open a realtime connection to Overleaf (\(detail))."
        case let .handshakeStatus(status, detail):
            let suffix = detail.isEmpty ? "" : " — \(detail)"
            return "Overleaf's realtime service refused the connection (HTTP \(status))\(suffix)."
        case .unexpectedReply:
            return "Overleaf's realtime service answered the connection request with something unexpected."
        case .closed:
            return "Overleaf closed the realtime connection."
        }
    }
}

/// Resumes an awaiting caller exactly once, whichever side gets there first.
private final class OnceResult<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false
    private let continuation: CheckedContinuation<T, Error>

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let alreadySettled = settled
        if !alreadySettled { settled = true }
        lock.unlock()
        guard !alreadySettled else { return }
        continuation.resume(with: result)
    }
}

/// A minimal WebSocket client that always speaks HTTP/1.1.
///
/// `URLSessionWebSocketTask` cannot be used here. It negotiates HTTP/2 over ALPN,
/// and Overleaf's load balancer answers **502** to an HTTP/2 upgrade while the
/// identical request over HTTP/1.1 returns **101** — measured, not assumed. HTTP/1.1
/// is therefore pinned in ALPN, and the upgrade and framing are handled directly
/// on an `NWConnection`.
///
/// Only what the join handshake needs is implemented: text frames in, masked
/// control frames out, and the close path.
final class HTTP1WebSocket {
    private let host: String
    private let port: UInt16
    private let secure: Bool
    private let path: String
    private let extraHeaders: [String: String]
    private let userAgent: String
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "com.mangrovedesktop.websocket")

    private var connection: NWConnection?
    private var buffer = Data()
    private var handshakeBox: OnceResult<Void>?
    private var handshakeComplete = false
    private var partialMessage: [UInt8]?
    private var closed = false

    var onText: ((String) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(host: String, port: UInt16, secure: Bool, path: String,
         extraHeaders: [String: String], userAgent: String, timeout: TimeInterval = 25) {
        self.host = host
        self.port = port
        self.secure = secure
        self.path = path
        self.extraHeaders = extraHeaders
        self.userAgent = userAgent
        self.timeout = timeout
    }

    // MARK: Lifecycle

    func open() async throws {
        let parameters: NWParameters
        if secure {
            let tls = NWProtocolTLS.Options()
            // Pin the upgrade to HTTP/1.1; an HTTP/2 upgrade is rejected upstream.
            sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 443, using: parameters
        )
        self.connection = connection

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceResult<Void>(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.finish(.success(()))
                case let .failed(error), let .waiting(error):
                    box.finish(.failure(WebSocketFailure.connectionFailed(error.localizedDescription)))
                case .cancelled:
                    box.finish(.failure(WebSocketFailure.closed))
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case let .failed(error):
                self?.fireClose(WebSocketFailure.connectionFailed(error.localizedDescription))
            case .cancelled:
                self?.fireClose(nil)
            default:
                break
            }
        }

        try await send(handshakeRequest())
        pump()
        try await waitForHandshake()
    }

    func close() {
        queue.async {
            guard !self.closed else { return }
            self.sendFrame(opcode: 0x8, payload: [])
            self.closed = true
            self.connection?.cancel()
        }
    }

    // MARK: Upgrade

    private func handshakeRequest() -> Data {
        let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        var lines = [
            "GET \(path) HTTP/1.1",
            "Host: \(host)\(defaultPort ? "" : ":\(port)")",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Key: \(key)",
            "Sec-WebSocket-Version: 13",
            "User-Agent: \(userAgent)",
        ]
        if secure {
            lines.append("Origin: https://\(host)")
        }
        for (name, value) in extraHeaders.sorted(by: { $0.key < $1.key }) {
            lines.append("\(name): \(value)")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private var defaultPort: Bool { (secure && port == 443) || (!secure && port == 80) }

    /// Pulls the useful line out of a load balancer's error page without dumping
    /// HTML into a banner.
    static func briefDiagnostic(head: String, body: Data) -> String {
        let text = (head + " " + String(decoding: body.prefix(600), as: UTF8.self))
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if let match = text.range(of: "<h2>([^<]*)</h2>", options: .regularExpression) {
            let inner = String(text[match]).replacingOccurrences(of: "<h2>", with: "")
                .replacingOccurrences(of: "</h2>", with: "")
            if !inner.isEmpty { return inner.trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }

    private func waitForHandshake() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let box = OnceResult<Void>(continuation)
            queue.async {
                self.handshakeBox = box
                self.parseBuffered()
            }
        }
    }

    // MARK: Inbound

    private func pump() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.parseBuffered()
            }
            if let error {
                self.fireClose(WebSocketFailure.connectionFailed(error.localizedDescription))
                return
            }
            if isComplete {
                self.fireClose(nil)
                return
            }
            self.pump()
        }
    }

    /// Consumes whatever is buffered: first the upgrade reply, then frames.
    private func parseBuffered() {
        guard !closed else { return }

        if !handshakeComplete {
            guard handshakeBox != nil else { return }
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }
            let head = String(decoding: buffer[buffer.startIndex..<headerEnd.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<headerEnd.upperBound)

            guard let statusLine = head.split(separator: "\r\n").first else {
                handshakeBox?.finish(.failure(WebSocketFailure.unexpectedReply))
                return
            }
            let status = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            guard status == 101 else {
                let detail = Self.briefDiagnostic(head: head, body: buffer)
                handshakeBox?.finish(.failure(WebSocketFailure.handshakeStatus(status, detail)))
                return
            }
            handshakeComplete = true
            handshakeBox?.finish(.success(()))
            handshakeBox = nil
        }

        drainFrames()
    }

    private func drainFrames() {
        while true {
            guard buffer.count >= 2 else { return }
            let first = buffer[buffer.startIndex]
            let second = buffer[buffer.index(after: buffer.startIndex)]
            let finished = (first & 0x80) != 0
            let opcode = first & 0x0F
            let masked = (second & 0x80) != 0
            var length = Int(second & 0x7F)
            var offset = 2

            if length == 126 {
                guard buffer.count >= 4 else { return }
                length = Int(byte(at: 2)) << 8 | Int(byte(at: 3))
                offset = 4
            } else if length == 127 {
                guard buffer.count >= 10 else { return }
                var value = 0
                for index in 2..<10 { value = value << 8 | Int(byte(at: index)) }
                length = value
                offset = 10
            }

            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count >= offset + 4 else { return }
                maskKey = (0..<4).map { byte(at: offset + $0) }
                offset += 4
            }
            guard buffer.count >= offset + length else { return }

            let payloadStart = buffer.index(buffer.startIndex, offsetBy: offset)
            var payload = [UInt8](buffer[payloadStart..<buffer.index(payloadStart, offsetBy: length)])
            buffer.removeSubrange(buffer.startIndex..<buffer.index(payloadStart, offsetBy: length))
            if masked, !maskKey.isEmpty {
                for index in payload.indices { payload[index] ^= maskKey[index % 4] }
            }

            switch opcode {
            case 0x1:
                if finished {
                    deliver(payload)
                } else {
                    partialMessage = payload
                }
            case 0x0:
                var message = partialMessage ?? []
                message.append(contentsOf: payload)
                if finished {
                    partialMessage = nil
                    deliver(message)
                } else {
                    partialMessage = message
                }
            case 0x8:
                fireClose(nil)
                return
            case 0x9:
                sendFrame(opcode: 0xA, payload: payload)
            default:
                break
            }
        }
    }

    private func byte(at offset: Int) -> UInt8 {
        buffer[buffer.index(buffer.startIndex, offsetBy: offset)]
    }

    private func deliver(_ bytes: [UInt8]) {
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        onText?(text)
    }

    // MARK: Outbound

    private func send(_ data: Data) async throws {
        guard let connection else { throw WebSocketFailure.closed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: WebSocketFailure.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private func sendFrame(opcode: UInt8, payload: [UInt8]) {
        guard let connection, !closed else { return }
        var frame = Data([0x80 | opcode])
        let mask: [UInt8] = (0..<4).map { _ in UInt8.random(in: 0...255) }

        if payload.count < 126 {
            frame.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(0x80 | 126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(contentsOf: mask)
        var masked = [UInt8](repeating: 0, count: payload.count)
        for index in payload.indices { masked[index] = payload[index] ^ mask[index % 4] }
        frame.append(contentsOf: masked)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    private func fireClose(_ error: Error?) {
        queue.async {
            guard !self.closed else { return }
            self.closed = true
            self.handshakeBox?.finish(.failure(error ?? WebSocketFailure.closed))
            self.onClose?(error)
            self.connection?.cancel()
        }
    }
}

// MARK: - Client

/// Opens Overleaf's realtime channel just long enough to join the project and
/// read the ids the HTTP API will not give us.
///
/// The server joins automatically: `joinProject` is driven by the `projectId`
/// query parameter on the handshake, and the response arrives as a
/// `joinProjectResponse` event without the client emitting anything.
final class RealtimeChannel {
    private let baseURL: URL
    private let cookieHeader: String
    private let userAgent: String
    private let timeout: TimeInterval
    private let urlSession: URLSession
    private let log: (String) -> Void

    init(
        baseURL: URL,
        cookieHeader: String,
        userAgent: String,
        timeout: TimeInterval = 25,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.baseURL = baseURL
        self.cookieHeader = cookieHeader
        self.userAgent = userAgent
        self.timeout = timeout
        self.log = log

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        self.urlSession = URLSession(configuration: configuration)
    }

    /// Joins a project, retrying the whole handshake when the upgrade fails.
    ///
    /// The load balancer in front of Overleaf intermittently answers 502 to the
    /// WebSocket upgrade because the session id is only known to the backend that
    /// issued it (measured: roughly one attempt in four). Each retry performs a
    /// fresh handshake, which yields both a new session id and a fresh affinity
    /// cookie, so it lands somewhere that can serve it.
    func joinProject(_ projectId: String) async throws -> ProjectJoin {
        let attempts = 4
        var lastError: Error = WebSocketFailure.closed

        for attempt in 1...attempts {
            do {
                return try await attemptJoin(projectId)
            } catch {
                lastError = error
                guard Self.isRetryableUpgrade(error), attempt < attempts else { break }
                log("realtime upgrade failed on attempt \(attempt), retrying")
                try? await Task.sleep(nanoseconds: 350_000_000 * UInt64(attempt))
            }
        }
        throw Self.describeTransport(lastError)
    }

    private func attemptJoin(_ projectId: String) async throws -> ProjectJoin {
        let (handshake, affinityCookies) = try await handshake(projectId: projectId)
        log("realtime handshake ok, transports=\(handshake.transports.joined(separator: ","))")
        guard handshake.transports.contains("websocket") else {
            throw MangroveError.message(
                "Overleaf's realtime service did not offer a WebSocket transport, so files cannot be written."
            )
        }

        var headers: [String: String] = [:]
        let cookies = ([cookieHeader] + affinityCookies).filter { !$0.isEmpty }.joined(separator: "; ")
        if !cookies.isEmpty { headers["Cookie"] = cookies }

        let secure = (baseURL.scheme ?? "https").lowercased() != "http"
        let socket = HTTP1WebSocket(
            host: baseURL.host ?? "",
            port: UInt16(baseURL.port ?? (secure ? 443 : 80)),
            secure: secure,
            path: "/socket.io/1/websocket/\(handshake.sid)",
            extraHeaders: headers,
            userAgent: userAgent,
            timeout: timeout
        )
        defer { socket.close() }

        return try await connect(
            socket: socket, deadline: max(timeout, handshake.closeTimeout)
        )
    }

    // MARK: Join

    private func connect(socket: HTTP1WebSocket, deadline: TimeInterval) async throws -> ProjectJoin {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProjectJoin, Error>) in
            let waiter = OnceResult<ProjectJoin>(continuation)

            socket.onText = { [weak self] text in
                guard let self else { return }
                guard let outcome = self.join(from: text) else { return }
                switch outcome {
                case let .success(join): waiter.finish(.success(join))
                case let .failure(error): waiter.finish(.failure(error))
                }
            }
            socket.onClose = { error in
                waiter.finish(.failure(error ?? WebSocketFailure.closed))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline) {
                waiter.finish(.failure(MangroveError.message(
                    "Overleaf's realtime service did not answer in time, so the file could not be saved."
                )))
            }

            // Raw errors are kept intact so the caller can tell a retryable
            // upgrade failure from a final rejection; wording happens once, at
            // the end.
            Task {
                do {
                    try await socket.open()
                } catch {
                    waiter.finish(.failure(error))
                }
            }
        }
    }

    /// Returns a result only when the stream contains a decision; otherwise nil
    /// and the socket keeps reading.
    private func join(from text: String) -> Result<ProjectJoin, Error>? {
        for raw in SocketIO09.splitPayload(text) {
            guard let packet = SocketIO09.decode(raw) else { continue }

            if let event = SocketIO09.event(in: packet) {
                log("realtime event \(event.name)")
                switch event.name {
                case "joinProjectResponse":
                    let payload = event.args.compactMap { $0 as? [String: Any] }.first ?? [:]
                    return .success(ProjectJoin(
                        rootFolderId: ProjectTreeIds.rootFolderId(fromJoinPayload: payload),
                        rootDocId: ProjectTreeIds.rootDocId(fromJoinPayload: payload)
                    ))
                case "connectionRejected":
                    let reason = (event.args.first as? [String: Any])?["message"] as? String ?? ""
                    log("realtime rejected: \(reason)")
                    return .failure(Self.describeRejection(reason))
                default:
                    continue
                }
            }

            if packet.type == "error" {
                return .failure(MangroveError.message("Overleaf's realtime service refused the connection."))
            }
        }
        return nil
    }

    // MARK: Handshake

    private func handshake(projectId: String) async throws -> (SocketHandshake, [String]) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.path = "/socket.io/1/"
        components.queryItems = [
            URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "projectId", value: projectId),
        ]
        guard let url = components.url else {
            throw MangroveError.message("Could not build the realtime handshake URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !cookieHeader.isEmpty {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            log("realtime handshake failed: \(error.localizedDescription)")
            throw MangroveError.message(
                "Could not reach Overleaf's realtime service, which is required to save files. \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw MangroveError.message("Overleaf's realtime service sent an unreadable response.")
        }
        guard http.statusCode == 200 else {
            log("realtime handshake status \(http.statusCode)")
            throw MangroveError.http(status: http.statusCode, body: OverleafClient.describe(body: data))
        }

        let text = String(decoding: data.prefix(400), as: UTF8.self)
        guard let handshake = SocketHandshake.parse(text) else {
            log("realtime handshake unparseable")
            throw MangroveError.message("Overleaf's realtime service answered with an unexpected handshake.")
        }

        let affinity = Self.affinityCookies(from: http, excluding: cookieNames(in: cookieHeader))
        return (handshake, affinity)
    }

    private func cookieNames(in header: String) -> Set<String> {
        Set(header.split(separator: ";").compactMap { pair in
            pair.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) }
        })
    }

    /// The load balancer in front of Overleaf pins the session id to one backend
    /// with a cookie (`GCLB`). Without it the WebSocket upgrade lands on a node
    /// that has never heard of the sid and answers 502, so this cookie has to
    /// travel with the upgrade request.
    ///
    /// Parsed from the raw header rather than through `HTTPCookie`, which drops
    /// host-only cookies set without a `Domain` attribute — exactly how this one
    /// arrives.
    static func affinityCookies(from response: HTTPURLResponse, excluding existing: Set<String>) -> [String] {
        var headerTexts: [String] = []
        for (key, value) in response.allHeaderFields {
            guard let name = key as? String, name.lowercased() == "set-cookie",
                  let text = value as? String else { continue }
            headerTexts.append(text)
        }
        guard !headerTexts.isEmpty else { return [] }

        // Several Set-Cookie headers may arrive comma-joined; a comma starts a new
        // cookie only when followed by `name=`, which leaves `Expires` dates alone.
        let joined = headerTexts.joined(separator: ",")
        let boundary = joined.replacingOccurrences(
            of: ",(?=\\s*[A-Za-z0-9_.\\-]+=)",
            with: "\u{0}",
            options: .regularExpression
        )

        var seen = existing
        var result: [String] = []
        for piece in boundary.split(separator: "\u{0}") {
            guard let pair = piece.split(separator: ";", maxSplits: 1).first else { continue }
            guard let equals = pair.firstIndex(of: "=") else { continue }
            let name = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !value.isEmpty, !seen.contains(name) else { continue }
            seen.insert(name)
            result.append("\(name)=\(value)")
        }
        return result
    }

    // MARK: Failure wording

    /// Only failures a new handshake can plausibly fix. A rejected session or a
    /// missing project is final, so it is reported straight away.
    static func isRetryableUpgrade(_ error: Error) -> Bool {
        switch error {
        case let WebSocketFailure.handshakeStatus(status, _):
            return status >= 500
        case WebSocketFailure.connectionFailed, WebSocketFailure.closed:
            return true
        case let MangroveError.http(status, _):
            return status >= 500
        default:
            return false
        }
    }

    static func describeRejection(_ reason: String) -> MangroveError {
        switch reason {
        case "invalid session", "not authorized":
            return .notAuthenticated
        case "project not found":
            return .message("Overleaf could not find that project, so nothing was saved.")
        case "rate-limit hit when joining project":
            return .message("Overleaf is limiting how often a project can be opened for editing. Wait a few seconds and save again.")
        case "":
            return .message("Overleaf refused the realtime connection, so nothing was saved.")
        default:
            return .message("Overleaf refused the realtime connection: \(reason).")
        }
    }

    static func describeTransport(_ error: Error) -> Error {
        if let failure = error as? WebSocketFailure {
            return MangroveError.message("\(failure.errorDescription ?? "Could not reach Overleaf.") Nothing was saved.")
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return MangroveError.message("The realtime connection to Overleaf timed out, so nothing was saved.")
            case .notConnectedToInternet, .networkConnectionLost:
                return MangroveError.message("Lost the connection to Overleaf, so nothing was saved.")
            default:
                return MangroveError.message("The realtime connection to Overleaf failed: \(urlError.localizedDescription)")
            }
        }
        return error
    }
}

// MARK: - Diagnostics

/// A short append-only log of save attempts.
///
/// Saving needs a socket handshake plus an upload, and when that fails on
/// someone else's machine the only useful evidence is which step broke. This
/// records outcomes and ids — never cookies, file contents or anything typed.
enum SyncDiagnostics {
    static let logURL: URL? = {
        guard let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let directory = base.appendingPathComponent("Mangrove", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("sync.log")
    }()

    private static let queue = DispatchQueue(label: "com.mangrovedesktop.sync-log")
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func write(_ line: String) {
        guard let url = logURL else { return }
        let stamp = formatter.string(from: Date())
        queue.async {
            guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
