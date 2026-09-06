import Foundation

/// プロキシは 1 回の起動より長生きするので、掴んだ DEVELOPER_DIR は `xcode-select -s` で古くなる。
enum XcodeSelection: Sendable {
    case pinned(String)
    case tracking(linkPath: String, readLink: @Sendable (String) -> String?)

    /// Developer ディレクトリを直接指す。後ろに繋ぐものは無い。
    static let xcodeSelectLinkPath = "/var/db/xcode_select_link"

    static func trackingXcodeSelect(linkPath: String = xcodeSelectLinkPath) -> XcodeSelection {
        .tracking(linkPath: linkPath, readLink: { try? FileManager.default.destinationOfSymbolicLink(atPath: $0) })
    }

    /// env ファイルは `--developer-dir` を必ず渡すので、パスでない値は全て「追従」。
    static func from(argument: String?) -> XcodeSelection {
        guard let argument, argument.hasPrefix("/") else { return .trackingXcodeSelect() }
        return .pinned(argument)
    }

    func resolve() -> String? {
        switch self {
        case .pinned(let developerDir):
            return developerDir
        case .tracking(let linkPath, let readLink):
            return readLink(linkPath)
        }
    }
}
