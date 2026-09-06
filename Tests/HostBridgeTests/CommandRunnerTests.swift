import Foundation
import Logging
import Testing

@testable import HostBridge

// タイムアウト・パイプ・シグナルの絡む実プロセス実行。ここが壊れると全ホスト CLI が
// 巻き添えになるのに、これまでユニットテストが無かった。

private let logger = Logger(label: "command-runner-tests")

@Suite("ホスト CLI の実行")
struct CommandRunnerTests {
    private func run(
        _ path: String, _ args: [String] = [],
        stdin: String? = nil, timeout: TimeInterval = 10
    ) -> ExecResponse {
        let command = AllowedCommand(name: "probe", path: path, allowedSubcommands: nil)
        return CommandRunner.run(command, args: args, cwd: nil, stdin: stdin, timeout: timeout, logger: logger)
    }

    private func sh(_ script: String, stdin: String? = nil, timeout: TimeInterval = 10) -> ExecResponse {
        run("/bin/sh", ["-c", script], stdin: stdin, timeout: timeout)
    }

    @Test func 往復_終了コードと両ストリーム() {
        let result = sh("echo out; echo err >&2; exit 3")
        #expect(result.stdout == "out\n")
        #expect(result.stderr == "err\n")
        #expect(result.exitCode == 3)
        #expect(result.bridgeError == nil)
    }

    @Test func stdinが子に届く() {
        let result = run("/bin/cat", stdin: "hello")
        #expect(result.stdout == "hello")
        #expect(result.exitCode == 0)
    }

    // パイプ容量（約 64KB）を超える stdin。専用スレッドで流し込む設計でないと、
    // 子が読み終わる前に書き込みが詰まってデッドロックする。
    @Test func パイプ容量を超えるstdin() {
        let big = String(repeating: "x", count: 200_000)
        let result = run("/bin/cat", stdin: big)
        #expect(result.stdout.count == big.count)
    }

    @Test func タイムアウトで打ち切られる() {
        let result = sh("sleep 30", timeout: 0.3)
        #expect(result.exitCode == -1)
        #expect(result.bridgeError?.contains("timed out") == true)
    }

    @Test func 出力は上限で切り詰められる() {
        let over = CommandRunner.maxOutputBytes + 1_000_000
        let result = sh("yes | head -c \(over)")
        #expect(result.stdout.contains("[output truncated by host-bridge]"))
        #expect(result.stdout.count < over)
    }

    // 書き込み側のパイプを孫プロセスが持ったまま親が先に終わるケース。EOF を待ち続けると
    // リクエストが返らないので、猶予の後に打ち切って印を残す。
    @Test func 孫プロセスがパイプを掴んでいても返る() {
        let result = sh("sleep 5 & echo done")
        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("done"))
        #expect(result.stdout.contains("[stream still open after command exit"))
    }

    // SIGTERM を無視する子は SIGKILL の経路に入る。そこが pid 指定のままだと、
    // xcodebuild が起こしたコンパイラのような孫が走り続ける。
    @Test func SIGTERMを無視する子でも孫まで止まる() throws {
        let mark = NSTemporaryDirectory() + "grandchild-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: mark) }

        // SIGKILL は SIGTERM の killGrace 秒後。孫の目印はそれより後に置く。
        let after = CommandRunner.killGrace + 2.0
        let result = sh("trap '' TERM; (sleep \(Int(after)); touch \(mark)) & sleep 30", timeout: 0.3)
        #expect(result.bridgeError?.contains("timed out") == true)

        Thread.sleep(forTimeInterval: after + 1.5)
        #expect(!FileManager.default.fileExists(atPath: mark))
    }

    @Test func 起動失敗はbridgeErrorになる() {
        let result = run("/nonexistent/binary")
        #expect(result.bridgeError?.contains("failed to launch") == true)
    }

    // cwd はリクエストが決めるので、渡していないディレクトリを弾く。
    @Test func 渡していないディレクトリはcwdにしない() {
        let home = NSHomeDirectory()
        let roots = ["/tmp/probe-root"]
        #expect(CommandRunner.resolvedCwd("/etc", roots: roots) == home)
        #expect(CommandRunner.resolvedCwd("/usr", roots: roots) == home)
        // 前方一致だけで見ると /tmp/probe-root-other が通ってしまう。
        #expect(CommandRunner.resolvedCwd("/private/etc", roots: roots) == home)
    }

    @Test func 渡したディレクトリとその配下は通る() throws {
        let base = NSTemporaryDirectory() + "cwd-probe-\(UUID().uuidString)"
        let nested = base + "/a/b"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: base) }

        #expect(CommandRunner.resolvedCwd(base, roots: [base]) == base)
        #expect(CommandRunner.resolvedCwd(nested, roots: [base]) == nested)
        // 名前が前方一致するだけの兄弟は通さない。
        let sibling = base + "-other"
        try FileManager.default.createDirectory(atPath: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: sibling) }
        #expect(CommandRunner.resolvedCwd(sibling, roots: [base]) == NSHomeDirectory())
    }

    // サンドボックス内にしか無い cwd（`/home/agent`）を拒否すると、ワークスペースの
    // 外からの呼び出しが全て失敗する。
    @Test func containerOnlyCwdFallsBackToHostHome() {
        #expect(CommandRunner.resolvedCwd("/home/agent") == NSHomeDirectory())
        #expect(CommandRunner.resolvedCwd(nil) == NSHomeDirectory())
        #expect(CommandRunner.resolvedCwd("/usr/bin/true") == NSHomeDirectory())  // ディレクトリではない
        #expect(CommandRunner.resolvedCwd("/usr/bin") == "/usr/bin")
    }

    // sbx が引けないときまで拒否すると、ブリッジが使えなくなる。
    @Test func rootsが空なら存在チェックだけ() {
        #expect(CommandRunner.resolvedCwd("/etc", roots: []) == "/etc")
        #expect(CommandRunner.resolvedCwd("/nonexistent-xyz", roots: []) == NSHomeDirectory())
    }

    // 渡す環境は列挙したものだけ。除外方式だと SSH_AUTH_SOCK のような名前を足し忘れる。
    @Test func 列挙した環境変数だけを子に渡す() {
        setenv("SSH_AUTH_SOCK", "/tmp/probe-agent", 1)
        setenv("GITHUB_TOKEN", "ghp_probe", 1)
        defer { unsetenv("SSH_AUTH_SOCK"); unsetenv("GITHUB_TOKEN") }
        let result = sh("printf %s \"${SSH_AUTH_SOCK:-none}/${GITHUB_TOKEN:-none}/${HOME:+home}\"")
        #expect(result.stdout == "none/none/home")
    }

    // ラッパーが PATH から ios-dev-sandbox を呼ぶ。ブリッジを上げたシェルに ~/.local/bin が
    // 無いと見つからず、黙って workspace に落とすので、ランチャーの置き場を先頭に足す。
    @Test func binDirはPATHの先頭に1つだけ載る() {
        let command = AllowedCommand(name: "probe", path: "/bin/sh", allowedSubcommands: nil)
        func path(binDir: String) -> String {
            CommandRunner.run(command, args: ["-c", "printf %s \"$PATH\""],
                              cwd: nil, stdin: nil, binDir: binDir, timeout: 10, logger: logger).stdout
        }
        let added = path(binDir: "/opt/ios-dev-sandbox-probe")
        #expect(added.hasPrefix("/opt/ios-dev-sandbox-probe:"))
        #expect(added.contains("/usr/bin"))

        // 既に入っているものは重ねない。部分文字列で数えない（macOS の PATH には
        // /Library/Apple/usr/bin が居る）。
        #expect(path(binDir: "/usr/bin").split(separator: ":").filter { $0 == "/usr/bin" }.count == 1)
    }

    // 孫がパイプを掴んだままだと、読み手が EOF を待ち続けて fd が戻らない。
    // ブリッジは動き続けるので、繰り返すうちに開ける数を使い切る。
    @Test func 孫がパイプを掴んでもfdは戻る() {
        func openFDs() -> Int { (0..<512).filter { fcntl($0, F_GETFD) != -1 }.count }

        _ = sh("sleep 20 & echo warm")
        Thread.sleep(forTimeInterval: 1.0)
        let before = openFDs()

        for _ in 0..<8 { _ = sh("sleep 20 & echo x") }
        Thread.sleep(forTimeInterval: 1.0)

        // 1 回につき stdout と stderr で 2 つ漏れていた。8 回で 16。
        #expect(openFDs() <= before + 2, "fd が戻っていない: \(before) → \(openFDs())")
    }
}
