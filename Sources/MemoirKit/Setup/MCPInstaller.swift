import Foundation

/// Wires Memoir's MCP server into the agent clients the user already has.
///
/// There is no global MCP registry on macOS. Every client reads its own file, and for
/// Claude alone that is two files that know nothing about each other: the desktop chat app
/// reads `claude_desktop_config.json`, while Claude Code reads `~/.claude.json`. Registering
/// with one and expecting the other to notice is the single most common way this feature
/// appears broken: it is how the author's own first test failed, with Claude correctly
/// reporting that it could not see a server that was, in the other file, plainly there.
///
/// So this does not "install the MCP". It connects a *set* of surfaces, names each one, and
/// reports on each independently.
public enum MCPInstaller {

    // MARK: - What a surface is

    /// The key an agent client files its servers under.
    ///
    /// Almost everything copied Claude Desktop's `mcpServers`. Zed did not.
    public enum ConfigShape: String, Sendable {
        case mcpServers
        case contextServers = "context_servers"
    }

    /// One agent client that can be taught to read Memoir's memory.
    public struct Surface: Sendable, Identifiable, Equatable {
        public let id: String
        /// What the user calls it.
        public let name: String
        /// Why connecting this one is worth doing, in the user's terms.
        public let detail: String
        /// Config file, relative to the home directory.
        public let path: String
        public let shape: ConfigShape
        /// Whether the client must be restarted before it notices.
        public let needsRestart: Bool
        /// Whether this client's config format tolerates `//` comments.
        ///
        /// JSON with comments cannot be round-tripped by `JSONSerialization`: parsing fails,
        /// and a writer that treated that failure as "empty file" would replace a settings
        /// file the user had hand-annotated with one containing only our entry. Surfaces
        /// flagged here are detected and offered a snippet to paste, never written blind.
        public let toleratesComments: Bool

        /// A path whose existence proves the client is installed, when the config file's own
        /// directory does not.
        ///
        /// Most clients keep their config inside a folder of their own, so the folder is the
        /// evidence. Claude Code does not: `~/.claude.json` sits at the root of the home
        /// directory, which exists on every Mac ever made. Without this, Claude Code reported
        /// itself installed on a machine that had never heard of it.
        public let presencePath: String?

        /// Where this client keeps its tool-permission rules, when that is a *different* file
        /// from the one servers are registered in.
        ///
        /// The same split that this type's header comment is about, one layer up. Registering
        /// the server teaches Claude Code that Memoir exists; it says nothing about whether
        /// calling it needs asking first, and that answer lives in `~/.claude/settings.json`,
        /// a file `claude mcp add` never touches. Connect one and not the other and the
        /// feature works, in the sense that every single lookup stops to ask permission.
        ///
        /// Nil for clients that decide this some other way. Cursor and Windsurf have their own
        /// approval models and are not ours to pre-empt.
        public let permissionsPath: String?

        public init(
            id: String,
            name: String,
            detail: String,
            path: String,
            shape: ConfigShape,
            needsRestart: Bool,
            toleratesComments: Bool,
            presencePath: String? = nil,
            permissionsPath: String? = nil
        ) {
            self.id = id
            self.name = name
            self.detail = detail
            self.path = path
            self.shape = shape
            self.needsRestart = needsRestart
            self.toleratesComments = toleratesComments
            self.presencePath = presencePath
            self.permissionsPath = permissionsPath
        }

        /// Absolute config location under a given home.
        public func configURL(home: URL) -> URL { home.appending(path: path) }

        /// The path that decides whether this client is on the machine at all.
        public func presenceURL(home: URL) -> URL {
            if let presencePath { return home.appending(path: presencePath) }
            return configURL(home: home).deletingLastPathComponent()
        }
    }

    /// Every client worth offering, in the order a user is likely to care about them.
    ///
    /// Deliberately a list rather than a probe of what is installed: a surface whose config
    /// file does not exist yet is still worth connecting if the user is about to install the
    /// client, and a client can be present with no config written yet. Presence is decided by
    /// ``status(of:home:binary:)``, not by membership here.
    public static let surfaces: [Surface] = [
        Surface(
            id: "claude-desktop",
            name: "Claude Desktop",
            detail: "The chat app. This is the one most people mean by \u{201c}Claude\u{201d}.",
            path: "Library/Application Support/Claude/claude_desktop_config.json",
            shape: .mcpServers,
            needsRestart: true,
            toleratesComments: false
        ),
        Surface(
            id: "claude-code",
            name: "Claude Code",
            detail: "The coding agent, in the terminal and inside Claude Desktop. A separate file from the chat app.",
            path: ".claude.json",
            shape: .mcpServers,
            needsRestart: true,
            toleratesComments: false,
            presencePath: ".claude",
            permissionsPath: ".claude/settings.json"
        ),
        Surface(
            id: "cursor",
            name: "Cursor",
            detail: "Cursor's global MCP configuration.",
            path: ".cursor/mcp.json",
            shape: .mcpServers,
            needsRestart: true,
            toleratesComments: false
        ),
        Surface(
            id: "windsurf",
            name: "Windsurf",
            detail: "Windsurf's MCP configuration.",
            path: ".codeium/windsurf/mcp_config.json",
            shape: .mcpServers,
            needsRestart: true,
            toleratesComments: false
        ),
        Surface(
            id: "zed",
            name: "Zed",
            detail: "Zed calls them context servers, and its settings file allows comments.",
            path: ".config/zed/settings.json",
            shape: .contextServers,
            needsRestart: false,
            toleratesComments: true
        ),
    ]

    /// The name Memoir files itself under. Also the name we look for when checking.
    public static let serverName = "memoir"

    /// Server names this app has shipped under before now.
    ///

    // MARK: - What we found

    /// The state of one surface, as of a moment.
    public enum Status: Sendable, Equatable {
        /// No config file, and no sign of the client. Nothing to do unless asked.
        case clientNotFound
        /// The client is here; Memoir is not in its config.
        case notConnected
        /// Connected, and the recorded path is the binary we would write today.
        case connected
        /// Connected, but pointing somewhere else: a moved app, or a previous version.
        ///
        /// Carries the path actually on file so the user can be told what it says rather
        /// than merely that it is wrong.
        case stale(recorded: String)
        /// The file exists and could not be parsed. Never written to in this state.
        case unreadable(reason: String)
    }

    /// A surface paired with what we found there.
    public struct Finding: Sendable, Identifiable, Equatable {
        public let surface: Surface
        public let status: Status
        public var id: String { surface.id }

        /// Whether connecting would change anything.
        public var needsWork: Bool {
            switch status {
            case .notConnected: return true
            case .stale: return true
            case .connected, .clientNotFound, .unreadable: return false
            }
        }
    }

    // MARK: - Looking

    /// Reads every surface and reports what is there. Never writes.
    public static func survey(home: URL = defaultHome(), binary: URL) -> [Finding] {
        surfaces.map { Finding(surface: $0, status: status(of: $0, home: home, binary: binary)) }
    }

    /// The state of a single surface.
    static func status(of surface: Surface, home: URL, binary: URL) -> Status {
        let url = surface.configURL(home: home)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A missing config is not the same as a missing client: Cursor writes its
            // mcp.json only once something has been added. The client's own directory is the
            // evidence, since that is created on first launch.
            return FileManager.default.fileExists(atPath: surface.presenceURL(home: home).path)
                ? .notConnected
                : .clientNotFound
        }

        guard let data = try? Data(contentsOf: url) else {
            return .unreadable(reason: "could not be read")
        }
        // An empty file is a legitimate starting point (several clients touch the file
        // before they ever write to it) and is not something to report as damage.
        if data.isEmpty { return .notConnected }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unreadable(
                reason: surface.toleratesComments
                    ? "contains comments or is not plain JSON, so it cannot be edited safely"
                    : "is not valid JSON"
            )
        }

        guard let servers = root[surface.shape.rawValue] as? [String: Any],
              let entry = servers[serverName] as? [String: Any],
              let command = entry["command"] as? String
        else {
            return .notConnected
        }

        return command == binary.path ? .connected : .stale(recorded: command)
    }

    // MARK: - Writing

    /// What happened to the read-only tools' standing permission.
    public enum Preapproval: Sendable, Equatable {
        /// Rules were added and read back.
        case granted(count: Int)
        /// Every rule was already on file. Nothing was written.
        case alreadyPresent
        /// Deliberately left alone, with a reason worth showing the user.
        case skipped(reason: String)
    }

    /// What a connect attempt did.
    public struct Outcome: Sendable, Equatable {
        public let surface: Surface
        /// Nil on success; a human-readable reason otherwise.
        public let failure: String?
        /// Stale entries under an old product name that were removed on the way through.
        public let removedLegacy: [String]
        /// Whether reading the file back afterwards confirmed the entry.
        public let verified: Bool
        /// What became of the tool allowlist, for a client that keeps one.
        ///
        /// Nil for the clients that do not. Reported separately from ``verified`` because it
        /// is a separate file with a separate way of failing, and a connection that works
        /// while asking permission twelve times is a different outcome from one that does not
        /// work at all: the user should be told which they got.
        public let preapproval: Preapproval?

        public var succeeded: Bool { failure == nil && verified }
    }

    /// Adds Memoir to one surface, preserving everything already in the file.
    ///
    /// Three properties this has to hold, each learned from a way config-writing goes wrong:
    ///
    /// **It merges.** A real `claude_desktop_config.json` holds other people's servers and a
    /// large preferences block the app maintains for itself. Writing a document containing
    /// only our key would take an Obsidian server and every window preference with it.
    ///
    /// **It writes atomically.** Serialising straight over the file leaves a truncated
    /// document if anything interrupts it, and a client that cannot parse its config does not
    /// start degraded: it starts with no servers at all.
    ///
    /// **It reads back.** `~/.claude.json` is not a static file: every running Claude Code
    /// session writes to it, so a correct write can be overwritten seconds later by a session
    /// that had loaded the older copy. The verification result is reported rather than assumed,
    /// which is what lets the UI offer to do it again instead of insisting it worked.
    @discardableResult
    public static func connect(_ surface: Surface, home: URL = defaultHome(), binary: URL) -> Outcome {
        let url = surface.configURL(home: home)

        if case .unreadable(let reason) = status(of: surface, home: home, binary: binary) {
            return Outcome(surface: surface, failure: "\(surface.name)'s config \(reason)",
                           removedLegacy: [], verified: false, preapproval: nil)
        }

        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }

        var servers = root[surface.shape.rawValue] as? [String: Any] ?? [:]

        let removed: [String] = []

        servers[serverName] = ["command": binary.path]
        root[surface.shape.rawValue] = servers

        do {
            try writeAtomically(root, to: url)
        } catch {
            return Outcome(surface: surface, failure: error.localizedDescription,
                           removedLegacy: removed, verified: false, preapproval: nil)
        }

        let verified = status(of: surface, home: home, binary: binary) == .connected
        // Only worth doing once the server is actually registered: standing permission for a
        // server the client cannot see is a line in a settings file and nothing else.
        let preapproval = verified ? preapproveReadOnlyTools(surface, home: home) : nil
        return Outcome(surface: surface, failure: nil, removedLegacy: removed,
                       verified: verified, preapproval: preapproval)
    }

    /// Puts Memoir's read-only tools on a client's allowlist, so lookups stop asking.
    ///
    /// Twelve tools, each prompting until individually approved, is what a new user meets
    /// before they have seen a single answer, and the approving happens in a dialog that
    /// says only that some server would like to run something. That is a bad trade in both
    /// directions: it teaches people to click through permission prompts without reading
    /// them, in exchange for guarding calls that cannot change anything. The database is
    /// opened read-only; there is no state on the other side of these to protect.
    ///
    /// Additive and idempotent. It reads what is there, adds only what is missing, and keeps
    /// every rule the user or another tool put in the file. It never writes `deny`, never
    /// touches a rule that is not ours, and never grants the one tool that stages something.
    ///
    /// Returns nil for a surface with no permissions file of its own.
    @discardableResult
    static func preapproveReadOnlyTools(_ surface: Surface, home: URL) -> Preapproval? {
        guard let permissionsPath = surface.permissionsPath else { return nil }
        let url = home.appending(path: permissionsPath)

        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url) else {
                return .skipped(reason: "\(surface.name)'s settings file could not be read")
            }
            if !data.isEmpty {
                // Same rule as everywhere else here: a file we cannot parse is a file we do
                // not touch. Settings are hand-edited far more often than server registries
                // are, so this branch is the likely one, not the exotic one.
                guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    return .skipped(reason: "\(surface.name)'s settings file is not plain JSON, so it was left alone")
                }
                root = parsed
            }
        }

        var permissions = root["permissions"] as? [String: Any] ?? [:]
        let existing = permissions["allow"] as? [Any] ?? []
        let already = Set(existing.compactMap { $0 as? String })

        let missing = MemoirTools.readOnlyPermissionRules(server: serverName)
            .filter { !already.contains($0) }
        guard !missing.isEmpty else { return .alreadyPresent }

        // Append rather than rebuild, and append the originals rather than the strings we
        // read out of them: the array can hold entries this code does not model, and a
        // rewrite that keeps only what it understood is a rewrite that quietly deletes.
        permissions["allow"] = existing + missing
        root["permissions"] = permissions

        do {
            try writeAtomically(root, to: url)
        } catch {
            return .skipped(reason: "\(surface.name)'s settings file could not be written: \(error.localizedDescription)")
        }

        guard let after = try? Data(contentsOf: url),
              let reread = (try? JSONSerialization.jsonObject(with: after)) as? [String: Any],
              let saved = (reread["permissions"] as? [String: Any])?["allow"] as? [Any],
              missing.allSatisfy(Set(saved.compactMap { $0 as? String }).contains)
        else {
            return .skipped(reason: "\(surface.name)'s settings were written but did not read back")
        }
        return .granted(count: missing.count)
    }

    /// Takes Memoir's rules back off the allowlist, leaving every other rule in place.
    @discardableResult
    static func revokeReadOnlyTools(_ surface: Surface, home: URL) -> Preapproval? {
        guard let permissionsPath = surface.permissionsPath else { return nil }
        let url = home.appending(path: permissionsPath)

        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var permissions = root["permissions"] as? [String: Any],
              let existing = permissions["allow"] as? [Any]
        else { return .alreadyPresent }

        let ours = Set(MemoirTools.readOnlyPermissionRules(server: serverName))
        // Anything that is not one of our rules stays, including entries that are not strings
        // at all. Removing our own is the whole job.
        let kept = existing.filter { entry in
            guard let rule = entry as? String else { return true }
            return !ours.contains(rule)
        }
        guard kept.count != existing.count else { return .alreadyPresent }

        permissions["allow"] = kept
        root["permissions"] = permissions
        do {
            try writeAtomically(root, to: url)
        } catch {
            return .skipped(reason: error.localizedDescription)
        }
        return .granted(count: existing.count - kept.count)
    }

    /// Removes Memoir from one surface, leaving everything else untouched.
    ///
    /// Present because a feature that writes into other applications' configuration and offers
    /// no way back is not one a careful person should agree to.
    @discardableResult
    public static func disconnect(_ surface: Surface, home: URL = defaultHome()) -> Outcome {
        let url = surface.configURL(home: home)
        // Standing permission goes back with the connection that justified it, whatever state
        // the server registry turns out to be in. Leaving the rules behind would mean a user
        // who disconnected Memoir still carries an allowlist for it.
        let revoked = revokeReadOnlyTools(surface, home: home)

        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return Outcome(surface: surface, failure: nil, removedLegacy: [], verified: true,
                           preapproval: revoked)
        }

        guard var servers = root[surface.shape.rawValue] as? [String: Any],
              servers[serverName] != nil
        else {
            return Outcome(surface: surface, failure: nil, removedLegacy: [], verified: true,
                           preapproval: revoked)
        }

        servers.removeValue(forKey: serverName)
        // Leave the container behind rather than deleting an empty `mcpServers`: some clients
        // treat its absence and its emptiness differently, and this is not the place to find
        // out which.
        root[surface.shape.rawValue] = servers

        do {
            try writeAtomically(root, to: url)
        } catch {
            return Outcome(surface: surface, failure: error.localizedDescription,
                           removedLegacy: [], verified: false, preapproval: revoked)
        }
        return Outcome(surface: surface, failure: nil, removedLegacy: [], verified: true,
                       preapproval: revoked)
    }

    /// Repoints entries that already exist at wherever Memoir is now. Never adds one.
    ///
    /// The path in a config file is written once and then left alone, but the app it names can
    /// move: dragged to `~/Applications` rather than `/Applications`, renamed, or replaced by
    /// an update that lands somewhere new. Every entry then points at nothing, and the symptom
    /// is an agent that quietly stops knowing anything, which reads as the memory being empty
    /// rather than the wiring being broken, and sends the user looking in entirely the wrong
    /// place.
    ///
    /// Repairs only. Agreeing to be connected is not agreeing to be connected to more things
    /// later, so a surface the user never chose is never touched here.
    ///
    /// And only when the recorded path is genuinely **dead**. "Points at a different binary"
    /// is not the same as "broken": the moment a developer runs a build out of `build/`, every
    /// config would be repointed at a copy that is deleted on the next clean, silently breaking
    /// the agents of anyone who also has Memoir installed properly. A launch-time repair that
    /// can do that is worse than no repair at all, so this one waits until there is nothing on
    /// the other end. The Repair button in Settings is the deliberate override.
    @discardableResult
    public static func repairStalePaths(home: URL = defaultHome(), binary: URL) -> [Outcome] {
        survey(home: home, binary: binary).compactMap { finding in
            guard case .stale(let recorded) = finding.status,
                  !FileManager.default.isExecutableFile(atPath: recorded)
            else { return nil }
            return connect(finding.surface, home: home, binary: binary)
        }
    }

    /// The JSON a user can paste by hand, for a surface we decline to edit.
    public static func snippet(for surface: Surface, binary: URL) -> String {
        """
        {
          "\(surface.shape.rawValue)": {
            "\(serverName)": {
              "command": "\(binary.path)"
            }
          }
        }
        """
    }

    /// The allowlist a user can paste by hand, for a client whose settings we declined to edit.
    ///
    /// A separate snippet because it is a separate file: the two cannot be merged into one
    /// block to copy, and offering a single snippet that silently covers only half of what is
    /// needed is how someone ends up back at twelve permission prompts wondering what they
    /// did wrong.
    public static func permissionsSnippet(for surface: Surface) -> String? {
        guard surface.permissionsPath != nil else { return nil }
        let rules = MemoirTools.readOnlyPermissionRules(server: serverName)
            .map { "      \"\($0)\"" }
            .joined(separator: ",\n")
        return """
        {
          "permissions": {
            "allow": [
        \(rules)
            ]
          }
        }
        """
    }

    // MARK: - Putting bytes on disk

    /// Serialises and replaces, via a temporary file in the same directory.
    ///
    /// Same-directory matters: a rename across filesystems is a copy, which is not atomic and
    /// gives back exactly the truncated-file case this is here to avoid.
    static func writeAtomically(_ root: [String: Any], to url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)

        // `.sortedKeys` because without it dictionary order is arbitrary per process, and every
        // connect would rewrite the whole file into a new order: noise in a file the user may
        // have in version control.
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        // Back the file up once, before the first time we ever change it. Restoring by hand is
        // only possible if there is something to restore from, and the moment to take a copy is
        // before the first write, not after a bad one.
        let backup = url.appendingPathExtension("memoir-backup")
        if manager.fileExists(atPath: url.path), !manager.fileExists(atPath: backup.path) {
            try? manager.copyItem(at: url, to: backup)
        }

        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).memoir-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temporary, options: .atomic)
        // These files carry API keys for other people's servers. Match the 0600 that Claude
        // Desktop itself uses rather than inheriting whatever the process umask happens to be.
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)

        if manager.fileExists(atPath: url.path) {
            _ = try manager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try manager.moveItem(at: temporary, to: url)
        }
    }

    // MARK: - Where things are

    /// The real home directory.
    ///
    /// Read from the password database rather than `$HOME` for the same reason `Paths` does:
    /// the environment variable can be set to a temporary directory by a well-meaning test
    /// harness while the Foundation APIs carry on reading the real one, and an isolation
    /// mechanism that half works is worse than none. Tests here pass `home:` explicitly.
    public static func defaultHome() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    /// The `memoir-mcp` binary that belongs to the currently running app.
    ///
    /// Derived from the running bundle rather than hardcoded to `/Applications`, because the
    /// path we write is the path a client will exec for as long as the entry lives. A user who
    /// runs Memoir from `~/Applications`, or from the build directory, must get a config that
    /// points at the copy they are actually running.
    ///
    /// Takes a URL rather than a `Bundle` so the resolution can be tested against a synthetic
    /// layout: this is the logic that decides what goes in other people's config files, and
    /// "works on the machine it was written on" is not enough assurance for that.
    public static func bundledBinary(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let candidate = bundleURL.appending(path: "Contents/MacOS/memoir-mcp")
        if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }

        // Running outside an app bundle (the command-line tools, or the test suite), where
        // the executable sits beside its siblings in the build directory.
        let sibling = bundleURL.appending(path: "memoir-mcp")
        return FileManager.default.isExecutableFile(atPath: sibling.path) ? sibling : nil
    }
}
