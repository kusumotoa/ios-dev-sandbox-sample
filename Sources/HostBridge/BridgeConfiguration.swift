import Foundation

enum SubcommandPolicy: Codable, Sendable {
    /// 許可する第 1 語。以降の引数は見ない。空配列は全拒否、全許可は項目ごと省く。
    case flat([String])
    /// 第 1 語 -> 許可する第 2 語。`files list` と `files rm` のように読み書きが
    /// 同じ語の下に混在する CLI 向け。空配列はその語の下を全許可。
    case nested([String: [String]])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flat = try? container.decode([String].self) {
            self = .flat(flat)
        } else {
            self = .nested(try container.decode([String: [String]].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flat(let words): try container.encode(words)
        case .nested(let map): try container.encode(map)
        }
    }

    /// 先頭のフラグは読み飛ばさずに拒否する。`--api-url <url>` と真偽値フラグを
    /// 区別できないため、読み飛ばすと url がサブコマンドの位置に滑り込む。
    func permits(args: [String]) -> Bool {
        guard let first = args.first, !first.hasPrefix("-") else { return false }
        switch self {
        case .flat(let allowed):
            return allowed.contains(first)
        case .nested(let map):
            guard let seconds = map[first] else { return false }
            if seconds.isEmpty { return true }
            guard args.count > 1, !args[1].hasPrefix("-") else { return false }
            return seconds.contains(args[1])
        }
    }
}

extension SubcommandPolicy: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: String...) {
        self = .flat(elements)
    }
}

/// パスは常にここから取る。リクエストからは決して取らない。
struct AllowedCommand: Codable, Sendable {
    let name: String
    let path: String

    /// サブコマンドの許可リスト。無い場合は全許可。
    let allowedSubcommands: SubcommandPolicy?

    func permits(args: [String]) -> Bool {
        guard let policy = allowedSubcommands else { return true }
        return policy.permits(args: args)
    }
}

/// `paths` も `extra` も、チーム標準コマンドの `allowedSubcommands` には
/// 触れられない。
struct LocalOverrides: Codable, Sendable {
    let paths: [String: String]?
    let extra: [AllowedCommand]?

    static func load(path: String) throws -> LocalOverrides? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        do {
            return try JSONDecoder().decode(LocalOverrides.self, from: data)
        } catch {
            throw BridgeConfigurationError.unreadable(path: path, detail: describe(error))
        }
    }
}

struct BridgeConfiguration: Codable, Sendable {
    /// 構造より先に読む。食い違いを欠けたキーではなくバージョンのずれとして出す。
    static let supportedSchemaVersion = 1

    let commands: [AllowedCommand]

    func command(named name: String) -> AllowedCommand? {
        commands.first { $0.name == name }
    }

    func merged(with local: LocalOverrides) -> (config: BridgeConfiguration, warnings: [String]) {
        var warnings: [String] = []

        let teamNames = Set(commands.map(\.name))
        let merged = commands.map { command -> AllowedCommand in
            guard let override = local.paths?[command.name] else { return command }
            guard override.hasPrefix("/") else {
                warnings.append("'\(command.name)' のパス差し替えは絶対パスで書く必要があります（'\(override)'）— 無視しました")
                return command
            }
            return AllowedCommand(
                name: command.name, path: override,
                allowedSubcommands: command.allowedSubcommands
            )
        }

        for name in (local.paths ?? [:]).keys.sorted() where !teamNames.contains(name) {
            warnings.append("存在しないコマンド '\(name)' へのパス差し替え — 無視しました")
        }

        var result = merged
        var seen = teamNames
        for command in local.extra ?? [] {
            guard !seen.contains(command.name) else {
                warnings.append("extra の '\(command.name)' はチーム標準と同名 — 無視しました（チーム標準が優先）")
                continue
            }
            guard command.path.hasPrefix("/") else {
                warnings.append("extra の '\(command.name)' は絶対パスで書く必要があります（'\(command.path)'）— 無視しました")
                continue
            }
            seen.insert(command.name)
            result.append(command)
        }

        return (BridgeConfiguration(commands: result), warnings)
    }

    /// 相対パスは拒否する。ブリッジのその時の cwd を基準に解決されるため。バイナリの
    /// 存在は見ない。任意ツール 1 つの未導入で起動しなくなるのを避ける。
    static func load(path: String) throws -> BridgeConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try checkSchemaVersion(of: data, at: path)

        let config: BridgeConfiguration
        do {
            config = try JSONDecoder().decode(BridgeConfiguration.self, from: data)
        } catch {
            throw BridgeConfigurationError.unreadable(path: path, detail: describe(error))
        }

        for command in config.commands {
            guard command.path.hasPrefix("/") else {
                throw BridgeConfigurationError.relativePath(command.name, command.path)
            }
        }
        return config
    }

    /// `schemaVersion` の無いファイルは 1 として読む。JSON オブジェクトでない中身は
    /// 触れずに通す。デコーダのメッセージの方が分かりやすいため。
    static func checkSchemaVersion(of data: Data, at path: String) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let declared = object["schemaVersion"] else { return }

        let version = (declared as? Int) ?? (declared as? String).flatMap { Int($0) }
        guard let version, version <= supportedSchemaVersion else {
            throw BridgeConfigurationError.unsupportedSchemaVersion(
                path: path,
                declared: String(describing: declared),
                supported: supportedSchemaVersion
            )
        }
    }

    func partitionedByAvailability(
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> (available: BridgeConfiguration, missing: [AllowedCommand]) {
        var available: [AllowedCommand] = []
        var missing: [AllowedCommand] = []
        for command in commands {
            if isExecutable(command.path) {
                available.append(command)
            } else {
                missing.append(command)
            }
        }
        return (BridgeConfiguration(commands: available), missing)
    }
}

/// デコードのエラーはキーを言うがファイルを言わない。ブリッジは 2 つ読む。
func describe(_ error: Error) -> String {
    guard let error = error as? DecodingError else { return error.localizedDescription }
    switch error {
    case .keyNotFound(let key, let context):
        return "キー '\(key.stringValue)' がありません\(location(context))"
    case .typeMismatch(_, let context), .valueNotFound(_, let context):
        return "\(context.debugDescription)\(location(context))"
    case .dataCorrupted(let context):
        return "正しい JSON ではありません（\(context.debugDescription)）"
    @unknown default:
        return error.localizedDescription
    }
}

private func location(_ context: DecodingError.Context) -> String {
    let path = context.codingPath.reduce(into: "") { path, key in
        if let index = key.intValue {
            path += "[\(index)]"
        } else {
            path += path.isEmpty ? key.stringValue : ".\(key.stringValue)"
        }
    }
    return path.isEmpty ? "" : " at \(path)"
}

enum BridgeConfigurationError: LocalizedError {
    case relativePath(String, String)
    case unreadable(path: String, detail: String)
    case unsupportedSchemaVersion(path: String, declared: String, supported: Int)

    var errorDescription: String? {
        switch self {
        case .relativePath(let name, let path):
            return "コマンド '\(name)' は絶対パスで書く必要があります（'\(path)'）"
        case .unreadable(let path, let detail):
            return "\(path) を読めません: \(detail)"
        case .unsupportedSchemaVersion(let path, let declared, let supported):
            return "\(path) は schemaVersion \(declared) を宣言していますが、この host-bridge "
                + "が読めるのは \(supported) までです。allowlist とバイナリは一緒に配布されます — "
                + "git pull && mise run setup で更新するか、--config をこのビルドが読める "
                + "allowlist に向けてください。"
        }
    }
}

