import Foundation
import Testing
@testable import HostBridge

@Suite("JSON-RPC の id の読み取り")
struct JSONRPCTests {
    private func peek(_ json: String) -> JSONRPCPeek? {
        JSONRPCPeek(data: Data(json.utf8))
    }

    @Test func parsesIntegerAndStringIds() {
        #expect(peek(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#)?.id == .int(7))
        #expect(peek(#"{"jsonrpc":"2.0","id":"abc","method":"tools/list"}"#)?.id == .string("abc"))
    }

    // 小数の id を切り捨てて整数の id と衝突させてはいけない（1.5 → 1 は
    // RequestTracker の対応を取り違える）。他の使えない入力と同じく nil に落とす。
    @Test func fractionalIdIsNotTruncated() {
        let message = peek(#"{"jsonrpc":"2.0","id":1.5,"method":"tools/list"}"#)
        #expect(message != nil)
        #expect(message?.id == nil)
    }

    @Test func malformedJSONIsRejected() {
        #expect(peek("not json") == nil)
        #expect(peek("[1,2,3]") == nil)
    }
}
