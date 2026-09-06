import Foundation
import Logging
import Network

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    /// キーは小文字。HTTP のヘッダ名は大文字小文字を区別しない。
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? { headers[name.lowercased()] }
}

struct HTTPResponse: Sendable {
    var status: Int
    var headers: [(String, String)] = []
    var body: Data = Data()

    static func json(_ status: Int, _ data: Data, extraHeaders: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")] + extraHeaders, body: data)
    }
}

/// Network.framework 直上の HTTP/1.1 サーバー。守備範囲はこのブリッジのクライアント
/// （コンテナ内の Claude Code・curl・kit）が使う範囲だけ: Content-Length のボディ、
/// keep-alive、逐次処理。chunked・TLS・HTTP/2・サーバー push は対応しない。
final class HTTPServer: Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    static let maxBodyBytes = 32 * 1_048_576
    private static let maxHeaderBytes = 64 * 1024

    private let listener: NWListener
    private let handler: Handler
    private let logger: Logger

    init(host: String, port: Int, handler: @escaping Handler, logger: Logger) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw BackendError.unreachable("invalid port \(port)")
        }
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .init(host), port: nwPort)
        self.listener = try NWListener(using: parameters)
        self.handler = handler
        self.logger = logger
    }

    /// 待ち受けを開始し、終了しない。listener が落ちたときだけ throw する。
    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [logger] state in
                switch state {
                case .ready:
                    logger.info("listening on port \(self.listener.port?.rawValue ?? 0)")
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [handler, logger] connection in
                connection.start(queue: .global())
                Task { await Self.serve(connection, handler: handler, logger: logger) }
            }
            listener.start(queue: .global())
        }
    }

    var boundPort: Int { Int(listener.port?.rawValue ?? 0) }

    private static func serve(_ connection: NWConnection, handler: Handler, logger: Logger) async {
        var buffer = Data()
        defer { connection.cancel() }
        while true {
            guard let request = await nextRequest(connection, buffer: &buffer, logger: logger) else {
                return
            }
            let response = await handler(request)
            await send(response, over: connection)
            if request.header("connection")?.lowercased() == "close" {
                return
            }
        }
    }

    /// 1 リクエストを読み切る。プロトコル違反はエラー応答を返してから nil。
    private static func nextRequest(
        _ connection: NWConnection, buffer: inout Data, logger: Logger
    ) async -> HTTPRequest? {
        while true {
            if let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) else {
                    await reject(400, "malformed request head", over: connection)
                    return nil
                }
                var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false)
                let requestLine = lines.removeFirst().split(separator: " ")
                guard requestLine.count >= 2 else {
                    await reject(400, "malformed request line", over: connection)
                    return nil
                }
                var headers: [String: String] = [:]
                var conflictingLength = false
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    let name = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    // 食い違う Content-Length を後勝ちで採ると、ボディの残りが次の
                    // リクエストとして読まれる。数が合わない時点で断る。
                    if name == "content-length", let seen = headers[name], seen != value {
                        conflictingLength = true
                    }
                    headers[name] = value
                }
                guard !conflictingLength else {
                    await reject(400, "conflicting content-length", over: connection)
                    return nil
                }
                if headers["transfer-encoding"] != nil {
                    await reject(411, "chunked bodies are not supported", over: connection)
                    return nil
                }
                // 読めない値を 0 に倒すと、ボディがそのまま次のリクエストになる。
                let contentLength: Int
                if let text = headers["content-length"] {
                    guard let parsed = Int(text), parsed >= 0, !text.hasPrefix("+") else {
                        await reject(400, "invalid content-length", over: connection)
                        return nil
                    }
                    contentLength = parsed
                } else {
                    contentLength = 0
                }
                guard contentLength <= maxBodyBytes else {
                    let alreadyRead = buffer.distance(from: headEnd.upperBound, to: buffer.endIndex)
                    await drain(contentLength - alreadyRead, over: connection)
                    await reject(413, "body too large", over: connection)
                    return nil
                }
                buffer.removeSubrange(..<headEnd.upperBound)
                while buffer.count < contentLength {
                    guard let chunk = await receive(connection), !chunk.isEmpty else { return nil }
                    buffer.append(chunk)
                }
                let body = buffer.prefix(contentLength)
                buffer.removeSubrange(..<buffer.index(buffer.startIndex, offsetBy: contentLength))
                return HTTPRequest(
                    method: String(requestLine[0]),
                    path: String(requestLine[1]),
                    headers: headers,
                    body: Data(body)
                )
            }
            guard buffer.count < maxHeaderBytes else {
                await reject(431, "request head too large", over: connection)
                return nil
            }
            guard let chunk = await receive(connection), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
        }
    }

    private static func receive(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
                if error != nil || (isComplete && data == nil) {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private static func send(_ response: HTTPResponse, over connection: NWConnection) async {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        for (name, value) in response.headers {
            head += "\(name): \(value)\r\n"
        }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: Data(head.utf8) + response.body,
                completion: .contentProcessed { _ in continuation.resume() })
        }
    }

    /// 拒否した要求の残りを読み捨てる。上限は要求が申告した長さまでで、途中で
    /// 途切れたらそこで止める。
    private static func drain(_ remaining: Int, over connection: NWConnection) async {
        var left = remaining
        while left > 0 {
            guard let chunk = await receive(connection), !chunk.isEmpty else { return }
            left -= chunk.count
        }
    }

    private static func reject(_ status: Int, _ message: String, over connection: NWConnection) async {
        let body = (try? JSONSerialization.data(withJSONObject: ["bridgeError": message])) ?? Data()
        await send(.json(status, body), over: connection)
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 411: "Length Required"
        case 413: "Payload Too Large"
        case 431: "Request Header Fields Too Large"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        default: "Status \(status)"
        }
    }
}
