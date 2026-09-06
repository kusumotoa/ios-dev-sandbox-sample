import Foundation

/// 差し替えた mcpbridge はセッションを持たないので握手を再生する。id は元のまま保ち、重複した応答をそれで見分ける。
struct HandshakeRecorder {
    private(set) var initializeRequest: Data?
    private(set) var initializeId: JSONRPCId?
    private(set) var initializedNotification: Data?

    mutating func record(_ message: Data, method: String?, id: JSONRPCId?) {
        switch method {
        case "initialize":
            initializeRequest = message
            initializeId = id
        case "notifications/initialized":
            initializedNotification = message
        default:
            break
        }
    }
}
