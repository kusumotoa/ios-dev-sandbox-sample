import Foundation
import Logging

/// `terminate()` は `messages()` を必ず終わらせること。張り替え前に流し切るのを待つ。
protocol MCPBridgeConnection: Sendable {
    func start() throws
    func messages() -> AsyncStream<Data>
    func send(_ data: Data)
    func terminate()
}

extension MCPBridgeProcess: MCPBridgeConnection {}

/// 呼び出し側から見えるストリームは 1 本で、再起動をまたいで続く。
actor MCPBridgeSupervisor {
    nonisolated let messages: AsyncStream<Data>

    private nonisolated let downstream: AsyncStream<Data>.Continuation
    private let selection: XcodeSelection
    private let makeConnection: @Sendable (String?) -> MCPBridgeConnection
    private let logger: Logger

    private var connection: MCPBridgeConnection?
    private var developerDir: String?
    private var pump: Task<Void, Never>?
    private var handshake = HandshakeRecorder()
    private var replayedInitializeId: JSONRPCId?
    private var inFlight: [JSONRPCId: String] = [:]
    private var failure: String?
    private var isShutDown = false

    /// 張り替えで終わったのか、mcpbridge が自分で死んだのかを区別する。
    private var generation = 0

    init(
        selection: XcodeSelection,
        logger: Logger,
        makeConnection: @escaping @Sendable (String?) -> MCPBridgeConnection
    ) {
        self.selection = selection
        self.logger = logger
        self.makeConnection = makeConnection

        let (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
        self.messages = stream
        self.downstream = continuation
    }

    func start() throws {
        developerDir = selection.resolve()
        try spawn()
    }

    func forward(_ message: Data, method: String?, id: JSONRPCId?) async {
        let replayed = await ensureConnection()
        handshake.record(message, method: method, id: id)

        if replayed, method == "initialize" || method == "notifications/initialized" {
            return
        }

        if let failure {
            if let id, let response = Self.errorResponse(id: id, code: -32000, message: failure) {
                downstream.yield(response)
            }
            return
        }

        if let id, let method {
            inFlight[id] = method
        }
        connection?.send(message)
    }

    func shutdown() async {
        isShutDown = true
        await teardown()
        downstream.finish()
    }


    /// - Returns: 新しく起動した mcpbridge に握手を再生したかどうか。
    private func ensureConnection() async -> Bool {
        let desired = selection.resolve() ?? developerDir
        guard connection == nil || desired != developerDir else { return false }

        if connection != nil {
            logger.info("xcode-select moved: \(developerDir ?? "unset") -> \(desired ?? "unset")")
            await teardown()
        }
        failInFlightRequests(reason: "mcpbridge was replaced")

        developerDir = desired
        do {
            try spawn()
        } catch {
            failure = "mcpbridge failed to start: \(error.localizedDescription)"
            logger.error("\(failure ?? "")")
            return false
        }
        failure = nil
        return replayHandshake()
    }

    private func spawn() throws {
        let connection = makeConnection(developerDir)
        try connection.start()
        self.connection = connection

        generation += 1
        let generation = generation
        pump = Task { [weak self] in
            for await message in connection.messages() {
                await self?.receive(message)
            }
            await self?.bridgeStreamEnded(generation: generation)
        }
    }

    private func teardown() async {
        generation += 1
        connection?.terminate()
        await pump?.value
        pump = nil
        connection = nil
    }

    /// 頼まないのに mcpbridge が終了した場合。接続を捨てると次のメッセージが差し替えを
    /// 起動する。放置すると無言で応答が返らない。
    private func bridgeStreamEnded(generation: Int) {
        guard generation == self.generation, !isShutDown else { return }
        logger.error("mcpbridge exited on its own; respawning on the next request")
        connection = nil
        failInFlightRequests(reason: "mcpbridge exited")
    }

    /// 差し替えた mcpbridge は前の仕事を知らないので、残すとクライアントが待ち続ける。
    private func failInFlightRequests(reason: String) {
        for (id, method) in inFlight {
            let message = "\(reason); retry \(method)"
            if let response = Self.errorResponse(id: id, code: -32000, message: message) {
                downstream.yield(response)
            }
        }
        inFlight.removeAll()
    }

    /// 応答を待たずに通知を送る。mcpbridge は stdin を順に読むので、再起動のきっかけに
    /// なったメッセージより前に置ける。待つとそれが握手の途中に割り込む。
    private func replayHandshake() -> Bool {
        guard let request = handshake.initializeRequest else { return false }
        replayedInitializeId = handshake.initializeId
        connection?.send(request)
        if let notification = handshake.initializedNotification {
            connection?.send(notification)
        }
        return true
    }

    private func receive(_ message: Data) {
        let peek = JSONRPCPeek(data: message)
        guard let id = peek?.id, peek?.method == nil else {
            downstream.yield(message)
            return
        }

        if id == replayedInitializeId {
            replayedInitializeId = nil
            if Self.isError(message) {
                failure = "the replacement mcpbridge rejected the replayed initialize"
                logger.error("\(failure ?? "")")
            }
            return
        }

        inFlight.removeValue(forKey: id)
        downstream.yield(message)
    }

    private static func isError(_ message: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: message),
              let payload = object as? [String: Any]
        else { return false }
        return payload["error"] != nil
    }

    private static func errorResponse(id: JSONRPCId, code: Int, message: String) -> Data? {
        let idValue: Any = switch id {
        case .int(let value): value
        case .string(let value): value
        }
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": idValue,
            "error": ["code": code, "message": message],
        ]
        return try? JSONSerialization.data(withJSONObject: payload)
    }
}
