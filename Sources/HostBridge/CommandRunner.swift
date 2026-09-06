import Foundation
import Logging

struct ExecRequest: Codable, Sendable {
    let command: String
    let args: [String]?
    let cwd: String?
    let stdin: String?
}

struct ExecResponse: Codable, Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    /// コマンドの非ゼロ終了ではなく、ブリッジ自身が拒否・中断したときに入る。
    let bridgeError: String?
}

enum CommandRunner {
    /// ストリームごとの取り込み上限。暴走したコマンドがホストのメモリを食い潰さないように。
    static let maxOutputBytes = 8 * 1024 * 1024

    /// 子の終了後もパイプを読む時間。書き込み側を継いだ孫が居るとパイプは閉じない。
    static let drainGrace: TimeInterval = 2.0

    /// SIGTERM を送ってから SIGKILL までに与える後始末の時間。
    static let killGrace: TimeInterval = 2.0

    /// 起動時のサンドボックスのマウント先。`sbx ls` が引けなければ空を返し、
    /// cwd の検証は行わない（ブリッジが動かなくなる方が困る）。
    static func sandboxWorkspaces(logger: Logger) -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sbx", "ls", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sandboxes = root["sandboxes"] as? [[String: Any]] else { return [] }

        var roots = Set<String>()
        for sandbox in sandboxes {
            for workspace in sandbox["workspaces"] as? [String] ?? [] {
                var path = workspace
                for suffix in [":ro", ":rw"] where path.hasSuffix(suffix) {
                    path = String(path.dropLast(suffix.count))
                }
                roots.insert(path)
            }
        }
        logger.info("cwd に許すディレクトリ: \(roots.count) 件")
        return roots.sorted()
    }

    /// ホスト CLI に引き継ぐ環境変数。macOS の CLI が動くのに要るものだけ。
    static let passthroughKeys = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR",
        "LANG", "LC_ALL", "LC_CTYPE", "TERM",
        "DEVELOPER_DIR", "IOS_DEV_SANDBOX_DEVELOPER_DIR",
    ]

    static func run(
        _ command: AllowedCommand,
        args: [String],
        cwd: String?,
        stdin: String?,
        binDir: String? = nil,
        cwdRoots: [String] = [],
        timeout: TimeInterval,
        logger: Logger
    ) -> ExecResponse {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.path)
        process.arguments = args

        let workingDirectory = resolvedCwd(cwd, roots: cwdRoots)
        if let cwd, cwd != workingDirectory {
            logger.warning("cwd はサンドボックスへ渡していない場所なので使いません: \(cwd)")
        }
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

        // 渡すものを列挙する。除外方式にすると SSH_AUTH_SOCK や GITHUB_TOKEN のような
        // 名前を足し忘れ、サンドボックスが argv を決めるコマンドの手に渡る。
        let inherited = ProcessInfo.processInfo.environment
        var environment = Self.passthroughKeys.reduce(into: [String: String]()) { env, key in
            env[key] = inherited[key]
        }

        // ラッパーが ios-dev-sandbox を PATH から呼ぶ。起動したシェルに依存させない。
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        if let binDir, !binDir.isEmpty, !path.split(separator: ":").contains(Substring(binDir)) {
            environment["PATH"] = "\(binDir):\(path)"
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        // 20ms ごとに isRunning を見に行くと、長いビルドの間じゅう起き続けるうえ、
        // 終わってから返るまでにその分の遅れが乗る。終了通知で待つ。
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return refusal("failed to launch \(command.name): \(error.localizedDescription)")
        }

        let outCollector = OutputCollector(handle: stdoutPipe.fileHandleForReading)
        let errCollector = OutputCollector(handle: stderrPipe.fileHandleForReading)

        // stdin は専用スレッドから。パイプは 64KB で、読まない子に書くと中断できず止まる。
        let stdinHandle = stdinPipe.fileHandleForWriting
        if let stdinData = stdin.flatMap({ $0.data(using: .utf8) }), !stdinData.isEmpty {
            Thread.detachNewThread {
                try? stdinHandle.write(contentsOf: stdinData)
                try? stdinHandle.close()
            }
        } else {
            try? stdinHandle.close()
        }

        let timedOut = exited.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + killGrace) == .timedOut {
                // terminate() は Process が作ったプロセスグループごと送るが、こちらは
                // pid 指定なので、SIGTERM を無視する子の孫が残る。合わせてグループへ。
                let pid = process.processIdentifier
                if getpgid(pid) == pid { killpg(pid, SIGKILL) } else { kill(pid, SIGKILL) }
            }
        }
        process.waitUntilExit()

        let drainDeadline = Date().addingTimeInterval(drainGrace)
        let stdout = outCollector.finish(by: drainDeadline)
        let stderr = errCollector.finish(by: drainDeadline)

        if timedOut {
            logger.warning("\(command.name) timed out after \(Int(timeout))s")
            return ExecResponse(
                exitCode: -1,
                stdout: stdout,
                stderr: stderr,
                bridgeError: "timed out after \(Int(timeout))s"
            )
        }

        return ExecResponse(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            bridgeError: nil
        )
    }

    static func refusal(_ message: String) -> ExecResponse {
        ExecResponse(exitCode: -1, stdout: "", stderr: "", bridgeError: message)
    }

    /// 呼び出し側の cwd が意味を持つのは、両側が同じ絶対パスで見ているマウント済み
    /// ワークスペースの中だけ。コンテナ内にしか無いパスはホストのホームへ落とす。
    /// ブリッジがたまたま起動したディレクトリと違い、位置が決まっているため。
    /// サンドボックスへ渡していないディレクトリでは動かさない。cwd はリクエストが
    /// そのまま決めるので、検証しないと /etc や ~/.ssh でも実行できる。roots が空
    /// （sbx が引けない）なら存在チェックだけに落とす。
    ///
    /// 別プロジェクトのサンドボックスに渡した先は roots に入るので、そこは防げない。
    /// ブリッジは全サンドボックスで共有されていて、リクエストがどれから来たか
    /// 分からないため。
    static func resolvedCwd(_ requested: String?, roots: [String] = []) -> String {
        guard let requested else { return NSHomeDirectory() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: requested, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return NSHomeDirectory()
        }
        guard !roots.isEmpty else { return requested }

        let path = URL(fileURLWithPath: requested).standardizedFileURL.path
        let allowed = roots.contains { root in
            let base = URL(fileURLWithPath: root).standardizedFileURL.path
            return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
        return allowed ? requested : NSHomeDirectory()
    }
}

/// バックグラウンドスレッドでパイプを EOF まで読み、`maxOutputBytes` で打ち切る。
///
/// `availableData` ではなく `poll` で待つ。孫が書き込み側を継ぐとパイプは閉じず、
/// ブロックしたままのスレッドが `FileHandle` を掴み続けて fd が戻らない。
/// 実測で 1 回の実行につき 2 つ漏れ、長く動くブリッジでは開ける数を使い切る。
///
/// 安全性の前提: `data` `truncated` `done` `stopped` に触れるのは `condition` の下だけ。
private final class OutputCollector: @unchecked Sendable {
    /// 打ち切りを言い渡してから読み手が気づくまでの間隔。
    private static let pollInterval: Int32 = 100

    private var data = Data()
    private var truncated = false
    private var done = false
    private var stopped = false
    private let condition = NSCondition()

    init(handle: FileHandle) {
        let thread = Thread { [self] in
            // handle をクロージャで掴んでおく。解放されると fd が閉じ、read が EBADF になる。
            let fd = handle.fileDescriptor
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while !shouldStop() {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Self.pollInterval)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if ready == 0 { continue }
                let count = read(fd, &buffer, buffer.count)
                if count < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if count == 0 { break }
                append(Data(buffer[0..<count]))
            }
            // 読み終えたら明示的に閉じる。Process が Pipe を保持したままだと、
            // スレッドが終わっても fd が戻らない（実測）。
            try? handle.close()
            markDone()
        }
        thread.start()
    }

    /// `deadline` まで EOF を待ち、そこまでに届いた分を返す。間に合わなければ読み手に
    /// 打ち切りを言い渡す。放っておくと fd を掴んだまま残る。
    func finish(by deadline: Date) -> String {
        condition.lock()
        defer { condition.unlock() }
        while !done {
            if !condition.wait(until: deadline) { break }
        }
        var text = String(data: data, encoding: .utf8) ?? ""
        if truncated { text += "\n[output truncated by host-bridge]" }
        if !done {
            stopped = true
            text += "\n[stream still open after command exit; remaining output dropped]"
        }
        return text
    }

    private func shouldStop() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    private func append(_ chunk: Data) {
        condition.lock()
        defer { condition.unlock() }
        let room = CommandRunner.maxOutputBytes - data.count
        guard room > 0 else {
            truncated = true
            return
        }
        data.append(chunk.prefix(room))
        if chunk.count > room { truncated = true }
    }

    private func markDone() {
        condition.lock()
        done = true
        condition.broadcast()
        condition.unlock()
    }
}
