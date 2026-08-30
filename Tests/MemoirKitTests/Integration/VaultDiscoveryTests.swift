import Foundation
import Testing
@testable import MemoirKit

// CF-78: the vault is found, not hunted for.
//
// The file picker cannot reach the most common vault on a Mac: it lives under
// `~/Library`, which is hidden, inside a folder called `iCloud~md~obsidian`. A feature
// that requires the user to paste a path does not work. Everything here is built against
// a synthetic home so the assertions are about behaviour, not about this machine.

@Suite("CF-78 the vault is found, not hunted for")
struct VaultDiscoveryTests {

    /// A throwaway home directory with whatever the case needs in it.
    private struct FakeHome {
        let root: URL

        init(_ name: String) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("memoir-vaults-\(ProcessInfo.processInfo.processIdentifier)-\(name)",
                                        isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        /// A folder with `notes` markdown files in it, i.e. something worth importing.
        @discardableResult
        func makeVault(at relative: String, notes: Int) throws -> URL {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for i in 0..<notes {
                try "# Note \(i)\n".write(to: url.appending(path: "note-\(i).md"),
                                         atomically: true, encoding: .utf8)
            }
            return url
        }

        func write(_ text: String, to relative: String) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @Test("CF-78 Obsidian's own vault list is read, open vault first")
    func readsObsidianRegistry() throws {
        let home = try FakeHome("registry")
        defer { home.cleanup() }

        let stale = try home.makeVault(at: "Vaults/Archive", notes: 2)
        let current = try home.makeVault(at: "Vaults/Work", notes: 5)
        try home.write("""
        {"vaults":{
          "a":{"path":"\(stale.path)","ts":1000,"open":false},
          "b":{"path":"\(current.path)","ts":500,"open":true}
        }}
        """, to: "Library/Application Support/obsidian/obsidian.json")

        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.count == 2)
        // The vault actually open in Obsidian leads, regardless of timestamps.
        #expect(found.first?.name == "Work")
        #expect(found.first?.noteCount == 5)
        #expect(found.first?.source == .obsidian)
    }

    @Test("CF-78 an Obsidian MCP server already configured hands over its path")
    func readsMCPConfig() throws {
        let home = try FakeHome("mcp")
        defer { home.cleanup() }

        let vault = try home.makeVault(at: "Notes/Second Brain", notes: 3)
        // The shape a real Claude Desktop config takes: the vault is just an argument.
        try home.write("""
        {"mcpServers":{"obsidian":{"command":"npx","args":["-y","mcp-obsidian","\(vault.path)"]}}}
        """, to: "Library/Application Support/Claude/claude_desktop_config.json")

        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.count == 1)
        #expect(found.first?.name == "Second Brain")
        #expect(found.first?.source == .mcpConfig)
    }

    @Test("CF-78 a project-nested MCP config is found too, and env wins over args")
    func readsNestedConfigAndEnv() throws {
        let home = try FakeHome("nested")
        defer { home.cleanup() }

        let vault = try home.makeVault(at: "Vaults/Env", notes: 4)
        // Claude Code nests servers per project rather than at the root.
        try home.write("""
        {"projects":{"/some/dir":{"mcpServers":{"my-obsidian":{
            "command":"node","args":["server.js"],
            "env":{"OBSIDIAN_VAULT_PATH":"\(vault.path)"}
        }}}}}
        """, to: ".claude.json")

        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.contains { $0.url.path == vault.path && $0.source == .mcpConfig })
    }

    @Test("CF-78 the iCloud folder the file dialog cannot reach is found by looking")
    func findsICloudVault() throws {
        let home = try FakeHome("icloud")
        defer { home.cleanup() }

        // The exact shape of the path that made the picker useless.
        try home.makeVault(at: "Library/Mobile Documents/iCloud~md~obsidian/Documents/Projects",
                           notes: 7)

        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.count == 1)
        #expect(found.first?.name == "Projects")
        #expect(found.first?.noteCount == 7)
        #expect(found.first?.source == .conventional)
    }

    @Test("CF-78 one vault named twice is offered once, by its best source")
    func deduplicatesAcrossSources() throws {
        let home = try FakeHome("dedupe")
        defer { home.cleanup() }

        let vault = try home.makeVault(at: "Library/Mobile Documents/iCloud~md~obsidian/Documents/Projects",
                                       notes: 6)
        try home.write("""
        {"vaults":{"a":{"path":"\(vault.path)","ts":1,"open":true}}}
        """, to: "Library/Application Support/obsidian/obsidian.json")
        try home.write("""
        {"mcpServers":{"obsidian":{"command":"npx","args":["mcp-obsidian","\(vault.path)"]}}}
        """, to: "Library/Application Support/Claude/claude_desktop_config.json")

        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.count == 1, "the same folder from three sources is still one vault")
        #expect(found.first?.source == .obsidian, "the most authoritative source is reported")
    }

    @Test("CF-78 a folder with no notes in it is never offered")
    func ignoresEmptyFolders() throws {
        let home = try FakeHome("empty")
        defer { home.cleanup() }

        let empty = home.root.appending(path: "Documents/Obsidian")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try home.write("""
        {"vaults":{"a":{"path":"\(empty.path)","ts":1,"open":true}}}
        """, to: "Library/Application Support/obsidian/obsidian.json")

        // Sending someone to import nothing is how a feature earns "it doesn't work".
        #expect(VaultDiscovery.discover(home: home.root).isEmpty)
    }

    @Test("CF-78 Memoir's own write-back folder never counts as a vault")
    func ignoresOwnOutput() throws {
        let home = try FakeHome("selfecho")
        defer { home.cleanup() }

        // A folder whose ONLY markdown is what Memoir wrote is not a vault to import.
        let root = home.root.appending(path: "Documents/Obsidian")
        try FileManager.default.createDirectory(at: root.appending(path: "Memoir"),
                                                withIntermediateDirectories: true)
        try "# 7 August\n".write(to: root.appending(path: "Memoir/2026-08-07.md"),
                                 atomically: true, encoding: .utf8)
        try home.write("""
        {"vaults":{"a":{"path":"\(root.path)","ts":1,"open":true}}}
        """, to: "Library/Application Support/obsidian/obsidian.json")

        #expect(VaultDiscovery.discover(home: home.root).isEmpty,
                "reading our own daily notes back would be the vault-shaped self-echo")
    }

    @Test("CF-78 no Obsidian at all is silence, not a crash")
    func emptyHomeIsQuiet() throws {
        let home = try FakeHome("bare")
        defer { home.cleanup() }
        #expect(VaultDiscovery.discover(home: home.root).isEmpty)
    }

    @Test("CF-78 malformed config files are skipped, not fatal")
    func survivesGarbage() throws {
        let home = try FakeHome("garbage")
        defer { home.cleanup() }

        try home.write("{not json at all", to: "Library/Application Support/obsidian/obsidian.json")
        try home.write("[]", to: "Library/Application Support/Claude/claude_desktop_config.json")
        let vault = try home.makeVault(at: "Documents/Obsidian", notes: 2)

        // The good source still lands even though both config files are unusable.
        let found = VaultDiscovery.discover(home: home.root)
        #expect(found.contains { $0.url.path == vault.path })
    }
}
