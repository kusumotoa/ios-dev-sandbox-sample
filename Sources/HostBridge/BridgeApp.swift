import Foundation
import Logging

struct ExecEndpointHandler: Sendable {
    let config: BridgeConfiguration
    let timeout: TimeInterval
    let logger: Logger

    /// ログだけでなく応答にも載せる。無視された上書きは規則の食い違いを意味するため。
    let warnings: [String]

    /// cwd に許すディレクトリ。起動時のサンドボックスのマウントの和集合。
    var cwdRoots: [String] = []

    @Sendable
    func handleExec(body: Data) async -> HTTPResponse {
        guard body.count <= 1_048_576 else {
            return encode(CommandRunner.refusal("request body too large"), status: 413)
        }
        let execRequest: ExecRequest
        do {
            execRequest = try JSONDecoder().decode(ExecRequest.self, from: body)
        } catch {
            return encode(CommandRunner.refusal("malformed request body"), status: 400)
        }

        guard let command = config.command(named: execRequest.command) else {
            logger.warning("Rejected command not in allowlist: \(execRequest.command)")
            return encode(
                CommandRunner.refusal("command '\(execRequest.command)' is not allowed"),
                status: 403
            )
        }

        guard FileManager.default.isExecutableFile(atPath: command.path) else {
            return encode(
                CommandRunner.refusal(
                    "'\(command.name)' is allowlisted but not installed on the host (\(command.path))"),
                status: 503
            )
        }

        let args = execRequest.args ?? []
        guard command.permits(args: args) else {
            logger.warning("Rejected subcommand: \(execRequest.command) \(args.first ?? "")")
            return encode(
                CommandRunner.refusal("subcommand is not allowed for '\(command.name)'"),
                status: 403
            )
        }

        logger.info("exec \(command.name) \(args.joined(separator: " "))")

        let response = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: CommandRunner.run(
                    command,
                    args: args,
                    cwd: execRequest.cwd,
                    stdin: execRequest.stdin,
                    binDir: ProcessInfo.processInfo.environment["IOS_DEV_SANDBOX_BIN_DIR"],
                    cwdRoots: cwdRoots,
                    timeout: timeout,
                    logger: logger
                ))
            }
        }

        return encode(response, status: 200)
    }

    private func encode(_ response: ExecResponse, status: Int) -> HTTPResponse {
        .json(status, (try? JSONEncoder().encode(response)) ?? Data())
    }
}
