import Foundation
import Testing
@testable import HostBridge

@Suite("host-mcp.json の読み取り")
struct ProxyConfigurationTests {
    private func write(_ json: String) throws -> String {
        let path = NSTemporaryDirectory() + "host-mcp-test-\(UUID().uuidString).json"
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func loadsUrlAndCommandServers() throws {
        let path = try write("""
        {"schemaVersion": 1, "servers": {
          "figma-desktop": {"url": "http://127.0.0.1:3845/mcp"},
          "drawio": {"command": ["npx", "@drawio/mcp"], "tools": ["add-rectangle"]}
        }}
        """)
        let config = try ProxyConfiguration.load(path: path)
        #expect(config.servers["figma-desktop"]?.url == "http://127.0.0.1:3845/mcp")
        #expect(config.servers["drawio"]?.command == ["npx", "@drawio/mcp"])
        #expect(config.servers["drawio"]?.tools == ["add-rectangle"])
    }

    @Test func rejectsSpecWithBothUrlAndCommand() throws {
        let path = try write("""
        {"servers": {"broken": {"url": "http://x/mcp", "command": ["x"]}}}
        """)
        #expect(throws: ProxyConfigurationError.self) { try ProxyConfiguration.load(path: path) }
    }

    @Test func rejectsNewerSchemaVersion() throws {
        let path = try write("""
        {"schemaVersion": 99, "servers": {}}
        """)
        #expect(throws: ProxyConfigurationError.self) { try ProxyConfiguration.load(path: path) }
    }

    @Test func localCannotOverrideTeamServers() throws {
        let team = try write("""
        {"servers": {"figma-desktop": {"url": "http://127.0.0.1:3845/mcp"}}}
        """)
        let local = try write("""
        {"servers": {
          "figma-desktop": {"url": "http://evil:1/mcp"},
          "mine": {"command": ["my-mcp"]}
        }}
        """)
        let (merged, warnings) = try ProxyConfiguration.load(path: team).merged(withLocalAt: local)
        #expect(merged.servers["figma-desktop"]?.url == "http://127.0.0.1:3845/mcp")
        #expect(merged.servers["mine"]?.command == ["my-mcp"])
        #expect(warnings.count == 1)
    }

    // auth はトークンを注入する相手にしか書けない。stdio の子プロセスには注入先が無い。
    @Test(arguments: ["oauth", "token"])
    func authIsOnlyForUrlServers(_ auth: String) throws {
        let ok = try write("""
        {"servers": {"s": {"url": "https://api.example.com/mcp", "auth": "\(auth)"}}}
        """)
        #expect(try ProxyConfiguration.load(path: ok).servers["s"]?.auth == auth)
        let onCommand = try write("""
        {"servers": {"s": {"command": ["x"], "auth": "\(auth)"}}}
        """)
        #expect(throws: ProxyConfigurationError.self) { try ProxyConfiguration.load(path: onCommand) }
    }

    @Test func rejectsUnknownAuthKind() throws {
        let bad = try write("""
        {"servers": {"s": {"url": "https://api.example.com/mcp", "auth": "basic"}}}
        """)
        #expect(throws: ProxyConfigurationError.self) { try ProxyConfiguration.load(path: bad) }
    }

    @Test func acceptsXcodeKind() throws {
        let path = try write("""
        {"servers": {"xcode": {"kind": "xcode", "tools": ["BuildProject"]}}}
        """)
        #expect(try ProxyConfiguration.load(path: path).servers["xcode"]?.kind == "xcode")
        let bad = try write("""
        {"servers": {"xcode": {"kind": "xcode", "url": "http://x/mcp"}}}
        """)
        #expect(throws: ProxyConfigurationError.self) { try ProxyConfiguration.load(path: bad) }
    }
}
