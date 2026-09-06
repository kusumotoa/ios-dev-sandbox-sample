import Foundation
import Logging

struct ServerEntry: Sendable {
    let backend: any MCPBackend
    let gate: ToolGate
}

private func jsonError(_ status: Int, _ message: String) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: ["bridgeError": message])) ?? Data()
    return .json(status, body)
}

private func jsonBody(_ data: Data, sessionId: String?) -> HTTPResponse {
    .json(200, data, extraHeaders: sessionId.map { [("Mcp-Session-Id", $0)] } ?? [])
}

func makeHostBridgeHandler(
    cli: BridgeConfiguration,
    cliWarnings: [String],
    timeout: TimeInterval,
    mcp: ProxyConfiguration,
    oauthDir: String,
    tokenDir: String,
    logger: Logger
) -> HTTPServer.Handler {
    var building: [String: ServerEntry] = [:]
    for (name, spec) in mcp.servers {
        let gate = ToolGate(spec.tools)
        if spec.kind == "xcode" {
            building[name] = ServerEntry(backend: XcodeBackend(logger: logger), gate: gate)
        } else if let url = spec.url.flatMap(URL.init(string:)) {
            let auth: (any MCPTokenProvider)?
            switch spec.auth {
            case "oauth":
                auth = OAuthTokenProvider(
                    serverName: name, mcpURL: url, storeDir: oauthDir, logger: logger)
            case "token":
                auth = StaticTokenProvider(
                    serverName: name, path: "\(tokenDir)/\(name)")
            default:
                auth = nil
            }
            building[name] = ServerEntry(backend: URLBackend(url: url, logger: logger, auth: auth), gate: gate)
        } else if let command = spec.command {
            building[name] = ServerEntry(backend: CommandBackend(command: command, logger: logger), gate: gate)
        }
    }
    let servers = building
    let serverNames = servers.keys.sorted()
    let exec = ExecEndpointHandler(
        config: cli, timeout: timeout, logger: logger, warnings: cliWarnings,
        cwdRoots: CommandRunner.sandboxWorkspaces(logger: logger))

    // 独自の認証は持たない。待ち受けは 127.0.0.1 だけで LAN からは届かず、
    // サンドボックスからの到達は sbx のネットワークポリシー（既定 deny。kit が
    // localhost:19721 を宣言したサンドボックスだけが通る）が門番になる。ホスト上の
    // 同一ユーザーのプロセスは元から任意のコマンドを実行できるので、ここで認証を
    // 足しても守れるものが増えない。
    return { request in
        // Origin は /health より先に見る。後ろだとブラウザから allowlist を読める。
        if request.header("Origin") != nil {
            return jsonError(403, "Origin header not allowed")
        }

        if request.path == "/health", request.method == "GET" {
            let names = cli.partitionedByAvailability().available.commands.map(\.name).sorted()
            var payload: [String: Any] = ["status": "ok", "commands": names, "servers": serverNames]
            if !cliWarnings.isEmpty {
                payload["warnings"] = cliWarnings
            }
            return .json(200, (try? JSONSerialization.data(withJSONObject: payload)) ?? Data())
        }

        if request.path == "/exec", request.method == "POST" {
            return await exec.handleExec(body: request.body)
        }

        if request.path.hasPrefix("/mcp/") {
            let name = String(request.path.dropFirst("/mcp/".count))
            guard !name.contains("/"), let entry = servers[name] else {
                return jsonError(404, "unknown server")
            }
            let sessionId = request.header("Mcp-Session-Id")

            if request.method == "DELETE" {
                await entry.backend.endSession(sessionId)
                return HTTPResponse(status: 200)
            }
            guard request.method == "POST" else {
                return jsonError(404, "unknown route")
            }

            if ToolGate.isBatch(request.body) {
                return jsonError(400, "JSON-RPC batch is not supported")
            }
            if let tool = ToolGate.calledTool(in: request.body), !entry.gate.isAllowed(tool) {
                logger.warning("rejected tools/call '\(tool)' on '\(name)'")
                return jsonBody(ToolGate.rejection(for: request.body, tool: tool), sessionId: nil)
            }

            let response: BackendResponse
            do {
                response = try await entry.backend.send(
                    request.body, sessionId: sessionId,
                    protocolVersion: request.header("MCP-Protocol-Version"))
            } catch {
                logger.warning("backend '\(name)' failed: \(error.localizedDescription)")
                return jsonError(502, error.localizedDescription)
            }

            guard var payload = response.body else {
                return HTTPResponse(status: 202)
            }
            if ToolGate.isToolsListRequest(request.body) {
                payload = entry.gate.filterToolsListResponse(payload)
            }
            return jsonBody(payload, sessionId: response.sessionId)
        }

        return jsonError(404, "unknown route")
    }
}
