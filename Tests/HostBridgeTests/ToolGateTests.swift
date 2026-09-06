import Foundation
import Testing
@testable import HostBridge

@Suite("MCP ツールの絞り込み")
struct ToolGateTests {
    @Test func allowsEverythingWhenUnrestricted() {
        let gate = ToolGate(nil)
        #expect(gate.isAllowed("anything"))
    }

    @Test func filtersToolsListResponse() throws {
        let gate = ToolGate(["keep"])
        let response = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[{"name":"keep"},{"name":"drop"}]}}
        """
        let filtered = gate.filterToolsListResponse(Data(response.utf8))
        let obj = try JSONSerialization.jsonObject(with: filtered) as? [String: Any]
        let tools = (obj?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        #expect(tools?.map { $0["name"] as? String } == ["keep"])
    }

    @Test func detectsCalledTool() {
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"drop"}}"#
        #expect(ToolGate.calledTool(in: Data(call.utf8)) == "drop")
        let list = #"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#
        #expect(ToolGate.calledTool(in: Data(list.utf8)) == nil)
        #expect(ToolGate.isToolsListRequest(Data(list.utf8)))
    }

    @Test func rejectionKeepsRequestId() throws {
        let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"drop"}}"#
        let rejection = ToolGate.rejection(for: Data(call.utf8), tool: "drop")
        let obj = try JSONSerialization.jsonObject(with: rejection) as? [String: Any]
        #expect(obj?["id"] as? Int == 7)
        #expect((obj?["error"] as? [String: Any])?["code"] as? Int == -32602)
    }

    @Test func sseUnwrappingPrefersResponseOverNotifications() {
        let sse = """
        event: message
        data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}

        event: message
        data: {"jsonrpc":"2.0","id":1,"result":{"ok":true}}

        """
        let payload = URLBackend.lastDataPayload(fromSSE: Data(sse.utf8))
        let obj = (try? JSONSerialization.jsonObject(with: payload ?? Data())) as? [String: Any]
        #expect(obj?["id"] as? Int == 1)
    }

    // 配列（バッチ）は解釈前に見分けて拒否する。中の tools/call は誰も検査できない。
    @Test func detectsBatchBodies() {
        #expect(ToolGate.isBatch(Data("  [ {\"jsonrpc\":\"2.0\"} ]".utf8)))
        #expect(ToolGate.isBatch(Data("\n\t[]".utf8)))
        #expect(!ToolGate.isBatch(Data("{\"jsonrpc\":\"2.0\"}".utf8)))
        #expect(!ToolGate.isBatch(Data()))
    }

    // 素の文字列でない name は nil。文字列化して通すと判定をすり抜ける。
    @Test func calledToolIgnoresNonStringNames() {
        let weird = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":{"x":1}}}"#
        #expect(ToolGate.calledTool(in: Data(weird.utf8)) == nil)
        let missing = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{}}"#
        #expect(ToolGate.calledTool(in: Data(missing.utf8)) == nil)
    }
}
