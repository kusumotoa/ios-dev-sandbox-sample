import Foundation
import Logging

/// MCP セッションごとに mcpbridge を 1 つ持つ。1 本を共有すると、どのクライアントも
/// JSON-RPC の id を 1 から振るため、複数プロジェクトを同時に開いたときに応答が
/// 取り違えられる（片方に届かない）。
actor XcodeBackend: MCPBackend {
    /// 使われなくなったセッションを畳むまでの猶予。ビルドやテストの待ち時間より長く。
    static let idleTimeout: TimeInterval = 30 * 60

    private final class Session {
        let supervisor: MCPBridgeSupervisor
        var reader: Task<Void, Never>?
        var waiters: [JSONRPCId: CheckedContinuation<Data, Never>] = [:]
        var lastActivity = Date()

        init(supervisor: MCPBridgeSupervisor) {
            self.supervisor = supervisor
        }
    }

    private let logger: Logger
    private let makeConnection: @Sendable (String?) -> MCPBridgeConnection
    private var sessions: [String: Session] = [:]
    private var sweeper: Task<Void, Never>?

    init(
        logger: Logger,
        makeConnection: (@Sendable (String?) -> MCPBridgeConnection)? = nil
    ) {
        self.logger = logger
        self.makeConnection = makeConnection ?? { developerDir in
            MCPBridgeProcess(xcrunPath: "/usr/bin/xcrun", developerDir: developerDir, logger: logger)
        }
    }

    func send(_ message: Data, sessionId: String?, protocolVersion: String?) async throws -> BackendResponse {
        guard let peek = JSONRPCPeek(data: message) else {
            throw BackendError.badResponse("unparseable JSON-RPC message")
        }

        if peek.method == "initialize" {
            return try await openSession(with: message, peek: peek)
        }

        guard let sessionId else {
            throw BackendError.badResponse(
                "Mcp-Session-Id がありません。initialize からやり直してください")
        }
        let session: Session
        if let existing = sessions[sessionId] {
            session = existing
        } else {
            session = try await revive(sessionId, protocolVersion: protocolVersion)
        }
        session.lastActivity = Date()
        return await forward(message, peek: peek, to: session, id: sessionId)
    }

    func endSession(_ sessionId: String?) async {
        guard let sessionId, let session = sessions.removeValue(forKey: sessionId) else { return }
        await close(session, id: sessionId)
    }


    /// supervisor を 1 つ起こして sessionId に結び付ける。initialize の送出は呼び手が行う。
    private func spawnSession(id sessionId: String, verb: String) async throws -> Session {
        let developerDir = ProcessInfo.processInfo.environment["IOS_DEV_SANDBOX_DEVELOPER_DIR"]
        let supervisor = MCPBridgeSupervisor(
            selection: .from(argument: developerDir), logger: logger, makeConnection: makeConnection)
        do {
            try await supervisor.start()
        } catch {
            throw BackendError.unreachable("mcpbridge failed to start: \(error.localizedDescription)")
        }

        let session = Session(supervisor: supervisor)
        session.reader = Task { [weak self] in
            for await message in supervisor.messages {
                await self?.dispatch(message, to: sessionId)
            }
        }
        sessions[sessionId] = session
        startSweeperIfNeeded()
        logger.info("xcode session \(verb): \(sessionId) (\(sessions.count) active)")
        return session
    }

    /// 回収済みの ID で来た要求を、その ID のまま繋ぎ直す。クライアントの initialize は
    /// もう手元に無いので、ブリッジが最小の handshake を代わりに行う。
    private func revive(_ sessionId: String, protocolVersion: String?) async throws -> Session {
        let session = try await spawnSession(id: sessionId, verb: "revived")
        let handshake = Self.initializeMessage(protocolVersion: protocolVersion)
        guard let peek = JSONRPCPeek(data: handshake) else {
            throw BackendError.badResponse("handshake を組めませんでした")
        }
        let response = await forward(handshake, peek: peek, to: session, id: sessionId)
        if let body = response.body, Self.isError(body) {
            sessions.removeValue(forKey: sessionId)
            await close(session, id: sessionId)
            throw BackendError.unreachable("xcode のセッションを繋ぎ直せませんでした")
        }
        let initialized = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
        if let notice = JSONRPCPeek(data: initialized) {
            _ = await forward(initialized, peek: notice, to: session, id: sessionId)
        }
        return session
    }

    /// ブリッジ発の initialize。id はクライアントのものと衝突しない形にする。
    private static func initializeMessage(protocolVersion: String?) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": "host-bridge-revive-\(UUID().uuidString)",
            "method": "initialize",
            "params": [
                "protocolVersion": protocolVersion ?? "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "ios-dev-sandbox-host-bridge", "version": "1"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    private func openSession(with message: Data, peek: JSONRPCPeek) async throws -> BackendResponse {
        let sessionId = UUID().uuidString
        let session = try await spawnSession(id: sessionId, verb: "opened")

        let response = await forward(message, peek: peek, to: session, id: sessionId)
        if let body = response.body, Self.isError(body) {
            sessions.removeValue(forKey: sessionId)
            await close(session, id: sessionId)
            return BackendResponse(body: body, sessionId: nil)
        }
        return BackendResponse(body: response.body, sessionId: sessionId)
    }

    private func forward(
        _ message: Data, peek: JSONRPCPeek, to session: Session, id sessionId: String
    ) async -> BackendResponse {
        guard let id = peek.id else {
            await session.supervisor.forward(message, method: peek.method, id: nil)
            return BackendResponse(body: nil, sessionId: nil)
        }
        let supervisor = session.supervisor
        let method = peek.method
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            session.waiters[id] = continuation
            Task { await supervisor.forward(message, method: method, id: id) }
        }
        return BackendResponse(body: response, sessionId: nil)
    }

    private func dispatch(_ message: Data, to sessionId: String) {
        guard let session = sessions[sessionId],
              let peek = JSONRPCPeek(data: message), let id = peek.id, peek.method == nil,
              let continuation = session.waiters.removeValue(forKey: id) else {
            return  // サーバー発の通知は HTTP では押し出せないので捨てる
        }
        continuation.resume(returning: message)
    }

    private func close(_ session: Session, id sessionId: String) async {
        session.reader?.cancel()
        await session.supervisor.shutdown()
        for (_, continuation) in session.waiters {
            continuation.resume(returning: Self.errorBody("xcode session was closed"))
        }
        session.waiters.removeAll()
        logger.info("xcode session closed: \(sessionId) (\(sessions.count) active)")
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

    private func sweepIdleSessions() async {
        let now = Date()
        for (id, session) in sessions where now.timeIntervalSince(session.lastActivity) > Self.idleTimeout {
            sessions.removeValue(forKey: id)
            logger.info("xcode session idle for \(Int(Self.idleTimeout))s: \(id)")
            await close(session, id: id)
        }
    }

    private static func isError(_ body: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return false }
        return obj["error"] != nil
    }

    private static func errorBody(_ message: String) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0", "id": NSNull(),
            "error": ["code": -32000, "message": message],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}
