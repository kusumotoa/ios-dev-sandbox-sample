import Foundation

struct MCPServerSpec: Codable, Sendable {
    let kind: String?
    let url: String?
    let command: [String]?
    let auth: String?
    let tools: [String]?
}

struct ProxyConfiguration: Codable, Sendable {
    /// 構造より先に読む。食い違いをバージョンのずれとして出す（host-cli と同じ）。
    static let supportedSchemaVersion = 1

    let schemaVersion: Int?
    let servers: [String: MCPServerSpec]

    static func load(path: String) throws -> ProxyConfiguration {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let config: ProxyConfiguration
        do {
            config = try JSONDecoder().decode(ProxyConfiguration.self, from: data)
        } catch {
            throw ProxyConfigurationError.unreadable(path: path, detail: describe(error))
        }
        if let declared = config.schemaVersion, declared > supportedSchemaVersion {
            throw ProxyConfigurationError.unsupportedSchemaVersion(
                path: path, declared: declared, supported: supportedSchemaVersion)
        }
        for (name, spec) in config.servers {
            try spec.validate(name: name)
        }
        return config
    }

    /// ローカル層はチーム標準と同名を上書きできない（チーム標準の allowlist と同じ規則）。
    func merged(withLocalAt path: String) throws -> (config: ProxyConfiguration, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: path) else { return (self, []) }
        let local = try ProxyConfiguration.load(path: path)

        var warnings: [String] = []
        var merged = servers
        for (name, spec) in local.servers.sorted(by: { $0.key < $1.key }) {
            guard merged[name] == nil else {
                warnings.append("local の '\(name)' はチーム標準と同名 — 無視しました（チーム標準が優先）")
                continue
            }
            merged[name] = spec
        }
        return (ProxyConfiguration(schemaVersion: schemaVersion, servers: merged), warnings)
    }
}

extension MCPServerSpec {
    func validate(name: String) throws {
        if let kind {
            guard kind == "xcode" else {
                throw ProxyConfigurationError.invalidSpec(name, "kind に書けるのは xcode だけです（'\(kind)'）")
            }
            guard url == nil, command == nil else {
                throw ProxyConfigurationError.invalidSpec(name, "kind: xcode に url / command は書けません")
            }
            return
        }
        switch (url, command) {
        case (nil, nil), (.some, .some):
            throw ProxyConfigurationError.invalidSpec(name, "url か command のどちらか一方を書きます")
        case (.some(let url), nil):
            guard URL(string: url)?.scheme?.hasPrefix("http") == true else {
                throw ProxyConfigurationError.invalidSpec(name, "url は http(s) で書きます（'\(url)'）")
            }
        case (nil, .some(let command)):
            guard !command.isEmpty else {
                throw ProxyConfigurationError.invalidSpec(name, "command が空です")
            }
        }
        if let auth {
            guard auth == "oauth" || auth == "token" else {
                throw ProxyConfigurationError.invalidSpec(
                    name, "auth に書けるのは oauth か token です（'\(auth)'）")
            }
            guard url != nil else {
                throw ProxyConfigurationError.invalidSpec(name, "auth は url 型にだけ書けます")
            }
        }
    }
}

enum ProxyConfigurationError: LocalizedError {
    case unreadable(path: String, detail: String)
    case unsupportedSchemaVersion(path: String, declared: Int, supported: Int)
    case invalidSpec(String, String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let path, let detail):
            return "\(path) を読めません: \(detail)"
        case .unsupportedSchemaVersion(let path, let declared, let supported):
            return "\(path) は schemaVersion \(declared) を宣言していますが、この host-bridge が"
                + "読めるのは \(supported) までです。git pull && mise run setup で更新してください。"
        case .invalidSpec(let name, let detail):
            return "サーバー '\(name)' の定義が不正です: \(detail)"
        }
    }
}
