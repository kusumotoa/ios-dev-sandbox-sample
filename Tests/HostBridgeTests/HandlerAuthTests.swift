import Foundation
import Logging
import Testing

@testable import HostBridge

// 認可の判断は全部 makeHostBridgeHandler に集まっているのに、ここを通るテストが
// 無かった。ToolGate の単体は別途あるが、それが実際に呼ばれるかは誰も見ていない。

private let logger = Logger(label: "handler-auth-tests")

@Suite("ブリッジの受け口")
struct HandlerAuthTests {
    private func handler() -> HTTPServer.Handler {
        let cli = BridgeConfiguration(
            commands: [AllowedCommand(name: "probe", path: "/bin/echo", allowedSubcommands: nil)])
        return makeHostBridgeHandler(
            cli: cli, cliWarnings: [], timeout: 5,
            mcp: ProxyConfiguration(schemaVersion: 1, servers: [:]),
            oauthDir: NSTemporaryDirectory(), tokenDir: NSTemporaryDirectory(), logger: logger)
    }

    private func request(_ method: String, _ path: String,
                         headers: [String: String] = [:], body: Data = Data()) -> HTTPRequest {
        HTTPRequest(method: method, path: path,
                    headers: headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value },
                    body: body)
    }

    @Test func healthは通る() async {
        let response = await handler()(request("GET", "/health"))
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8)?.contains("probe") == true)
    }

    // Origin の検査が /health より後ろにあると、ブラウザの持つページが allowlist を読める。
    @Test func Origin付きはhealthでも弾く() async {
        let response = await handler()(request("GET", "/health", headers: ["Origin": "https://evil.example"]))
        #expect(response.status == 403)
        #expect(String(data: response.body, encoding: .utf8)?.contains("probe") != true)
    }

    // Origin は /exec と /mcp にも効く。ブラウザからの実行経路を塞ぐ唯一の検査。
    @Test func Origin付きはexecも弾く() async {
        let body = #"{"command":"probe","args":["ok"]}"#.data(using: .utf8)!
        #expect(await handler()(request("POST", "/exec",
            headers: ["Origin": "https://evil.example"], body: body)).status == 403)
    }

    @Test func execはallowlistのコマンドを実行する() async {
        let body = #"{"command":"probe","args":["ok"]}"#.data(using: .utf8)!
        let response = await handler()(request("POST", "/exec", body: body))
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8)?.contains("ok") == true)
    }

    @Test func allowlistにないコマンドは403() async {
        let body = #"{"command":"rm","args":["-rf","/"]}"#.data(using: .utf8)!
        #expect(await handler()(request("POST", "/exec", body: body)).status == 403)
    }

    @Test func 知らないMCPサーバーは404() async {
        #expect(await handler()(request("POST", "/mcp/nosuch")).status == 404)
    }

    // パスにスラッシュを含む名前で servers の外へ出られないこと。
    @Test func MCPのサーバー名にパスを混ぜられない() async {
        #expect(await handler()(request("POST", "/mcp/../exec")).status == 404)
    }

    // バッチを通すと、中の tools/call を ToolGate が検査できないまま素通りする。
    @Test func JSONRPCのバッチは拒否する() async {
        let batch = #"[{"jsonrpc":"2.0","id":1,"method":"tools/list"}]"#.data(using: .utf8)!
        let response = await handler()(request("POST", "/mcp/nosuch", body: batch))
        #expect(response.status == 404 || response.status == 400)
    }
}
