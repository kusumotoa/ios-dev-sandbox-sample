import Foundation
import Testing
@testable import HostBridge

// schemaVersion の検査で使い回す、最小限の commands。
private let oneCommand = #""commands":[{"name":"t","path":"/usr/bin/true"}]"#

@Suite("ホスト CLI の allowlist")
struct AllowlistTests {
    @Test func allowsAnySubcommandWhenUnrestricted() {
        let command = AllowedCommand(name: "mytool", path: "/usr/bin/true", allowedSubcommands: nil)
        #expect(command.permits(args: ["ui"]))
        #expect(command.permits(args: ["init"]))
    }

    @Test func restrictsToListedSubcommands() {
        let command = AllowedCommand(
            name: "mytool",
            path: "/usr/bin/true",
            allowedSubcommands: ["ui", "tap"]
        )
        #expect(command.permits(args: ["ui", "--device", "X"]))
        #expect(!command.permits(args: ["init"]))
    }

    // 先頭のフラグを読み飛ばすと、オプションの値がサブコマンドの代わりになる。
    // `tool --api-url status logs` は `status` と読まれる一方、CLI は `logs` を実行する。
    // 実物のバイナリで再現を確認済み。
    @Test func rejectsLeadingFlagsInsteadOfSkippingThem() {
        let command = AllowedCommand(
            name: "tool",
            path: "/usr/bin/true",
            allowedSubcommands: ["status", "logs"]
        )
        #expect(command.permits(args: ["status", "--api-url", "http://x"]))
        #expect(!command.permits(args: ["--api-url", "status", "docs"]))
        #expect(!command.permits(args: ["--verbose", "status"]))
        #expect(!command.permits(args: []))
    }

    // 1 階層下でも同じ。フラグが第 2 語として読まれてはいけない。
    @Test func nestedPolicyRejectsFlagInSecondWordPosition() {
        let command = AllowedCommand(
            name: "tool",
            path: "/usr/bin/true",
            allowedSubcommands: .nested(["files": ["list"]])
        )
        #expect(!command.permits(args: ["files", "--app", "list"]))
    }

    // 明示した空配列は全拒否。制限を外したいときは項目ごと省く。
    @Test func emptyFlatPolicyAllowsNothing() {
        let command = AllowedCommand(name: "mytool", path: "/usr/bin/true", allowedSubcommands: [])
        #expect(!command.permits(args: ["ui"]))
    }

    @Test func lookupMatchesByName() {
        let config = BridgeConfiguration(commands: [
            AllowedCommand(name: "mytool", path: "/usr/bin/true", allowedSubcommands: nil),
        ])
        #expect(config.command(named: "mytool") != nil)
        #expect(config.command(named: "sh") == nil)
    }

    @Test func nestedPolicyRequiresSecondWordForListedFirstWords() {
        let command = AllowedCommand(
            name: "tool",
            path: "/usr/bin/true",
            allowedSubcommands: .nested([
                "files": ["list", "read", "info", "summary"],
                "docs": [],
            ])
        )
        #expect(command.permits(args: ["files", "list", "--app", "com.example"]))
        #expect(!command.permits(args: ["files", "rm", "--app", "com.example"]))
        // 第 2 語の配列が空なら、その第 1 語の下は全許可。
        #expect(command.permits(args: ["docs", "show", "cli/getting-started"]))
        // 書いていない第 1 語はそのまま拒否。
        #expect(!command.permits(args: ["keychain", "list"]))
        // 第 2 語が要る場合、第 1 語だけの呼び出しは拒否。
        #expect(!command.permits(args: ["files"]))
    }

    @Test func nestedPolicyDecodesFromJSONObject() throws {
        let json = #"{"name":"tool","path":"/usr/bin/true","allowedSubcommands":{"files":["list"]}}"#
        let command = try JSONDecoder().decode(AllowedCommand.self, from: Data(json.utf8))
        #expect(command.permits(args: ["files", "list"]))
        #expect(!command.permits(args: ["files", "rm"]))
    }

    @Test func flatPolicyStillDecodesFromJSONArray() throws {
        let json = #"{"name":"tool","path":"/usr/bin/true","allowedSubcommands":["status","logs"]}"#
        let command = try JSONDecoder().decode(AllowedCommand.self, from: Data(json.utf8))
        #expect(command.permits(args: ["status"]))
        #expect(!command.permits(args: ["rule"]))
    }

    @Test func localPathOverrideKeepsTeamSubcommands() throws {
        let team = BridgeConfiguration(commands: [
            AllowedCommand(name: "tool", path: "/opt/homebrew/bin/tool",
                           allowedSubcommands: ["status", "logs"]),
        ])
        let local = LocalOverrides(paths: ["tool": "/usr/local/bin/tool"], extra: nil)
        let (merged, warnings) = team.merged(with: local)
        #expect(warnings.isEmpty)
        let tool = try #require(merged.command(named: "tool"))
        #expect(tool.path == "/usr/local/bin/tool")
        #expect(tool.permits(args: ["status"]))
        #expect(!tool.permits(args: ["rule"]))
    }

    @Test func localExtraAddsUnknownCommandsOnly() throws {
        let team = BridgeConfiguration(commands: [
            AllowedCommand(name: "mytool", path: "/opt/homebrew/bin/mytool", allowedSubcommands: nil),
        ])
        let local = LocalOverrides(paths: nil, extra: [
            AllowedCommand(name: "my-tool", path: "/usr/local/bin/my-tool", allowedSubcommands: ["run"]),
            AllowedCommand(name: "mytool", path: "/tmp/evil-mytool",
                           allowedSubcommands: nil),
        ])
        let (merged, warnings) = team.merged(with: local)
        #expect(merged.command(named: "my-tool") != nil)
        // 名前が衝突したエントリがチーム標準を置き換えてはいけない。
        let myTool = try #require(merged.command(named: "mytool"))
        #expect(myTool.path == "/opt/homebrew/bin/mytool")
        #expect(warnings.count == 1)
    }

    @Test func localOverridesRejectRelativePaths() throws {
        let team = BridgeConfiguration(commands: [
            AllowedCommand(name: "mytool", path: "/opt/homebrew/bin/mytool", allowedSubcommands: nil),
        ])
        let local = LocalOverrides(
            paths: ["mytool": "bin/mytool"],
            extra: [AllowedCommand(name: "other", path: "relative/other", allowedSubcommands: nil)]
        )
        let (merged, warnings) = team.merged(with: local)
        let myTool = try #require(merged.command(named: "mytool"))
        #expect(myTool.path == "/opt/homebrew/bin/mytool")
        #expect(merged.command(named: "other") == nil)
        #expect(warnings.count == 2)
    }

    @Test func localOverridesWarnOnUnknownPathKey() {
        let team = BridgeConfiguration(commands: [])
        let local = LocalOverrides(paths: ["ghost": "/usr/bin/ghost"], extra: nil)
        let (merged, warnings) = team.merged(with: local)
        #expect(merged.commands.isEmpty)
        #expect(warnings.count == 1)
    }

    @Test func missingLocalConfigLoadsAsNil() throws {
        #expect(try LocalOverrides.load(path: "/nonexistent/local/host-cli.json") == nil)
    }

    // 未導入のツールが載り得る。致命扱いにすると新しいマシンでブリッジが起動しない。
    @Test func missingExecutablesAreSplitOffNotFatal() {
        let config = BridgeConfiguration(commands: [
            AllowedCommand(name: "present", path: "/usr/bin/true", allowedSubcommands: nil),
            AllowedCommand(name: "absent", path: "/nonexistent/tool", allowedSubcommands: nil),
        ])
        let (available, missing) = config.partitionedByAvailability { $0 == "/usr/bin/true" }
        #expect(available.commands.map(\.name) == ["present"])
        #expect(missing.map(\.name) == ["absent"])
        #expect(available.command(named: "absent") == nil)
    }

    // MARK: - schemaVersion and load diagnostics

    private func writingConfig(_ json: String) throws -> String {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("host-cli-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: path)
        return path.path
    }


    @Test(arguments: ["1", "\"1\""])
    func aSchemaVersionThisBuildUnderstandsLoads(declared: String) throws {
        let path = try writingConfig("{\"schemaVersion\":\(declared),\(oneCommand)}")
        #expect(try BridgeConfiguration.load(path: path).commands.count == 1)
    }

    // バージョンの無いファイルを拒否すると、この検査より前に書かれたものが全て死ぬ。
    @Test func anAbsentSchemaVersionIsReadAsTheCurrentOne() throws {
        let path = try writingConfig("{\(oneCommand)}")
        #expect(try BridgeConfiguration.load(path: path).commands.count == 1)
    }

    // 新しい allowlist を古いブリッジに読ませた場合で、この検査が
    // 無いと、たまたま名前が変わったキーの話として現れる。
    @Test(arguments: ["2", "\"2\"", "99", "\"next\""])
    func aSchemaVersionFromTheFutureIsRefusedByName(declared: String) throws {
        let path = try writingConfig("{\"schemaVersion\":\(declared),\(oneCommand)}")

        let error = #expect(throws: BridgeConfigurationError.self) {
            try BridgeConfiguration.load(path: path)
        }
        let message = try #require(error?.errorDescription)
        #expect(message.contains(path), "読んだファイルの名前がメッセージに入っていること")
        #expect(message.contains("schemaVersion"))
        #expect(message.contains("mise run setup"), "更新方法が案内されていること")
    }

    // ブリッジは allowlist を 2 つ読むが、DecodingError はファイル名を言わない。
    @Test func aBrokenConfigIsReportedAgainstItsPath() throws {
        let path = try writingConfig(#"{"commands":[{"name":"t"}]}"#)

        let error = #expect(throws: BridgeConfigurationError.self) {
            try BridgeConfiguration.load(path: path)
        }
        let message = try #require(error?.errorDescription)
        #expect(message.contains(path))
        #expect(message.contains("path"), "失敗したキーの名前も残っていること")
    }

    @Test func aBrokenLocalOverrideIsReportedAgainstItsPath() throws {
        let path = try writingConfig(#"{"paths":"not an object"}"#)

        let error = #expect(throws: BridgeConfigurationError.self) {
            try LocalOverrides.load(path: path)
        }
        #expect(try #require(error?.errorDescription).contains(path))
    }
}
