import Foundation

/// サーバーごとのツール allowlist。XcodeMCPProxy の ToolFilter の一般化で、
/// tools/list の応答を絞り、tools/call の許可外を呼ばずに拒否する。
struct ToolGate: Sendable {
    let allowed: Set<String>?

    init(_ tools: [String]?) {
        self.allowed = tools.map(Set.init)
    }

    func isAllowed(_ toolName: String) -> Bool {
        guard let allowed else { return true }
        return allowed.contains(toolName)
    }

    func filterToolsListResponse(_ data: Data) -> Data {
        guard allowed != nil,
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var result = obj["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            return data
        }
        result["tools"] = tools.filter { tool in
            guard let name = tool["name"] as? String else { return false }
            return isAllowed(name)
        }
        obj["result"] = result
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? data
    }

    /// 先頭の非空白が [ なら配列。JSON として解釈する前に見る。
    static func isBatch(_ data: Data) -> Bool {
        for byte in data {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: return byte == UInt8(ascii: "[")
            }
        }
        return false
    }

    static func calledTool(in data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              obj["method"] as? String == "tools/call",
              let params = obj["params"] as? [String: Any] else { return nil }
        return params["name"] as? String
    }

    static func isToolsListRequest(_ data: Data) -> Bool {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return obj["method"] as? String == "tools/list"
    }

    static func rejection(for data: Data, tool: String) -> Data {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": -32602, "message": "tool '\(tool)' is not allowed by host-mcp.json"],
        ]
        response["id"] = obj?["id"] ?? NSNull()
        return (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
    }
}
