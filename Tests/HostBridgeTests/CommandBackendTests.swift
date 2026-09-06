import Foundation
import Logging
import Testing

@testable import HostBridge

@Suite("stdio MCP サーバーの中継")
struct CommandBackendTests {
    // 応答を id で引く待機表の検査。stub は受けたリクエストの params.delay だけ
    // 待ってから同じ id で答える stdio サーバー。
    private func makeBackend() -> CommandBackend {
        let stub = """
        import sys, json, threading, time, os
        def answer(req):
            time.sleep(req.get("params", {}).get("delay", 0))
            out = {"jsonrpc": "2.0", "id": req["id"], "result": {"echo": req["id"], "pid": os.getpid()}}
            if req.get("method") == "initialize":
                out["result"] = {"serverInfo": {"name": "stub"}, "pid": os.getpid()}
            print(json.dumps(out), flush=True)
        for line in sys.stdin:
            req = json.loads(line)
            if "id" not in req:
                continue
            threading.Thread(target=answer, args=(req,)).start()
        """
        return CommandBackend(
            command: ["python3", "-u", "-c", stub],
            logger: Logger(label: "command-backend-tests"))
    }

    private func request(_ id: Int, delay: Double = 0) -> Data {
        Data(#"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"delay":\#(delay)}}"#.utf8)
    }

    /// initialize でセッションを開き、その id と子の pid を返す。
    private func open(_ backend: CommandBackend, id: Int = 1) async throws -> (session: String?, pid: Int?) {
        let initialize = #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{}}"#
        let response = try await backend.send(Data(initialize.utf8), sessionId: nil, protocolVersion: nil)
        return (response.sessionId, pid(of: response))
    }

    private func pid(of response: BackendResponse) -> Int? {
        guard let body = response.body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let result = obj["result"] as? [String: Any] else { return nil }
        return result["pid"] as? Int
    }

    private func echoedId(_ response: BackendResponse) -> Int? {
        guard let body = response.body,
              let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return nil }
        return obj["id"] as? Int
    }

    // actor は await 中に再入する。先発（遅い）と後発（速い）が同時に飛んでも、
    // それぞれ自分の id の応答を受け取ること。行を早い者勝ちで読む方式だと、
    // 後発が先発の応答を消費して落とす。
    @Test func concurrentRequestsGetTheirOwnResponses() async throws {
        let backend = makeBackend()
        let session = try #require(try await open(backend).session)
        async let slow = backend.send(request(1, delay: 0.4), sessionId: session, protocolVersion: nil)
        try await Task.sleep(for: .milliseconds(50))
        async let fast = backend.send(request(2), sessionId: session, protocolVersion: nil)
        let (first, second) = try await (slow, fast)
        #expect(echoedId(first) == 1)
        #expect(echoedId(second) == 2)
    }

    // クライアントごとに子プロセスが立つ。1 つを共有すると、どのクライアントも id を
    // 1 から振るため同時アクセスで応答が取り違えられる（実測で片方が空応答になった）。
    @Test func eachSessionGetsItsOwnChild() async throws {
        let backend = makeBackend()
        let a = try await open(backend)
        let b = try await open(backend)
        #expect(a.session != nil)
        #expect(a.session != b.session)
        #expect(a.pid != nil)
        #expect(a.pid != b.pid)
    }

    @Test func concurrentSessionsSharingRequestIdsDoNotCross() async throws {
        let backend = makeBackend()
        let a = try await open(backend)
        let b = try await open(backend)
        let sessionA = try #require(a.session)
        let sessionB = try #require(b.session)

        async let responseA = backend.send(request(5, delay: 0.3), sessionId: sessionA, protocolVersion: nil)
        async let responseB = backend.send(request(5), sessionId: sessionB, protocolVersion: nil)
        let (gotA, gotB) = try await (responseA, responseB)

        #expect(echoedId(gotA) == 5)
        #expect(echoedId(gotB) == 5)
        // それぞれ自分の子から返る。
        #expect(pid(of: gotA) == a.pid)
        #expect(pid(of: gotB) == b.pid)
    }

    @Test func commandRequestsWithoutASessionIdAreRejected() async throws {
        let backend = makeBackend()
        await #expect(throws: BackendError.self) {
            _ = try await backend.send(request(1), sessionId: nil, protocolVersion: nil)
        }
    }

    /// XcodeBackend と同じ契約。回収済みの ID はエラーにせず繋ぎ直す。
    @Test func commandUnknownSessionIsRevivedUnderTheSameId() async throws {
        let backend = makeBackend()
        let got = try await backend.send(request(1), sessionId: "swept-session", protocolVersion: nil)
        #expect(got.body != nil)
        let again = try await backend.send(request(1), sessionId: "swept-session", protocolVersion: nil)
        #expect(again.body != nil)
    }

    @Test func endSessionTerminatesTheChild() async throws {
        let backend = makeBackend()
        let session = try #require(try await open(backend).session)
        await backend.endSession(session)
        await #expect(throws: BackendError.self) {
            _ = try await backend.send(request(2), sessionId: session, protocolVersion: nil)
        }
    }

    // 2 回目の initialize は再生ではなく新しいセッションになる。子を分けるので
    // プロトコル違反にならない。
    @Test func secondInitializeOpensAFreshSession() async throws {
        let backend = makeBackend()
        let again = try await open(backend, id: 99)
        #expect(again.session != nil)
        let response = try await backend.send(
            Data(#"{"jsonrpc":"2.0","id":99,"method":"initialize","params":{}}"#.utf8),
            sessionId: nil, protocolVersion: nil)
        #expect(echoedId(response) == 99)
        let obj = (try? JSONSerialization.jsonObject(with: response.body ?? Data())) as? [String: Any]
        let server = ((obj?["result"] as? [String: Any])?["serverInfo"] as? [String: Any])?["name"] as? String
        #expect(server == "stub")
    }

    // 子が応答前に死んだら、待っている全リクエストがエラーで返ること（永久待ちにしない）。
    @Test func childDeathFailsPendingRequests() async {
        let backend = CommandBackend(
            command: ["sh", "-c", "read _line; exit 0"],
            logger: Logger(label: "command-backend-tests"))
        // initialize でセッションを開く前に子が死ぬので、ここで既にエラーになる。
        do {
            _ = try await backend.send(
                Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#.utf8),
                sessionId: nil, protocolVersion: nil)
            Issue.record("エラーになるべき応答が返った")
        } catch {}
    }
}
