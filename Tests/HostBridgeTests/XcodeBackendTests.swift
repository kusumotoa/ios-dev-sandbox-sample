import Foundation
import Logging
import Synchronization
import Testing
@testable import HostBridge

/// mcpbridge の代わり。要求の id をそのまま返し、どの接続が受けたかを数える。
private final class EchoConnection: MCPBridgeConnection, @unchecked Sendable {
    let label: Int
    private let stream: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let queue = DispatchQueue(label: "echo")

    init(label: Int) {
        self.label = label
        (stream, continuation) = AsyncStream<Data>.makeStream(of: Data.self)
    }

    func start() throws {}
    func messages() -> AsyncStream<Data> { stream }

    func send(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] else { return }
        // 応答には自分の label を載せる。取り違えを検出できる。
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": ["from": label]]
        let response = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        queue.async { self.continuation.yield(response) }
    }

    func terminate() { continuation.finish() }
}

/// Mutex は noncopyable なのでタプルに入れられない。数えるだけの箱を用意する。
private final class SpawnCounter: Sendable {
    private let storage = Mutex(0)

    func next() -> Int {
        storage.withLock { value -> Int in
            value += 1
            return value
        }
    }

    var count: Int { storage.withLock { $0 } }
}

@Suite("Xcode MCP の中継")
struct XcodeBackendTests {
    private func makeBackend() -> (backend: XcodeBackend, spawns: SpawnCounter) {
        let counter = SpawnCounter()
        let backend = XcodeBackend(logger: Logger(label: "xcode-backend-tests")) { _ in
            EchoConnection(label: counter.next())
        }
        return (backend, counter)
    }

    private func initialize(_ backend: XcodeBackend, id: Int) async throws -> (session: String?, from: Int?) {
        let message = Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{}}"#.utf8)
        let response = try await backend.send(message, sessionId: nil, protocolVersion: nil)
        return (response.sessionId, from(response.body))
    }

    private func from(_ body: Data?) -> Int? {
        guard let body, let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let result = obj["result"] as? [String: Any] else { return nil }
        return result["from"] as? Int
    }

    @Test(.timeLimit(.minutes(1))) func initializeOpensADistinctSessionPerClient() async throws {
        let (backend, counter) = makeBackend()
        let a = try await initialize(backend, id: 1)
        let b = try await initialize(backend, id: 1)

        #expect(a.session != nil)
        #expect(b.session != nil)
        #expect(a.session != b.session)
        // クライアントごとに mcpbridge が 1 つ立つ。共有すると取り違えが起きる。
        #expect(counter.count == 2)
        #expect(a.from != b.from)
    }

    /// 2 クライアントが同じ id を同時に使っても、応答は自分の mcpbridge から返る。
    /// 1 本共有だった実装では、片方が相手の応答を受け取るか、永久に待たされた。
    @Test(.timeLimit(.minutes(1))) func concurrentClientsSharingRequestIdsDoNotCross() async throws {
        let (backend, _) = makeBackend()
        let a = try await initialize(backend, id: 1)
        let b = try await initialize(backend, id: 1)
        let sessionA = try #require(a.session)
        let sessionB = try #require(b.session)
        let labelA = try #require(a.from)
        let labelB = try #require(b.from)

        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        async let responseA = backend.send(request, sessionId: sessionA, protocolVersion: nil)
        async let responseB = backend.send(request, sessionId: sessionB, protocolVersion: nil)
        let (gotA, gotB) = try await (responseA, responseB)

        #expect(from(gotA.body) == labelA)
        #expect(from(gotB.body) == labelB)
    }

    @Test(.timeLimit(.minutes(1))) func requestsWithoutASessionIdAreRejected() async throws {
        let (backend, _) = makeBackend()
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)

        await #expect(throws: BackendError.self) {
            _ = try await backend.send(request, sessionId: nil, protocolVersion: nil)
        }
    }

    /// idle sweep で回収されたあとも、クライアントは同じ ID を送り続ける。エラーではなく
    /// 繋ぎ直して応答する（そうしないと /mcp が connected のまま呼び出しだけ失敗する）。
    @Test(.timeLimit(.minutes(1))) func unknownSessionIsRevivedUnderTheSameId() async throws {
        let (backend, _) = makeBackend()
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)

        let got = try await backend.send(request, sessionId: "swept-session", protocolVersion: nil)
        #expect(got.body != nil)
        // 同じ ID で続けて呼べる（毎回作り直さない）。
        let again = try await backend.send(request, sessionId: "swept-session", protocolVersion: nil)
        #expect(again.body != nil)
    }

    @Test(.timeLimit(.minutes(1))) func endSessionReleasesTheBridge() async throws {
        let (backend, _) = makeBackend()
        let session = try #require(try await initialize(backend, id: 1).session)
        await backend.endSession(session)

        // 解放したセッションも、次の要求では繋ぎ直される。
        let request = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#.utf8)
        let got = try await backend.send(request, sessionId: session, protocolVersion: nil)
        #expect(got.body != nil)
    }
}
