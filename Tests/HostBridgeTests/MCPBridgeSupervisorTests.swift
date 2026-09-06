import Foundation
import Logging
import Synchronization
import Testing
@testable import HostBridge

private let xcodeA = "/Applications/Xcode-A.app/Contents/Developer"
private let xcodeB = "/Applications/Xcode-B.app/Contents/Developer"

/// actor では代われない。`MCPBridgeConnection` と `XcodeSelection.readLink` が
/// 同期のため。
private final class LockedBox<Value: Sendable>: Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) { storage = Mutex(value) }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}

private final class FakeConnection: MCPBridgeConnection, @unchecked Sendable {
    let developerDir: String?

    /// スーパーバイザーがこの接続へ書いたもの全て。順序どおり。
    let sent: AsyncStream<String>

    private let sentContinuation: AsyncStream<String>.Continuation
    private let received: AsyncStream<Data>
    private let receivedContinuation: AsyncStream<Data>.Continuation

    init(developerDir: String?) {
        self.developerDir = developerDir
        (sent, sentContinuation) = AsyncStream<String>.makeStream(of: String.self)
        (received, receivedContinuation) = AsyncStream<Data>.makeStream(of: Data.self)
    }

    func start() throws {}
    func messages() -> AsyncStream<Data> { received }
    func send(_ data: Data) { sentContinuation.yield(String(decoding: data, as: UTF8.self)) }
    func terminate() { receivedContinuation.finish() }

    /// mcpbridge が stdout で応答する様子を模す。
    func emit(_ json: String) { receivedContinuation.yield(Data(json.utf8)) }
}

private struct Harness {
    let link = LockedBox<String?>(xcodeA)
    let spawned = LockedBox<[FakeConnection]>([])
    let supervisor: MCPBridgeSupervisor

    init(pinnedTo pin: String? = nil) {
        let link = self.link
        let spawned = self.spawned
        supervisor = MCPBridgeSupervisor(
            selection: pin.map { XcodeSelection.pinned($0) }
                ?? .tracking(linkPath: "unused", readLink: { _ in link.value }),
            logger: Logger(label: "test")
        ) { developerDir in
            let connection = FakeConnection(developerDir: developerDir)
            spawned.value.append(connection)
            return connection
        }
    }

    func send(_ method: String, id: Int? = nil) async {
        let json = id.map { #"{"jsonrpc":"2.0","id":\#($0),"method":"\#(method)"}"# }
            ?? #"{"jsonrpc":"2.0","method":"\#(method)"}"#
        await supervisor.forward(Data(json.utf8), method: method, id: id.map(JSONRPCId.int))
    }
}

private struct RestartScenario: Sendable, CustomTestStringConvertible {
    let label: String
    let pin: String?
    let movesLink: Bool
    let expectedSpawns: Int

    var testDescription: String { label }
}

@Suite("mcpbridge の起動と再起動")
struct MCPBridgeSupervisorTests {
    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            RestartScenario(label: "tracking, selection unchanged", pin: nil, movesLink: false, expectedSpawns: 1),
            RestartScenario(label: "tracking, selection moved", pin: nil, movesLink: true, expectedSpawns: 2),
            RestartScenario(label: "pinned, selection moved", pin: xcodeA, movesLink: true, expectedSpawns: 1),
        ]
    )
    private func restartsOnlyWhenATrackedSelectionMoves(scenario: RestartScenario) async throws {
        let harness = Harness(pinnedTo: scenario.pin)
        try await harness.supervisor.start()

        await harness.send("tools/list", id: 1)
        if scenario.movesLink { harness.link.value = xcodeB }
        await harness.send("tools/list", id: 2)

        let spawned = harness.spawned.value
        try #require(spawned.count == scenario.expectedSpawns)
        #expect(spawned[0].developerDir == xcodeA)
        if scenario.expectedSpawns == 2 {
            #expect(spawned[1].developerDir == xcodeB)
        }

        await harness.supervisor.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func replaysHandshakeIntoTheReplacementBridge() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()

        await harness.send("initialize", id: 1)
        let original = try #require(harness.spawned.value.first)
        original.emit(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        let handshakeResponse = try #require(await toClient.next())
        #expect(String(decoding: handshakeResponse, as: UTF8.self).contains(#""id":1"#))
        await harness.send("notifications/initialized")

        harness.link.value = xcodeB
        await harness.send("tools/list", id: 2)

        try #require(harness.spawned.value.count == 2)
        let replacement = harness.spawned.value[1]
        var toBridge = replacement.sent.makeAsyncIterator()
        #expect(try #require(await toBridge.next()).contains(#""method":"initialize""#))
        #expect(try #require(await toBridge.next()).contains("notifications/initialized"))
        #expect(try #require(await toBridge.next()).contains(#""id":2"#))

        // 最初のブリッジが既に応答済みなので、差し替え後の応答は握り潰す。
        replacement.emit(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        replacement.emit(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#)
        let next = try #require(await toClient.next())
        #expect(String(decoding: next, as: UTF8.self).contains(#""id":2"#))

        await harness.supervisor.shutdown()
    }

    // ツールの絞り込みは ProxyApp の共通経路（ToolGate）に移った。supervisor は素通しする。
    @Test(.timeLimit(.minutes(1))) func passesToolsListThroughUnfiltered() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()

        await harness.send("tools/list", id: 1)
        try #require(harness.spawned.value.first)
            .emit(#"{"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"BuildProject"},{"name":"XcodeCreateFile"}]}}"#)
        let response = String(decoding: try #require(await toClient.next()), as: UTF8.self)
        #expect(response.contains("BuildProject"))
        #expect(response.contains("XcodeCreateFile"))

        await harness.supervisor.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func respawnsAfterMcpbridgeExitsOnItsOwn() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()

        await harness.send("tools/call", id: 3)
        try #require(harness.spawned.value.first).terminate()

        // orphan エラーを待てば終了は観測済み。次のメッセージは必ず接続の無い状態を見る。
        let orphaned = String(decoding: try #require(await toClient.next()), as: UTF8.self)
        #expect(orphaned.contains(#""id":3"#))
        #expect(orphaned.contains(#""code":-32000"#))

        await harness.send("tools/list", id: 4)
        try #require(harness.spawned.value.count == 2)
        #expect(harness.spawned.value[1].developerDir == xcodeA)

        await harness.supervisor.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func reportsARejectedHandshakeInsteadOfHangingTheClient() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()

        await harness.send("initialize", id: 1)
        try #require(harness.spawned.value.first).emit(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        _ = await toClient.next()

        harness.link.value = xcodeB
        await harness.send("tools/list", id: 2)
        try #require(harness.spawned.value.count == 2)
        let replacement = harness.spawned.value[1]
        replacement.emit(#"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"bad protocolVersion"}}"#)
        replacement.emit(#"{"jsonrpc":"2.0","id":2,"result":{"tools":[]}}"#)

        // 順に消費されるので、id:2 が見えれば手前の拒否された握手は処理済み。
        _ = await toClient.next()

        await harness.send("tools/list", id: 5)
        let reported = String(decoding: try #require(await toClient.next()), as: UTF8.self)
        #expect(reported.contains(#""code":-32000"#))
        #expect(reported.contains("rejected the replayed initialize"))

        await harness.supervisor.shutdown()
    }

    @Test(.timeLimit(.minutes(1))) func failsRequestsTheReplacedBridgeWillNeverAnswer() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()

        await harness.send("tools/call", id: 7)
        harness.link.value = xcodeB
        await harness.send("tools/list", id: 8)

        let orphaned = String(decoding: try #require(await toClient.next()), as: UTF8.self)
        #expect(orphaned.contains(#""id":7"#))
        #expect(orphaned.contains(#""code":-32000"#))

        await harness.supervisor.shutdown()
    }

    @Test func trackingSelectionRereadsTheSymlinkEveryTime() {
        let link = LockedBox<String?>(xcodeA)
        let selection = XcodeSelection.tracking(linkPath: "unused", readLink: { _ in link.value })

        #expect(selection.resolve() == xcodeA)
        link.value = xcodeB
        #expect(selection.resolve() == xcodeB)
        link.value = nil
        #expect(selection.resolve() == nil)
    }

    @Test func pinnedSelectionIgnoresTheSymlink() {
        #expect(XcodeSelection.pinned(xcodeA).resolve() == xcodeA)
    }

    @Test(arguments: [nil, "", "follow", "Xcode.app"]) func onlyAnAbsolutePathPins(argument: String?) {
        guard case .tracking = XcodeSelection.from(argument: argument) else {
            Issue.record("\(argument ?? "nil") was treated as a pin")
            return
        }
    }

    @Test func anAbsolutePathPins() {
        #expect(XcodeSelection.from(argument: xcodeA).resolve() == xcodeA)
    }

    // pump は nonisolated（`spawn()` の注記）なので、メッセージは 1 通ずつ actor へ
    // 入り直す。順序はループが 1 通待つことで保たれ、実行機の共有によるのではない。
    @Test(.timeLimit(.minutes(1))) func messagesReachTheClientInTheOrderTheyWereEmitted() async throws {
        let harness = Harness()
        try await harness.supervisor.start()
        var toClient = harness.supervisor.messages.makeAsyncIterator()
        let bridge = try #require(harness.spawned.value.first)

        // 応答ではなく通知。method を持つので、突き合わせずそのまま転送される。
        let count = 200
        for n in 0..<count {
            bridge.emit(#"{"jsonrpc":"2.0","method":"notifications/message","params":{"n":\#(n)}}"#)
        }

        var seen: [Int] = []
        for _ in 0..<count {
            let data = try #require(await toClient.next())
            let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let params = try #require(object["params"] as? [String: Any])
            seen.append(try #require(params["n"] as? Int))
        }

        #expect(seen == Array(0..<count))
        await harness.supervisor.shutdown()
    }

    // `spawn()` の `[weak self]` を守る。強参照だと、mcpbridge のストリームが開いて
    // いる限り自分の `pump` 経由で生き続ける。長命なプロキシでは永久を意味する。
    @Test(.timeLimit(.minutes(1))) func droppingTheSupervisorWithoutShutdownStillDeallocatesIt() async throws {
        weak var released: MCPBridgeSupervisor?
        do {
            let harness = Harness()
            try await harness.supervisor.start()
            released = harness.supervisor
            #expect(released != nil)
        }
        #expect(released == nil)
    }
}
