import Foundation
import Logging

struct BackendResponse: Sendable {
    let body: Data?
    let sessionId: String?
}

protocol MCPBackend: Sendable {
    func send(_ message: Data, sessionId: String?, protocolVersion: String?) async throws -> BackendResponse
    func endSession(_ sessionId: String?) async
}

enum BackendError: LocalizedError {
    case unreachable(String)
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .unreachable(let detail): return "backend unreachable: \(detail)"
        case .badResponse(let detail): return "backend returned an unusable response: \(detail)"
        }
    }
}

/// url 型サーバーに Authorization を付ける値の出どころ。OAuth のように更新が要る
/// ものと、ファイルに置いた固定トークンを同じ形で扱う。
protocol MCPTokenProvider: Sendable {
    /// forceRefresh は 401 を受けた直後の 1 回だけ true になる。
    func accessToken(forceRefresh: Bool) async throws -> String
}

extension MCPTokenProvider {
    func accessToken() async throws -> String { try await accessToken(forceRefresh: false) }
}

/// 事前に発行したトークンをファイルから読む。認可サーバーが動的クライアント登録に
/// 対応していない相手はこちらを使う。401 のたびに読み直すので、入れ替えても
/// ブリッジの再起動は要らない。
struct StaticTokenProvider: MCPTokenProvider {
    let serverName: String
    let path: String

    func accessToken(forceRefresh: Bool) async throws -> String {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw BackendError.unreachable(
                "'\(serverName)' のトークンがありません。ホストで 'ios-dev-sandbox mcp-token \(serverName)' を実行して登録してください")
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw BackendError.unreachable(
                "'\(serverName)' のトークンが空です。ホストで 'ios-dev-sandbox mcp-token \(serverName)' を実行して登録し直してください")
        }
        return token
    }
}

struct URLBackend: MCPBackend {
    let url: URL
    let logger: Logger
    var auth: (any MCPTokenProvider)?

    func send(_ message: Data, sessionId: String?, protocolVersion: String?) async throws -> BackendResponse {
        var response = try await post(message, sessionId: sessionId, protocolVersion: protocolVersion, forceRefresh: false)
        if response.status == 401, auth != nil {
            response = try await post(message, sessionId: sessionId, protocolVersion: protocolVersion, forceRefresh: true)
        }
        return try unwrap(response)
    }

    private struct RawResponse {
        let status: Int
        let data: Data
        let http: HTTPURLResponse
    }

    private func post(_ message: Data, sessionId: String?, protocolVersion: String?, forceRefresh: Bool) async throws -> RawResponse {
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.httpBody = message
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionId {
            request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        }
        if let protocolVersion {
            request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if let auth {
            let token = try await auth.accessToken(forceRefresh: forceRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw BackendError.badResponse("not HTTP")
            }
            return RawResponse(status: http.statusCode, data: data, http: http)
        } catch let error as BackendError {
            throw error
        } catch {
            throw BackendError.unreachable(error.localizedDescription)
        }
    }

    private func unwrap(_ raw: RawResponse) throws -> BackendResponse {
        let data = raw.data
        let http = raw.http
        let newSession = http.value(forHTTPHeaderField: "Mcp-Session-Id")

        if http.statusCode == 202 || data.isEmpty {
            return BackendResponse(body: nil, sessionId: newSession)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw BackendError.badResponse("HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        if contentType.contains("text/event-stream") {
            guard let unwrapped = Self.lastDataPayload(fromSSE: data) else {
                throw BackendError.badResponse("SSE stream held no data payload")
            }
            return BackendResponse(body: unwrapped, sessionId: newSession)
        }
        return BackendResponse(body: data, sessionId: newSession)
    }

    func endSession(_ sessionId: String?) async {
        guard let sessionId else { return }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "DELETE"
        request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id")
        if let auth, let token = try? await auth.accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        _ = try? await URLSession.shared.data(for: request)
    }

    /// SSE の data: 行のうち、JSON-RPC の応答（id と result/error を持つ）を優先して返す。
    /// 途中に進捗通知が混ざるストリームでも、要求への応答を落とさない。
    static func lastDataPayload(fromSSE data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lastPayload: Data?
        var lastResponse: Data?
        var currentData = ""
        func finishEvent() {
            guard !currentData.isEmpty else { return }
            let payload = Data(currentData.utf8)
            currentData = ""
            lastPayload = payload
            if let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
               obj["id"] != nil, obj["result"] != nil || obj["error"] != nil {
                lastResponse = payload
            }
        }
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty { finishEvent(); continue }
            if line.hasPrefix("data:") {
                let value = line.dropFirst(5).trimmingCharacters(in: .init(charactersIn: " "))
                currentData += currentData.isEmpty ? value : "\n" + value
            }
        }
        finishEvent()
        return lastResponse ?? lastPayload
    }
}

/// command 型: ホストで stdio MCP を子プロセスとして 1 つ起動して中継する。
/// 子は使い回し、2 回目以降の initialize には初回の応答を（id を差し替えて）返す。
///
/// 応答の受け取りは id で引く待機表 + 単一の reader タスク。send のたびに行を
/// 読む方式だと、並行リクエストが互いの応答を先に消費して落とす（actor は
/// await 中に再入する）。
/// MCP セッションごとに stdio の子プロセスを 1 つ持つ。1 つを共有すると、どの
/// クライアントも JSON-RPC の id を 1 から振るため、複数プロジェクトを同時に開いた
/// ときに応答が取り違えられる。
actor CommandBackend: MCPBackend {
    /// 使われなくなったセッションを畳むまでの猶予。
    static let idleTimeout: TimeInterval = 30 * 60

    private final class Child {
        let process: Process
        let stdin: FileHandle
        var reader: Task<Void, Never>?
        var waiters: [String: CheckedContinuation<Result<Data, BackendError>, Never>] = [:]
        var lastActivity = Date()

        init(process: Process, stdin: FileHandle) {
            self.process = process
            self.stdin = stdin
        }

        var isRunning: Bool { process.isRunning }
    }

    let command: [String]
    let logger: Logger

    private var children: [String: Child] = [:]
    private var sweeper: Task<Void, Never>?

    init(command: [String], logger: Logger) {
        self.command = command
        self.logger = logger
    }

    func send(_ message: Data, sessionId: String?, protocolVersion: String?) async throws -> BackendResponse {
        let peeked = (try? JSONSerialization.jsonObject(with: message)) as? [String: Any]
        let method = peeked?["method"] as? String

        if method == "initialize" {
            return try await openSession(with: message, id: peeked?["id"])
        }

        guard let sessionId else {
            throw BackendError.badResponse(
                "Mcp-Session-Id がありません。initialize からやり直してください")
        }
        let child: Child
        if let existing = children[sessionId], existing.isRunning {
            child = existing
        } else {
            child = try await revive(sessionId, protocolVersion: protocolVersion)
        }
        child.lastActivity = Date()
        return try await forward(message, id: peeked?["id"], to: child)
    }

    func endSession(_ sessionId: String?) async {
        guard let sessionId, let child = children.removeValue(forKey: sessionId) else { return }
        terminate(child)
        logger.info("\(command[0]) session closed: \(sessionId) (\(children.count) active)")
    }


    /// 回収済みの ID で来た要求を、その ID のまま繋ぎ直す。クライアントの initialize は
    /// もう手元に無いので、ブリッジが最小の handshake を代わりに行う。
    private func revive(_ sessionId: String, protocolVersion: String?) async throws -> Child {
        if let dead = children.removeValue(forKey: sessionId) {
            terminate(dead)
        }
        let child = try spawn(sessionId: sessionId)
        children[sessionId] = child
        startSweeperIfNeeded()
        logger.info("\(command[0]) session revived: \(sessionId) (\(children.count) active)")

        let handshakeId = "host-bridge-revive-\(UUID().uuidString)"
        let handshake: [String: Any] = [
            "jsonrpc": "2.0",
            "id": handshakeId,
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion ?? "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "ios-dev-sandbox-host-bridge", "version": "1"],
            ],
        ]
        guard let message = try? JSONSerialization.data(withJSONObject: handshake) else {
            children.removeValue(forKey: sessionId)
            terminate(child)
            throw BackendError.badResponse("handshake を組めませんでした")
        }
        do {
            let response = try await forward(message, id: handshakeId, to: child)
            if let body = response.body, Self.isError(body) {
                throw BackendError.unreachable("\(command[0]) のセッションを繋ぎ直せませんでした")
            }
        } catch {
            children.removeValue(forKey: sessionId)
            terminate(child)
            throw error
        }
        let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        _ = try? await forward(initialized, id: nil, to: child)
        return child
    }

    private func openSession(with message: Data, id: Any?) async throws -> BackendResponse {
        let sessionId = UUID().uuidString
        let child = try spawn(sessionId: sessionId)
        children[sessionId] = child
        startSweeperIfNeeded()
        logger.info("\(command[0]) session opened: \(sessionId) (\(children.count) active)")

        let response: BackendResponse
        do {
            response = try await forward(message, id: id, to: child)
        } catch {
            children.removeValue(forKey: sessionId)
            terminate(child)
            throw error
        }
        if let body = response.body, Self.isError(body) {
            children.removeValue(forKey: sessionId)
            terminate(child)
            return BackendResponse(body: body, sessionId: nil)
        }
        return BackendResponse(body: response.body, sessionId: sessionId)
    }

    private func forward(_ message: Data, id: Any?, to child: Child) async throws -> BackendResponse {
        do {
            try child.stdin.write(contentsOf: message + Data("\n".utf8))
        } catch {
            throw BackendError.unreachable("child stdin closed: \(error.localizedDescription)")
        }

        guard let key = Self.idKey(id) else {
            return BackendResponse(body: nil, sessionId: nil)
        }
        let result = await withCheckedContinuation { continuation in
            child.waiters[key] = continuation
        }
        return BackendResponse(body: try result.get(), sessionId: nil)
    }

    private func spawn(sessionId: String) throws -> Child {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = command
        let toChild = Pipe()
        let fromChild = Pipe()
        process.standardInput = toChild
        process.standardOutput = fromChild
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            throw BackendError.unreachable("spawn failed: \(error.localizedDescription)")
        }
        logger.info("spawned: \(command.joined(separator: " ")) (pid \(process.processIdentifier))")

        let child = Child(process: process, stdin: toChild.fileHandleForWriting)
        let lines = AsyncLineSequence(handle: fromChild.fileHandleForReading)
        child.reader = Task { [weak self] in
            while let line = try? await lines.next() {
                await self?.dispatch(line, to: sessionId)
            }
            await self?.childExited(sessionId)
        }
        return child
    }

    private func dispatch(_ line: String, to sessionId: String) {
        let data = Data(line.utf8)
        guard let child = children[sessionId],
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["result"] != nil || obj["error"] != nil,
              let key = Self.idKey(obj["id"]),
              let continuation = child.waiters.removeValue(forKey: key) else {
            return  // サーバー発の通知・リクエストは HTTP では押し出せないので捨てる
        }
        continuation.resume(returning: .success(data))
    }

    /// 子が自分で終了した場合。待たされたままのクライアントを解放し、登録から外す。
    private func childExited(_ sessionId: String) {
        guard let child = children.removeValue(forKey: sessionId) else { return }
        failWaiters(of: child, reason: "child exited while awaiting a response")
    }

    private func terminate(_ child: Child) {
        child.reader?.cancel()
        if child.isRunning {
            child.process.terminate()
        }
        failWaiters(of: child, reason: "session was closed")
    }

    private func failWaiters(of child: Child, reason: String) {
        for continuation in child.waiters.values {
            continuation.resume(returning: .failure(.unreachable(reason)))
        }
        child.waiters = [:]
    }

    private func startSweeperIfNeeded() {
        guard sweeper == nil else { return }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await self?.sweepIdleSessions()
            }
        }
    }

    private func sweepIdleSessions() {
        let now = Date()
        for (id, child) in children
        where now.timeIntervalSince(child.lastActivity) > Self.idleTimeout || !child.isRunning {
            children.removeValue(forKey: id)
            terminate(child)
            logger.info("\(command[0]) session reaped: \(id) (\(children.count) active)")
        }
    }

    private static func isError(_ body: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return obj["error"] != nil
    }

    /// 待機表の鍵。型を接頭辞で区別し、1 と "1" を衝突させない。
    private static func idKey(_ id: Any?) -> String? {
        switch id {
        case let s as String: return "s:" + s
        case let n as NSNumber: return "n:" + n.stringValue
        default: return nil
        }
    }
}

/// FileHandle から行単位で読む。readabilityHandler は使わず、専用スレッドの
/// ブロッキング read を continuation で橋渡しする。
final class AsyncLineSequence: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private let queue = DispatchQueue(label: "host-bridge.reader")

    init(handle: FileHandle) {
        self.handle = handle
    }

    func next() async throws -> String? {
        while true {
            if let index = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer.prefix(upTo: index)
                buffer.removeSubrange(...index)
                if line.isEmpty { continue }
                return String(data: line, encoding: .utf8)
            }
            let chunk: Data = await withCheckedContinuation { continuation in
                queue.async { continuation.resume(returning: self.handle.availableData) }
            }
            if chunk.isEmpty { return nil }  // EOF
            buffer.append(chunk)
        }
    }
}
