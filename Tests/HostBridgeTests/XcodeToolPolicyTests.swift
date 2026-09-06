import Foundation
import Testing

@testable import HostBridge

// xcode のツール一覧はコードから share/host-mcp.json へ移った。線引き（
// プロジェクトとホストを書き換えるものは載せない）の検査も一緒に移す。

private var xcodeTools: [String] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let path = root.appendingPathComponent("share/host-mcp.json").path
    guard let data = FileManager.default.contents(atPath: path),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let servers = obj["servers"] as? [String: Any],
          let xcode = servers["xcode"] as? [String: Any],
          let tools = xcode["tools"] as? [String] else { return [] }
    return tools
}

@Suite("Xcode ツールの許可リスト")
struct XcodeToolPolicyTests {
    // camelCase を語に割る。部分一致だと GetTargetBuildSettings が "Set" に当たる。
    private func words(of tool: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in tool {
            if character.isUppercase, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    @Test func 書き換え側の動詞を持つツールは載せない() {
        let mutating: Set<String> = [
            "Create", "Write", "Delete", "Remove", "Rename", "Move",
            "Update", "Set", "Edit", "Modify", "New", "Invoke", "Snippet",
        ]
        for tool in xcodeTools {
            let offending = words(of: tool).filter { mutating.contains($0) }
            #expect(offending.isEmpty, "\(tool) が書き換え側の動詞 \(offending) を含んでいる")
        }
    }

    @Test func ヘッドレスで識別子を解決するツールが揃っている() {
        // これらが無いとビルド・テスト・実行が一切使えない（CLAUDE.md の制約）。
        // XcodeOpenWorkspace は Xcode の承認ゲートで、これが無いと他が全て
        // "This agent isn't approved to use Xcode's tools yet" で弾かれる。
        for required in ["XcodeOpenWorkspace", "XcodeListWorkspaces", "XcodeListWindows",
                         "BuildProject", "XcodeSwitchScheme", "XcodeSwitchRunDestination",
                         "XcodeSwitchTestPlan"] {
            #expect(xcodeTools.contains(required), "\(required) が share/host-mcp.json に無い")
        }
    }

    @Test func 一覧が空でない() {
        #expect(xcodeTools.count >= 30)
    }
}
