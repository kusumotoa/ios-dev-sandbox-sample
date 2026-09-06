import ArgumentParser
import Foundation
import Logging

@main
struct HostBridgeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "host-bridge",
        abstract: "Serve allowlisted host CLIs and declared MCP servers to sandboxes over one port",
        subcommands: [Auth.self]
    )

    /// SIGPIPE の無視はプロセス全体に掛ける。serve だけに置くと、auth のコールバック
    /// サーバー（自前の socket。SO_NOSIGPIPE 無し）でブラウザが先に閉じたときに
    /// 認可コードを消費済みのまま落ちる。
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        await main(nil)
    }

    @Option(name: .long, help: "Host to bind to")
    var host: String = "127.0.0.1"

    @Option(name: .long, help: "Port to listen on")
    var port: Int = 19721

    @Option(name: .long, help: "Path to the team CLI allowlist JSON")
    var cliConfig: String?

    @Option(name: .long, help: "Path to machine-local CLI overrides JSON")
    var cliLocalConfig: String?

    @Option(name: .long, help: "Per-command timeout in seconds")
    var timeout: Int = 300

    @OptionGroup var mcp: MCPOptions

    func run() async throws {
        var logger = Logger(label: "host-bridge")
        logger.logLevel = .info

        guard let cliConfig else {
            throw ValidationError("--cli-config は待ち受けに必要です")
        }

        var allowlist = try BridgeConfiguration.load(path: cliConfig)
        var warnings: [String] = []
        if let cliLocalConfig, let local = try LocalOverrides.load(path: cliLocalConfig) {
            let (merged, localWarnings) = allowlist.merged(with: local)
            allowlist = merged
            warnings = localWarnings
            for warning in localWarnings {
                logger.warning("local config (\(cliLocalConfig)): \(warning)")
            }
        }
        for command in allowlist.partitionedByAvailability().missing {
            logger.warning("'\(command.name)' is allowlisted but not executable at \(command.path) (not installed?)")
        }

        let mcpConfig = try mcp.load(logger: logger)
        logger.info("CLI: \(allowlist.commands.map(\.name).sorted().joined(separator: ", "))")
        logger.info("MCP: \(mcpConfig.servers.keys.sorted().joined(separator: ", "))")

        let handler = makeHostBridgeHandler(
            cli: allowlist, cliWarnings: warnings,
            timeout: TimeInterval(timeout), mcp: mcpConfig, oauthDir: mcp.oauthDir,
            tokenDir: mcp.tokenDir, logger: logger)
        try await HTTPServer(host: host, port: port, handler: handler, logger: logger).run()
    }
}

struct MCPOptions: ParsableArguments {
    @Option(name: .long, help: "Path to the team MCP server list JSON")
    var mcpConfig: String

    @Option(name: .long, help: "Path to machine-local extra MCP servers JSON")
    var mcpLocalConfig: String?

    @Option(name: .long, help: "Directory holding OAuth tokens (one JSON per server)")
    var oauthDir: String

    @Option(name: .long, help: "Directory holding pre-issued bearer tokens (one file per server)")
    var tokenDir: String

    func load(logger: Logger?) throws -> ProxyConfiguration {
        var config = try ProxyConfiguration.load(path: mcpConfig)
        if let mcpLocalConfig {
            let (merged, warnings) = try config.merged(withLocalAt: mcpLocalConfig)
            config = merged
            for warning in warnings {
                logger?.warning("local config (\(mcpLocalConfig)): \(warning)")
            }
        }
        return config
    }
}

struct Auth: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "auth",
        abstract: "Authorize an auth: oauth server in the browser and store its tokens"
    )

    @Argument(help: "Server name declared in host-mcp.json")
    var name: String

    @OptionGroup var mcp: MCPOptions

    func run() async throws {
        let config = try mcp.load(logger: nil)
        guard let spec = config.servers[name] else {
            throw ValidationError("'\(name)' は host-mcp.json に定義されていません")
        }
        guard spec.auth == "oauth", let url = spec.url.flatMap(URL.init(string:)) else {
            throw ValidationError("'\(name)' は auth: oauth の url 型ではありません")
        }
        try await OAuthFlow.authorize(serverName: name, mcpURL: url, storeDir: mcp.oauthDir)
    }
}
