import Foundation
import Logging
import Testing

@testable import HostBridge

@Suite("MCP サーバーの認可とトークン")
struct OAuthTests {
    private func store(_ tokens: OAuthTokens?) throws -> String {
        let dir = NSTemporaryDirectory() + "oauth-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let tokens {
            try OAuthFlow.write(tokens, to: dir + "/probe.json")
        }
        return dir
    }

    private func provider(_ dir: String) -> OAuthTokenProvider {
        OAuthTokenProvider(
            serverName: "probe",
            mcpURL: URL(string: "https://example.invalid/mcp")!,
            storeDir: dir,
            logger: Logger(label: "oauth-tests"))
    }

    @Test func expiryLeavesAMinuteOfHeadroom() {
        let base = OAuthTokens(
            accessToken: "a", refreshToken: nil, expiresAt: nil,
            clientId: "c", tokenEndpoint: "https://example.invalid/token")
        #expect(!base.isExpired, "期限なしは失効扱いにしない")

        var soon = base
        soon.expiresAt = Date().addingTimeInterval(30)
        #expect(soon.isExpired, "30 秒後に切れるなら、使う前に更新する")

        var later = base
        later.expiresAt = Date().addingTimeInterval(600)
        #expect(!later.isExpired)
    }

    // 鍵が無いときと更新できないときで、案内するコマンドが違ってはいけない。
    // どちらもブラウザでの認可が要るので、mcp-auth を案内する。
    @Test func unauthorizedTellsTheUserToRunMcpAuth() async throws {
        let dir = try store(nil)
        do {
            _ = try await provider(dir).accessToken()
            Issue.record("エラーになるべき")
        } catch {
            #expect(error.localizedDescription.contains("mcp-auth probe"))
        }
    }

    @Test func missingRefreshTokenTellsTheUserToRunMcpAuth() async throws {
        let dir = try store(OAuthTokens(
            accessToken: "expired", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(-60),
            clientId: "c", tokenEndpoint: "https://example.invalid/token"))
        do {
            _ = try await provider(dir).accessToken()
            Issue.record("エラーになるべき")
        } catch {
            #expect(error.localizedDescription.contains("mcp-auth probe"))
        }
    }

    // リフレッシュトークンがあっても token endpoint に拒否される（＝失効した）場合。
    // postForm の汎用エラーのままでは、何をすればよいか伝わらない。
    @Test func rejectedRefreshTellsTheUserToRunMcpAuth() async throws {
        let dir = try store(OAuthTokens(
            accessToken: "expired", refreshToken: "dead",
            expiresAt: Date().addingTimeInterval(-60),
            clientId: "c", tokenEndpoint: "https://127.0.0.1:1/token"))
        do {
            _ = try await provider(dir).accessToken()
            Issue.record("エラーになるべき")
        } catch {
            #expect(error.localizedDescription.contains("mcp-auth probe"))
        }
    }

    // MARK: - auth: token（事前発行したトークンをファイルから読む）

    private func tokenFile(_ contents: String?) throws -> String {
        let dir = NSTemporaryDirectory() + "token-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let contents {
            try contents.write(toFile: dir + "/probe", atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func staticTokenIsReadAndTrimmed() async throws {
        let dir = try tokenFile("ghp_example\n")
        let sut = StaticTokenProvider(serverName: "probe", path: dir + "/probe")
        #expect(try await sut.accessToken() == "ghp_example")
    }

    @Test func missingStaticTokenNamesTheRegisterCommand() async throws {
        let dir = try tokenFile(nil)
        let sut = StaticTokenProvider(serverName: "probe", path: dir + "/probe")
        await #expect(throws: BackendError.self) { try await sut.accessToken() }
        do {
            _ = try await sut.accessToken()
        } catch let error as BackendError {
            #expect(error.errorDescription?.contains("ios-dev-sandbox mcp-token probe") == true)
        }
    }

    @Test func blankStaticTokenIsRejected() async throws {
        let dir = try tokenFile("   \n")
        let sut = StaticTokenProvider(serverName: "probe", path: dir + "/probe")
        await #expect(throws: BackendError.self) { try await sut.accessToken() }
    }

    /// 401 のあとに差し替えたトークンを、ブリッジを再起動せずに拾う。
    @Test func forceRefreshRereadsTheFile() async throws {
        let dir = try tokenFile("old")
        let sut = StaticTokenProvider(serverName: "probe", path: dir + "/probe")
        #expect(try await sut.accessToken() == "old")
        try "new".write(toFile: dir + "/probe", atomically: true, encoding: .utf8)
        #expect(try await sut.accessToken(forceRefresh: true) == "new")
    }

    // 認可サーバーの応答や保存済みトークンに変な文字列が入っていても、ブリッジは
    // 落ちてはいけない。全サンドボックスがこの 1 プロセスを共有している。
    @Test(arguments: ["", "not a url", "/relative/only", "ほげ", "http://"])
    func 壊れたエンドポイントはエラーになる(_ bad: String) {
        #expect(throws: BackendError.self) {
            _ = try OAuthFlow.requireURL(bad, "token endpoint")
        }
    }

    @Test func まともなエンドポイントは通る() throws {
        let url = try OAuthFlow.requireURL("https://example.invalid/token", "token endpoint")
        #expect(url.host == "example.invalid")
    }

    // 失効したトークンの更新先が壊れていたときに、crash ではなくエラーで返ること。
    // URL(string:) は "not a url" を通してしまうので、確実に nil になる空文字も試す。
    @Test(arguments: ["", "not a url", "/relative/only"])
    func 更新先が壊れていても落ちない(_ bad: String) async throws {
        let dir = try store(OAuthTokens(
            accessToken: "a", refreshToken: "r", expiresAt: Date().addingTimeInterval(-60),
            clientId: "c", tokenEndpoint: bad))
        await #expect(throws: BackendError.self) {
            _ = try await provider(dir).accessToken()
        }
    }
}
