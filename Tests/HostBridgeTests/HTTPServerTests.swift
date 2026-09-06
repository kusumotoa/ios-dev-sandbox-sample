import Foundation
import Logging
import Testing

@testable import HostBridge

@Suite("HTTP サーバー")
struct HTTPServerTests {
    private func startEchoServer() async throws -> (base: URL, task: Task<Void, Error>) {
        let server = try HTTPServer(
            host: "127.0.0.1", port: 0,
            handler: { request in
                switch (request.method, request.path) {
                case ("GET", "/ping"):
                    return .json(200, Data(#"{"pong":true}"#.utf8))
                case ("POST", "/echo"):
                    return .json(200, request.body, extraHeaders: [("X-Echo-Header", request.header("X-Probe") ?? "")])
                default:
                    return .json(404, Data(#"{"bridgeError":"unknown"}"#.utf8))
                }
            },
            logger: Logger(label: "http-server-tests"))
        let task = Task { try await server.run() }
        for _ in 0..<100 {
            if server.boundPort != 0 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(server.boundPort != 0)
        return (URL(string: "http://127.0.0.1:\(server.boundPort)")!, task)
    }

    /// URLSession は不正な Content-Length を送れないので、生の要求行を流して
    /// ステータス行だけ読む。
    private func rawStatus(to base: URL, head: String) async throws -> Int {
        let handle = try await withCheckedThrowingContinuation { (c: CheckedContinuation<FileHandle, Error>) in
            DispatchQueue.global().async {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_addr.s_addr = inet_addr("127.0.0.1")
                addr.sin_port = UInt16(base.port!).bigEndian
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                if ok == 0 {
                    // 応答を返さない実装だとここで永久に待つ。読めなければ諦めて -1 にする。
                    var timeout = timeval(tv_sec: 5, tv_usec: 0)
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                               socklen_t(MemoryLayout<timeval>.size))
                    c.resume(returning: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
                } else {
                    close(fd)
                    c.resume(throwing: BackendError.unreachable("connect failed"))
                }
            }
        }
        try handle.write(contentsOf: Data(head.utf8))
        let response = String(decoding: handle.availableData, as: UTF8.self)
        try? handle.close()
        let fields = response.split(separator: " ")
        guard fields.count > 1, let status = Int(fields[1]) else { return -1 }
        return status
    }

    @Test func 基本の往復とヘッダの大文字小文字() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }

        let (pong, pongResponse) = try await URLSession.shared.data(from: base.appendingPathComponent("ping"))
        #expect((pongResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: pong, as: UTF8.self) == #"{"pong":true}"#)

        var request = URLRequest(url: base.appendingPathComponent("echo"))
        request.httpMethod = "POST"
        request.httpBody = Data("こんにちは".utf8)
        request.setValue("abc", forHTTPHeaderField: "x-probe")
        let (echoed, echoResponse) = try await URLSession.shared.data(for: request)
        #expect(String(decoding: echoed, as: UTF8.self) == "こんにちは")
        #expect((echoResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Echo-Header") == "abc")
    }

    @Test func 同一接続で連続リクエストできる() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        for index in 0..<5 {
            var request = URLRequest(url: base.appendingPathComponent("echo"))
            request.httpMethod = "POST"
            request.httpBody = Data("\(index)".utf8)
            let (data, _) = try await URLSession.shared.data(for: request)
            #expect(String(decoding: data, as: UTF8.self) == "\(index)")
        }
    }

    @Test func chunkedは411で拒否する() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        var request = URLRequest(url: base.appendingPathComponent("echo"))
        request.httpMethod = "POST"
        request.httpBodyStream = InputStream(data: Data("stream".utf8))
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 411)
    }

    // 負の Content-Length は認証より手前の解析で prefix(-1) に届き、全サンドボックス
    // 共有のブリッジを落とせた。
    @Test func 負のContentLengthは400で拒否する() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        let status = try await rawStatus(
            to: base,
            head: "POST /echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: -1\r\n\r\n")
        #expect(status == 400)
    }

    @Test func 上限超えのボディは413で拒否する() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        var request = URLRequest(url: base.appendingPathComponent("echo"))
        request.httpMethod = "POST"
        request.httpBody = Data(count: HTTPServer.maxBodyBytes + 1)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 413)
    }

    // 読めない Content-Length を 0 に倒すと、ボディが次のリクエストとして解釈される。
    // 手前にプロキシが挟まると、そこを通せなかった要求を通せてしまう。
    @Test(arguments: ["abc", "0x10", "1 0", "", "+5", "-1"])
    func 読めないContentLengthは400(_ bad: String) async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        let status = try await rawStatus(to: base, head:
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: \(bad)\r\n\r\nBODY")
        #expect(status == 400, "Content-Length: '\(bad)' を通してはいけない")
    }

    // 食い違う Content-Length が 2 つ来たとき、後勝ちで採るとボディの残りが
    // 次のリクエストになる。
    @Test func 食い違うContentLengthは400() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        let status = try await rawStatus(to: base, head:
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nContent-Length: 0\r\n\r\nBODY")
        #expect(status == 400)
    }

    // 同じ値が 2 つなら曖昧さは無いので通す。
    @Test func 同じContentLengthが2つなら通る() async throws {
        let (base, task) = try await startEchoServer()
        defer { task.cancel() }
        let status = try await rawStatus(to: base, head:
            "POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\nBODY")
        #expect(status == 200)
    }
}
