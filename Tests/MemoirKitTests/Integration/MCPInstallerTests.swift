import Foundation
import Testing
@testable import MemoirKit

// CF-100: connecting an agent never costs the user what was already in the file.
//
// This writes into configuration files owned by other applications, which is a thing to do
// carefully or not at all. Every case here is built against a synthetic home; nothing in this
// suite can see the real one.

@Suite("CF-100 connecting an agent never costs the user what was already there")
struct MCPInstallerTests {

    /// A throwaway home plus a fake binary to point entries at.
    private struct FakeHome {
        let root: URL
        let binary: URL

        /// The name is for reading a leftover directory, not for telling two homes apart.
        ///
        /// It used to be the whole identity, and two tests that independently picked
        /// "idempotent" got the same directory, which this initialiser then deletes. Suites
        /// run in parallel, so they wiped each other's home mid-run, and the failure surfaced
        /// as whichever one lost the race reporting that a file it had just written was not
        /// there. Uniqueness cannot be left to everyone remembering what names are taken.
        init(_ name: String) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("memoir-mcpinstall-\(ProcessInfo.processInfo.processIdentifier)-\(name)-\(UUID().uuidString.prefix(8))",
                                        isDirectory: true)
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            binary = root.appending(path: "Applications/Memoir.app/Contents/MacOS/memoir-mcp")
            try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: binary)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: binary.path)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func write(_ text: String, to relative: String) throws {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }

        func json(at relative: String) throws -> [String: Any] {
            let data = try Data(contentsOf: root.appending(path: relative))
            return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        }
    }

    private func surface(_ id: String) throws -> MCPInstaller.Surface {
        try #require(MCPInstaller.surfaces.first { $0.id == id })
    }

    private static let desktopConfig = "Library/Application Support/Claude/claude_desktop_config.json"

    // MARK: - The thing that must never happen

    @Test("CF-100 another server and the app's own preferences survive the write")
    func mergesRatherThanReplaces() throws {
        let home = try FakeHome("merge")
        defer { home.cleanup() }

        // The shape of a real one: someone else's server, and a preferences block the app
        // maintains for itself and would not thank us for discarding.
        try home.write("""
        {
          "mcpServers": { "obsidian": { "command": "npx", "args": ["-y", "mcp-obsidian", "/vault"] } },
          "coworkUserFilesPath": "/Users/someone/Claude",
          "preferences": { "chromeExtensionEnabled": true, "keepAwakeEnabled": true }
        }
        """, to: Self.desktopConfig)

        let outcome = MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)
        #expect(outcome.succeeded)

        let root = try home.json(at: Self.desktopConfig)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers.count == 2, "the server that was already there is still there")
        #expect(servers["obsidian"] != nil)
        #expect(root["coworkUserFilesPath"] != nil, "sibling keys are not ours to remove")
        let preferences = try #require(root["preferences"] as? [String: Any])
        #expect(preferences.count == 2, "the app's own preferences block survives intact")
    }

    @Test("CF-100 the entry names the binary we were actually given")
    func writesTheRunningBinary() throws {
        let home = try FakeHome("path")
        defer { home.cleanup() }

        MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)

        let servers = try #require(try home.json(at: Self.desktopConfig)["mcpServers"] as? [String: Any])
        let entry = try #require(servers["memoir"] as? [String: Any])
        #expect(entry["command"] as? String == home.binary.path,
                "a user running Memoir from somewhere other than /Applications must get their own copy")
    }

    // MARK: - The two files that are not the same file

    @Test("CF-100 Claude Desktop and Claude Code are connected separately")
    func desktopAndCodeAreDistinct() throws {
        let home = try FakeHome("two-files")
        defer { home.cleanup() }

        MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)

        // Connecting the chat app must say nothing about the coding agent. This is the exact
        // shape of the original report: registered in one, reported missing by the other.
        let code = MCPInstaller.status(of: try surface("claude-code"), home: home.root, binary: home.binary)
        #expect(code != .connected)

        MCPInstaller.connect(try surface("claude-code"), home: home.root, binary: home.binary)
        #expect(MCPInstaller.status(of: try surface("claude-code"),
                                    home: home.root, binary: home.binary) == .connected)
        #expect(MCPInstaller.status(of: try surface("claude-desktop"),
                                    home: home.root, binary: home.binary) == .connected)
    }

    @Test("CF-100 Claude Code's per-project nesting is not mistaken for a connection")
    func projectNestingIsNotUserScope() throws {
        let home = try FakeHome("nested")
        defer { home.cleanup() }

        // A server registered inside one project is not registered for the user. Reporting
        // this as connected would leave the user with a green tick and no memory.
        try home.write("""
        {"projects":{"/some/dir":{"mcpServers":{"memoir":{"command":"\(home.binary.path)"}}}}}
        """, to: ".claude.json")

        #expect(MCPInstaller.status(of: try surface("claude-code"),
                                    home: home.root, binary: home.binary) == .notConnected)
    }

    // MARK: - Paths that stopped being true

    @Test("CF-100 an entry pointing at a moved app reads as stale, not as connected")
    func detectsMovedApp() throws {
        let home = try FakeHome("moved")
        defer { home.cleanup() }

        try home.write("""
        {"mcpServers":{"memoir":{"command":"/Applications/Memoir.app/Contents/MacOS/memoir-mcp"}}}
        """, to: Self.desktopConfig)

        let status = MCPInstaller.status(of: try surface("claude-desktop"),
                                         home: home.root, binary: home.binary)
        #expect(status == .stale(recorded: "/Applications/Memoir.app/Contents/MacOS/memoir-mcp"))

        // And connecting repairs it in place.
        MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)
        #expect(MCPInstaller.status(of: try surface("claude-desktop"),
                                    home: home.root, binary: home.binary) == .connected)
    }

    @Test("a server somebody else installed is left exactly where it is")
    func doesNotTouchOtherServers() throws {
        let home = try FakeHome("someone-elses-server")
        defer { home.cleanup() }

        // Connecting Memoir adds one key. It has never been this code's business to remove
        // anything it did not install, whatever the entry happens to be called.
        try home.write("""
        {"mcpServers":{"notes":{"command":"\(home.binary.path)"}}}
        """, to: Self.desktopConfig)

        let outcome = MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)
        #expect(outcome.removedLegacy.isEmpty)
        let servers = try #require(try home.json(at: Self.desktopConfig)["mcpServers"] as? [String: Any])
        #expect(servers["notes"] != nil)
    }

    // MARK: - Files we decline to touch

    @Test("CF-100 a settings file with comments in it is reported, never rewritten")
    func refusesToRewriteJSONWithComments() throws {
        let home = try FakeHome("jsonc")
        defer { home.cleanup() }

        // Zed's settings file allows comments. `JSONSerialization` cannot parse it, and a
        // writer that read that failure as "empty" would replace a hand-annotated settings
        // file with one containing only our entry.
        let original = """
        {
          // the size I actually like
          "buffer_font_size": 15
        }
        """
        try home.write(original, to: ".config/zed/settings.json")

        let zed = try surface("zed")
        let status = MCPInstaller.status(of: zed, home: home.root, binary: home.binary)
        guard case .unreadable = status else {
            Issue.record("a commented settings file must read as unreadable, got \(status)")
            return
        }

        let outcome = MCPInstaller.connect(zed, home: home.root, binary: home.binary)
        #expect(!outcome.succeeded)
        let after = try String(contentsOf: home.root.appending(path: ".config/zed/settings.json"),
                               encoding: .utf8)
        #expect(after == original, "the user's file is byte-for-byte untouched")
    }

    @Test("CF-100 Zed is offered its own key, not Claude's")
    func zedUsesContextServers() throws {
        let home = try FakeHome("zed-key")
        defer { home.cleanup() }
        try home.write("{}", to: ".config/zed/settings.json")

        MCPInstaller.connect(try surface("zed"), home: home.root, binary: home.binary)

        let root = try home.json(at: ".config/zed/settings.json")
        #expect(root["context_servers"] != nil, "Zed does not read mcpServers")
        #expect(root["mcpServers"] == nil)
    }

    // MARK: - Getting back out

    @Test("CF-100 disconnecting removes only our entry")
    func disconnectIsSurgical() throws {
        let home = try FakeHome("disconnect")
        defer { home.cleanup() }

        try home.write("""
        {"mcpServers":{"obsidian":{"command":"npx"}},"preferences":{"a":1}}
        """, to: Self.desktopConfig)

        let desktop = try surface("claude-desktop")
        MCPInstaller.connect(desktop, home: home.root, binary: home.binary)
        MCPInstaller.disconnect(desktop, home: home.root)

        let root = try home.json(at: Self.desktopConfig)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        #expect(servers["memoir"] == nil)
        #expect(servers["obsidian"] != nil)
        #expect(root["preferences"] != nil)
    }

    // MARK: - Not making things worse

    @Test("CF-100 the file is backed up before it is first changed")
    func backsUpBeforeFirstWrite() throws {
        let home = try FakeHome("backup")
        defer { home.cleanup() }

        let original = #"{"mcpServers":{"obsidian":{"command":"npx"}}}"#
        try home.write(original, to: Self.desktopConfig)

        MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)

        let backup = home.root.appending(path: Self.desktopConfig + ".memoir-backup")
        let saved = try String(contentsOf: backup, encoding: .utf8)
        #expect(saved.contains("obsidian"))
        #expect(!saved.contains("memoir"), "the backup is the file as it was before we touched it")
    }

    @Test("CF-100 connecting twice changes nothing the second time")
    func isIdempotent() throws {
        let home = try FakeHome("idempotent")
        defer { home.cleanup() }
        let desktop = try surface("claude-desktop")

        MCPInstaller.connect(desktop, home: home.root, binary: home.binary)
        let first = try Data(contentsOf: home.root.appending(path: Self.desktopConfig))
        MCPInstaller.connect(desktop, home: home.root, binary: home.binary)
        let second = try Data(contentsOf: home.root.appending(path: Self.desktopConfig))

        #expect(first == second)
    }

    @Test("CF-100 a config that is not an object at all is refused, not overwritten")
    func survivesGarbage() throws {
        let home = try FakeHome("garbage")
        defer { home.cleanup() }

        try home.write("[1, 2, 3]", to: Self.desktopConfig)
        let outcome = MCPInstaller.connect(try surface("claude-desktop"), home: home.root, binary: home.binary)

        // An array is valid JSON and not a config. Writing our key into it would mean
        // discarding whatever it was.
        #expect(!outcome.succeeded)
        let after = try String(contentsOf: home.root.appending(path: Self.desktopConfig), encoding: .utf8)
        #expect(after == "[1, 2, 3]")
    }

    @Test("CF-100 a client that was never installed is not invented")
    func absentClientIsReportedAbsent() throws {
        let home = try FakeHome("bare")
        defer { home.cleanup() }

        let findings = MCPInstaller.survey(home: home.root, binary: home.binary)
        #expect(findings.count == MCPInstaller.surfaces.count)
        #expect(findings.allSatisfy { $0.status == .clientNotFound })
        #expect(findings.allSatisfy { !$0.needsWork },
                "an app the user does not have is not work outstanding")
    }

    @Test("CF-100 an empty config file is a starting point, not damage")
    func emptyFileIsNotUnreadable() throws {
        let home = try FakeHome("empty")
        defer { home.cleanup() }
        try home.write("", to: Self.desktopConfig)

        #expect(MCPInstaller.status(of: try surface("claude-desktop"),
                                    home: home.root, binary: home.binary) == .notConnected)
        #expect(MCPInstaller.connect(try surface("claude-desktop"),
                                     home: home.root, binary: home.binary).succeeded)
    }

    // MARK: - The skill

    @Test("CF-100 the skill lands where Claude Code looks for it")
    func installsSkill() throws {
        let home = try FakeHome("skill")
        defer { home.cleanup() }

        let source = home.root.appending(path: "bundle/Skills/memoir")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "# Memoir\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let outcome = SkillInstaller.install(from: source, home: home.root)
        guard case .installed(let url) = outcome else {
            Issue.record("expected a first install, got \(outcome)")
            return
        }
        #expect(url.path.hasSuffix(".claude/skills/memoir"))
        #expect(FileManager.default.fileExists(atPath: url.appending(path: "SKILL.md").path))

        // Running it again with the same content must not churn the user's directory.
        #expect(SkillInstaller.install(from: source, home: home.root) == .alreadyCurrent(url))
    }

    @Test("CF-100 an edited skill is replaced but kept")
    func keepsTheSkillItReplaces() throws {
        let home = try FakeHome("skill-edit")
        defer { home.cleanup() }

        let source = home.root.appending(path: "bundle/Skills/memoir")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "# new\n".write(to: source.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)

        let destination = home.root.appending(path: SkillInstaller.relativeDestination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "# mine, edited\n".write(to: destination.appending(path: "SKILL.md"),
                                     atomically: true, encoding: .utf8)

        guard case .updated(_, let backup) = SkillInstaller.install(from: source, home: home.root) else {
            Issue.record("expected an update")
            return
        }
        let kept = try String(contentsOf: backup.appending(path: "SKILL.md"), encoding: .utf8)
        #expect(kept == "# mine, edited\n", "an edit the user made is recoverable")
    }

    // MARK: - Surviving a move

    @Test("CF-100 a moved app repoints what it had, and connects nothing it had not")
    func repairsOnlyWhatWasAlreadyThere() throws {
        let home = try FakeHome("repair")
        defer { home.cleanup() }

        // One client connected to where Memoir used to live, one client installed and never
        // connected. A launch-time repair must fix the first and stay out of the second.
        try home.write("""
        {"mcpServers":{"memoir":{"command":"/Volumes/Install/Memoir.app/Contents/MacOS/memoir-mcp"}}}
        """, to: Self.desktopConfig)
        try FileManager.default.createDirectory(at: home.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)

        let outcomes = MCPInstaller.repairStalePaths(home: home.root, binary: home.binary)

        #expect(outcomes.count == 1)
        #expect(outcomes.first?.surface.id == "claude-desktop")
        #expect(MCPInstaller.status(of: try surface("claude-desktop"),
                                    home: home.root, binary: home.binary) == .connected)
        #expect(MCPInstaller.status(of: try surface("claude-code"),
                                    home: home.root, binary: home.binary) == .notConnected,
                "being connected once is not permission to be connected everywhere later")
        #expect(!FileManager.default.fileExists(atPath: home.root.appending(path: ".claude.json").path),
                "a repair never creates a config file that was not there")
    }

    @Test("CF-100 a dev build does not steal the config from an installed copy")
    func doesNotRepointAtAStillLivingBinary() throws {
        let home = try FakeHome("dev-build")
        defer { home.cleanup() }

        // A second, working copy: what /Applications holds while the developer runs one out
        // of build/. Repointing here would break the user's agents the next time build/ is
        // cleaned, and they would have no idea why.
        let installed = home.root.appending(path: "Applications/Memoir.app/Contents/MacOS/memoir-mcp")
        try home.write("""
        {"mcpServers":{"memoir":{"command":"\(installed.path)"}}}
        """, to: Self.desktopConfig)

        let devBuild = home.root.appending(path: "build/Memoir.app/Contents/MacOS/memoir-mcp")
        try FileManager.default.createDirectory(at: devBuild.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: devBuild)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devBuild.path)

        #expect(MCPInstaller.repairStalePaths(home: home.root, binary: devBuild).isEmpty)

        let servers = try #require(try home.json(at: Self.desktopConfig)["mcpServers"] as? [String: Any])
        let entry = try #require(servers["memoir"] as? [String: Any])
        #expect(entry["command"] as? String == installed.path,
                "the installed copy keeps the config; only an explicit Repair may move it")
    }

    // MARK: - Not asking twelve times

    private static let claudeSettings = ".claude/settings.json"

    /// Every rule the installer should be putting on the allowlist.
    private var readOnlyRules: Set<String> {
        Set(MemoirTools.readOnlyPermissionRules(server: MCPInstaller.serverName))
    }

    @Test("CF-100 connecting Claude Code pre-approves the tools that only read")
    func preapprovesReadOnlyTools() throws {
        let home = try FakeHome("preapprove")
        defer { home.cleanup() }
        try FileManager.default.createDirectory(at: home.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)

        let outcome = MCPInstaller.connect(try surface("claude-code"),
                                           home: home.root, binary: home.binary)

        #expect(outcome.succeeded)
        #expect(outcome.preapproval == .granted(count: MemoirTools.readOnly.count))

        let permissions = try #require(try home.json(at: Self.claudeSettings)["permissions"] as? [String: Any])
        let allow = Set(try #require(permissions["allow"] as? [String]))
        #expect(allow == readOnlyRules,
                "the point of connecting is answers, not twelve dialogs before the first one")
    }

    @Test("CF-100 the tool that stages something keeps its prompt")
    func doesNotPreapproveProposeMemory() throws {
        let home = try FakeHome("staging-stays")
        defer { home.cleanup() }
        try FileManager.default.createDirectory(at: home.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)

        MCPInstaller.connect(try surface("claude-code"), home: home.root, binary: home.binary)

        let permissions = try #require(try home.json(at: Self.claudeSettings)["permissions"] as? [String: Any])
        let allow = Set(try #require(permissions["allow"] as? [String]))
        // Silence bought for reads is not silence bought for everything. `propose_memory`
        // produces something the user is later asked about, and pre-approving it would decide
        // on their behalf that they did not need to see it happen.
        #expect(!allow.contains("mcp__memoir__propose_memory"))
        #expect(allow.count == MemoirTools.readOnly.count)
    }

    @Test("CF-100 an existing settings file keeps every rule and every other key")
    func mergesIntoExistingSettings() throws {
        let home = try FakeHome("settings-merge")
        defer { home.cleanup() }
        // A real settings.json: someone else's permissions, a deny list, and unrelated keys
        // the user cares about more than they care about us.
        try home.write("""
        {
          "model": "opus",
          "permissions": {
            "allow": ["Bash(swift build *)", "mcp__other__thing"],
            "deny": ["Bash(rm *)"]
          },
          "enabledPlugins": {"something": true}
        }
        """, to: Self.claudeSettings)

        MCPInstaller.connect(try surface("claude-code"), home: home.root, binary: home.binary)

        let root = try home.json(at: Self.claudeSettings)
        #expect(root["model"] as? String == "opus")
        #expect(root["enabledPlugins"] as? [String: Any] != nil)

        let permissions = try #require(root["permissions"] as? [String: Any])
        let allow = Set(try #require(permissions["allow"] as? [String]))
        #expect(allow.isSuperset(of: readOnlyRules))
        #expect(allow.contains("Bash(swift build *)"))
        #expect(allow.contains("mcp__other__thing"))
        #expect(permissions["deny"] as? [String] == ["Bash(rm *)"],
                "a deny list is the one thing an installer must never touch")
    }

    @Test("CF-100 connecting twice adds nothing the second time")
    func preapprovalIsIdempotent() throws {
        let home = try FakeHome("preapprove-idempotent")
        defer { home.cleanup() }
        try FileManager.default.createDirectory(at: home.root.appending(path: ".claude"),
                                                withIntermediateDirectories: true)

        MCPInstaller.connect(try surface("claude-code"), home: home.root, binary: home.binary)
        let second = MCPInstaller.connect(try surface("claude-code"), home: home.root, binary: home.binary)

        #expect(second.preapproval == .alreadyPresent)
        let permissions = try #require(try home.json(at: Self.claudeSettings)["permissions"] as? [String: Any])
        let allow = try #require(permissions["allow"] as? [String])
        #expect(allow.count == Set(allow).count, "a re-connect must not stack duplicate rules")
    }

    @Test("CF-100 a settings file that cannot be parsed is reported, never overwritten")
    func leavesUnparseableSettingsAlone() throws {
        let home = try FakeHome("settings-comments")
        defer { home.cleanup() }
        // Hand-annotated settings. Parsing fails, and a writer that read that as "empty file"
        // would replace the user's configuration with one containing only our allowlist.
        let original = """
        {
          // the model I actually want
          "model": "opus"
        }
        """
        try home.write(original, to: Self.claudeSettings)

        let outcome = MCPInstaller.connect(try surface("claude-code"),
                                           home: home.root, binary: home.binary)

        #expect(outcome.succeeded, "the server still registers; only the allowlist is declined")
        guard case .skipped = outcome.preapproval else {
            Issue.record("expected the settings write to be declined, got \(String(describing: outcome.preapproval))")
            return
        }
        let after = try String(contentsOf: home.root.appending(path: Self.claudeSettings), encoding: .utf8)
        #expect(after == original, "not one byte of a file we could not parse")
    }

    @Test("CF-100 disconnecting takes the allowlist back out with it")
    func disconnectRevokesPreapproval() throws {
        let home = try FakeHome("revoke")
        defer { home.cleanup() }
        try home.write("""
        {"permissions":{"allow":["Bash(swift build *)"]}}
        """, to: Self.claudeSettings)

        let claudeCode = try surface("claude-code")
        MCPInstaller.connect(claudeCode, home: home.root, binary: home.binary)
        MCPInstaller.disconnect(claudeCode, home: home.root)

        let permissions = try #require(try home.json(at: Self.claudeSettings)["permissions"] as? [String: Any])
        let allow = Set(try #require(permissions["allow"] as? [String]))
        #expect(allow.isDisjoint(with: readOnlyRules),
                "standing permission for a server you removed is a rule nobody agreed to keep")
        #expect(allow.contains("Bash(swift build *)"), "and everything else stays")
    }

    @Test("CF-100 clients with their own approval model are not pre-empted")
    func onlyClaudeCodeHasAPermissionsFile() throws {
        // Cursor and Windsurf decide this themselves. Writing an allowlist into a client whose
        // rules we are guessing at is how an installer ends up corrupting a file it did not
        // understand, and a permission we were not asked to grant.
        let withPermissions = MCPInstaller.surfaces.filter { $0.permissionsPath != nil }
        #expect(withPermissions.map(\.id) == ["claude-code"])
    }

    @Test("CF-100 the advertised tools and the pre-approved ones come from one list")
    func catalogAndAllowlistCannotDrift() {
        // The division has to hold in both directions: everything advertised is accounted for,
        // and nothing is quietly in both halves. Two hand-kept copies of this would drift into
        // a tool that is documented as read-only and prompted for anyway.
        #expect(Set(MemoirTools.all) == Set(MemoirTools.readOnly).union(MemoirTools.staging))
        #expect(Set(MemoirTools.readOnly).isDisjoint(with: Set(MemoirTools.staging)))
        #expect(MemoirTools.all.count == 12)
        #expect(MemoirTools.readOnly.count == 11)
    }

    // MARK: - Finding ourselves

    @Test("CF-100 the binary is resolved from the bundle that is running, wherever it sits")
    func resolvesBinaryFromRunningBundle() throws {
        let home = try FakeHome("resolve")
        defer { home.cleanup() }

        // The app installed anywhere at all: the point is that /Applications is not assumed.
        let app = home.root.appending(path: "Users/someone/Applications/Memoir.app")
        let inside = app.appending(path: "Contents/MacOS/memoir-mcp")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: inside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inside.path)

        #expect(MCPInstaller.bundledBinary(bundleURL: app)?.path == inside.path)
    }

    @Test("CF-100 an incomplete build resolves to nothing rather than to a plausible lie")
    func missingBinaryIsNil() throws {
        let home = try FakeHome("no-binary")
        defer { home.cleanup() }

        let app = home.root.appending(path: "Empty.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        // Writing a path that does not exist would give every client a server that fails to
        // launch, which is harder to diagnose than a build that says it is incomplete.
        #expect(MCPInstaller.bundledBinary(bundleURL: app) == nil)
    }

    @Test("CF-100 the skill path in the bundle is the one the build script writes")
    func skillPathMatchesTheBuildScript() throws {
        // A consistency check across the language boundary. `SkillInstaller` reads a path that
        // only `build-app.sh` ever creates, and nothing else would notice the day one of them
        // moves: the symptom is an install action that reports success and copies nothing.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Integration
            .deletingLastPathComponent()   // MemoirKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let script = try String(contentsOf: repoRoot.appending(path: "Scripts/build-app.sh"),
                                encoding: .utf8)

        let home = try FakeHome("skill-path")
        defer { home.cleanup() }
        let app = home.root.appending(path: "Memoir.app")
        let skill = app.appending(path: "Contents/Resources/Skills/memoir")
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)

        let resolved = try #require(SkillInstaller.bundledSkill(bundleURL: app))
        let relative = resolved.path.replacingOccurrences(of: app.path + "/", with: "")
        #expect(relative == "Contents/Resources/Skills/memoir")
        #expect(script.contains(relative),
                "build-app.sh no longer writes the path SkillInstaller reads")
    }
}
