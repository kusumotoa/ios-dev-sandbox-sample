import CommonCrypto
import Darwin
import Foundation
import Logging

struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
    let clientId: String
    let tokenEndpoint: String

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSinceNow < 60
    }
}

/// トークンは <oauth-dir>/<サーバー名>.json（0600）。claude-oauth-token と同じ流儀で
/// ファイルに置き、Keychain は使わない。
extension OAuthTokenProvider: MCPTokenProvider {}

actor OAuthTokenProvider {
    let serverName: String
    let mcpURL: URL
    let storeDir: String
    let logger: Logger

    init(serverName: String, mcpURL: URL, storeDir: String, logger: Logger) {
        self.serverName = serverName
        self.mcpURL = mcpURL
        self.storeDir = storeDir
        self.logger = logger
    }

    private var storePath: String { "\(storeDir)/\(serverName).json" }

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard var tokens = load() else {
            throw BackendError.unreachable(
                "'\(serverName)' は未認可です。ホストで 'ios-dev-sandbox mcp-auth \(serverName)' を実行してください")
        }
        if forceRefresh || tokens.isExpired {
            tokens = try await refresh(tokens)
            try save(tokens)
        }
        return tokens.accessToken
    }

    private func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        guard let refreshToken = tokens.refreshToken else {
            throw BackendError.unreachable(
                "'\(serverName)' のトークンが失効しました。'ios-dev-sandbox mcp-auth \(serverName)' で認可し直してください")
        }
        let form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": tokens.clientId,
        ]
        let payload: [String: Any]
        do {
            payload = try await OAuthFlow.postForm(try OAuthFlow.requireURL(tokens.tokenEndpoint, "token endpoint"), form: form)
        } catch {
            throw BackendError.unreachable(
                "'\(serverName)' のトークンを更新できませんでした。ホストで "
                + "'ios-dev-sandbox mcp-auth \(serverName)' を実行してブラウザで認可し直してください"
                + "（元のエラー: \(error.localizedDescription)）")
        }
        var updated = tokens
        updated.accessToken = payload["access_token"] as? String ?? tokens.accessToken
        if let newRefresh = payload["refresh_token"] as? String { updated.refreshToken = newRefresh }
        if let expiresIn = payload["expires_in"] as? Double { updated.expiresAt = Date().addingTimeInterval(expiresIn) }
        logger.info("'\(serverName)' のトークンをリフレッシュしました")
        return updated
    }

    private func load() -> OAuthTokens? {
        guard let data = FileManager.default.contents(atPath: storePath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(OAuthTokens.self, from: data)
    }

    private func save(_ tokens: OAuthTokens) throws {
        try OAuthFlow.write(tokens, to: storePath)
    }
}

/// RFC 9728/8414 discovery -> DCR -> PKCE 認可コードフロー。特定サービス向けの分岐は無い。
enum OAuthFlow {
    /// 認可サーバーの応答や保存済みトークンに入っていた文字列を URL にする。
    /// ブリッジは全サンドボックスで共有しているので、1 つのサーバーが変なものを
    /// 返しただけで落とすわけにいかない。
    static func requireURL(_ string: String, _ what: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil, url.host != nil else {
            throw BackendError.badResponse("\(what) が URL として読めません: \(string)")
        }
        return url
    }

    static func authorize(serverName: String, mcpURL: URL, storeDir: String) async throws {
        let metadata = try await discoverAuthorizationServer(for: mcpURL)
        guard let authorizationEndpoint = metadata["authorization_endpoint"] as? String,
              let tokenEndpoint = metadata["token_endpoint"] as? String else {
            throw BackendError.badResponse("認可サーバーのメタデータに endpoint がありません")
        }

        let callback = try CallbackServer()
        defer { callback.close() }
        let redirectURI = "http://127.0.0.1:\(callback.port)/callback"

        let clientId: String
        if let registration = metadata["registration_endpoint"] as? String {
            clientId = try await register(at: registration, redirectURI: redirectURI)
        } else {
            throw BackendError.badResponse(
                "認可サーバーが動的クライアント登録に対応していません。このサーバーは提供できません")
        }

        let verifier = randomToken()
        let challenge = base64URL(sha256(Data(verifier.utf8)))
        let state = randomToken()
        guard var components = URLComponents(string: authorizationEndpoint) else {
            throw BackendError.badResponse("authorization endpoint が URL として読めません: \(authorizationEndpoint)")
        }
        components.queryItems = (components.queryItems ?? []) + [
            .init(name: "client_id", value: clientId),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "scope", value: ""),
        ]
        guard let url = components.url else {
            throw BackendError.badResponse("authorization endpoint に問い合わせを組み立てられません: \(authorizationEndpoint)")
        }
        print("ブラウザで認可してください:\n\n  \(url.absoluteString)\n")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()

        let (code, returnedState) = try callback.waitForCode(timeout: 300)
        guard returnedState == state else {
            throw BackendError.badResponse("state が一致しません")
        }

        let payload = try await postForm(try requireURL(tokenEndpoint, "token endpoint"), form: [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientId,
            "code_verifier": verifier,
        ])
        guard let accessToken = payload["access_token"] as? String else {
            throw BackendError.badResponse("token endpoint が access_token を返しません")
        }
        let tokens = OAuthTokens(
            accessToken: accessToken,
            refreshToken: payload["refresh_token"] as? String,
            expiresAt: (payload["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            clientId: clientId,
            tokenEndpoint: tokenEndpoint
        )
        try write(tokens, to: "\(storeDir)/\(serverName).json")
        print("'\(serverName)' を認可しました")
    }

    static func discoverAuthorizationServer(for mcpURL: URL) async throws -> [String: Any] {
        var origin = URLComponents()
        origin.scheme = mcpURL.scheme
        origin.host = mcpURL.host
        origin.port = mcpURL.port

        guard let originURL = origin.url else {
            throw BackendError.badResponse("MCP の url からホストを取り出せません: \(mcpURL.absoluteString)")
        }
        var authServer = originURL
        if let resource = try? await getJSON(originURL.appendingPathComponent(".well-known/oauth-protected-resource")),
           let servers = resource["authorization_servers"] as? [String], let first = servers.first,
           let url = URL(string: first) {
            authServer = url
        }
        return try await getJSON(authServer.appendingPathComponent(".well-known/oauth-authorization-server"))
    }

    static func register(at endpoint: String, redirectURI: String) async throws -> String {
        var request = URLRequest(url: try requireURL(endpoint, "registration endpoint"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "ios-dev-sandbox host-bridge",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let clientId = obj["client_id"] as? String else {
            throw BackendError.badResponse("クライアント登録に失敗しました（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        return clientId
    }

    static func getJSON(_ url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BackendError.badResponse("\(url.absoluteString) を読めません")
        }
        return obj
    }

    static func postForm(_ url: URL, form: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BackendError.badResponse(
                "token endpoint がエラーを返しました: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "")")
        }
        return obj
    }

    static func write(_ tokens: OAuthTokens, to path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(tokens).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// 戻り値を捨てると失敗時に state と code_verifier が定数になり、PKCE が無効になる。
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("乱数を生成できません（SecRandomCopyBytes が失敗）")
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func sha256(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }
}

/// 認可コードを 1 回だけ受けるローカルの HTTP リスナー。
final class CallbackServer {
    let port: UInt16
    private let socket: Int32

    init() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BackendError.unreachable("socket() failed") }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw BackendError.unreachable("bind/listen failed")
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                _ = Darwin.getsockname(fd, $0, &length)
            }
        }
        socket = fd
        port = UInt16(bigEndian: bound.sin_port)
    }

    func waitForCode(timeout: TimeInterval) throws -> (code: String, state: String?) {
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let client = Darwin.accept(socket, nil, nil)
        guard client >= 0 else { throw BackendError.unreachable("認可がタイムアウトしました") }
        defer { Darwin.close(client) }

        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = Darwin.read(client, &buffer, buffer.count)
        let request = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self)

        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n認可が完了しました。このタブは閉じて構いません。\n"
        _ = reply.withCString { Darwin.write(client, $0, strlen($0)) }

        guard let target = request.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(target)) else {
            throw BackendError.badResponse("コールバックの形式を読めません")
        }
        let items = components.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw BackendError.badResponse("コールバックに code がありません: \(target)")
        }
        return (code, items.first(where: { $0.name == "state" })?.value)
    }

    func close() {
        Darwin.close(socket)
    }
}
