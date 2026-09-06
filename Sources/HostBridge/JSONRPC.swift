import Foundation

enum JSONRPCId: Hashable, Sendable {
    case string(String)
    case int(Int)
}

/// 元のバイト列は手を加えず転送する。読むのは `id` と `method` だけ。
struct JSONRPCPeek: Sendable {
    let id: JSONRPCId?
    let method: String?

    init?(data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        switch obj["id"] {
        case let intId as Int:
            self.id = .int(intId)
        case let strId as String:
            self.id = .string(strId)
        default:
            self.id = nil
        }

        self.method = obj["method"] as? String
    }
}
