import Foundation

/// A vault Memoir found on its own, ready to be offered with one click.
public struct DiscoveredVault: Sendable, Equatable, Identifiable {
    /// Where it lives. Standardised, so two sources naming the same folder collapse to one.
    public let url: URL
    /// The folder's own name: what the user calls this vault in Obsidian.
    public let name: String
    /// How Memoir came to know about it. Shown, because a user is entitled to know why
    /// their notes folder is being offered to something that reads their screen.
    public let source: Source
    /// Markdown files found, bounded. Zero means "a folder, but not a vault".
    public let noteCount: Int

    public var id: String { url.path }

    public enum Source: String, Sendable, Equatable {
        /// Obsidian's own registry of open vaults. Authoritative.
        case obsidian
        /// An Obsidian MCP server already configured in a Claude client.
        case mcpConfig
        /// A conventional location, found by looking.
        case conventional

        public var label: String {
            switch self {
            case .obsidian: return "from Obsidian"
            case .mcpConfig: return "from your Obsidian MCP setup"
            case .conventional: return "found on disk"
            }
        }
    }

    public init(url: URL, name: String, source: Source, noteCount: Int) {
        self.url = url
        self.name = name
        self.source = source
        self.noteCount = noteCount
    }
}

/// Finds the user's Obsidian vaults without asking them to navigate a file dialog.
///
/// This exists because the file picker is a genuinely bad answer here. The most common
/// vault location on a Mac is
/// `~/Library/Mobile Documents/iCloud~md~obsidian/Documents/<name>`, inside `~/Library`,
/// which Finder hides by default, under a folder whose name contains tildes. A user who
/// keeps their notes in iCloud literally cannot click their way to them, and telling
/// somebody to paste a path into ⇧⌘G is an admission that the feature does not work.
///
/// Three sources, best first. Every one of them is a local file Memoir already has
/// permission to read; nothing here talks to a network, a server, or another process.
///
/// **On leveraging an existing Obsidian MCP server:** its *config* is read here, because
/// the vault path is sitting in the arguments and that is free information. Its *tools*
/// are deliberately not called. Doing so would mean shelling out to `npx`, which drags
/// Node into a product whose first hard constraint is zero dependencies, to obtain files
/// Memoir can already open directly and faster. The config is a hint; the filesystem is
/// the source of truth.
public enum VaultDiscovery {

    /// Every vault Memoir can find, best source first, deduplicated, empties dropped.
    ///
    /// - Parameters:
    ///   - home: the home directory to search. Injected so tests can build a fake one.
    ///   - fileManager: injected for the same reason.
    public static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [DiscoveredVault] {
        var found: [DiscoveredVault] = []
        var seen = Set<String>()

        /// True when one path contains the other. Compared with a trailing separator so
        /// `/a/bc` is not read as living inside `/a/b`.
        func nests(_ a: String, _ b: String) -> Bool {
            let x = a.hasSuffix("/") ? a : a + "/"
            let y = b.hasSuffix("/") ? b : b + "/"
            return x.hasPrefix(y) || y.hasPrefix(x)
        }

        func consider(_ path: String, source: DiscoveredVault.Source) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let key = url.resolvingSymlinksInPath().path
            guard !seen.contains(key) else { return }
            // Never offer a vault's parent, or a vault inside one already offered.
            //
            // `~/Documents/Obsidian` is usually the FOLDER OF vaults rather than a vault,
            // and it contains markdown by definition, so a naive scan offers both it and
            // everything under it. Importing the parent would merge every vault into one
            // ontology. Sources run most-authoritative first, so whoever got here first
            // is the one to keep.
            guard !seen.contains(where: { nests(key, $0) }) else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return }
            let notes = markdownCount(in: url, fileManager: fileManager)
            // A folder with no markdown in it is not a vault. Offering one would send a
            // user to import nothing and conclude the feature is broken.
            guard notes > 0 else { return }
            seen.insert(key)
            found.append(DiscoveredVault(
                url: url,
                name: url.lastPathComponent,
                source: source,
                noteCount: notes
            ))
        }

        for path in obsidianRegistryPaths(home: home) { consider(path, source: .obsidian) }
        for path in mcpConfigPaths(home: home) { consider(path, source: .mcpConfig) }
        for path in conventionalPaths(home: home, fileManager: fileManager) {
            consider(path, source: .conventional)
        }
        return found
    }

    // MARK: - Source 1: Obsidian's own registry

    /// Vault paths straight out of `obsidian.json`, most recently opened first.
    ///
    /// Obsidian maintains this itself, so it is both authoritative and free. `ts` is the
    /// last-opened timestamp; ordering by it means the vault the user actually works in
    /// is the one offered first.
    static func obsidianRegistryPaths(home: URL) -> [String] {
        let url = home.appending(path: "Library/Application Support/obsidian/obsidian.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vaults = root["vaults"] as? [String: Any] else { return [] }

        let entries: [(path: String, ts: Double, open: Bool)] = vaults.values.compactMap { raw in
            guard let record = raw as? [String: Any],
                  let path = record["path"] as? String, !path.isEmpty else { return nil }
            return (path, (record["ts"] as? Double) ?? 0, (record["open"] as? Bool) ?? false)
        }
        // Currently-open vaults lead, then most recently opened.
        return entries
            .sorted { a, b in a.open == b.open ? a.ts > b.ts : (a.open && !b.open) }
            .map(\.path)
    }

    // MARK: - Source 2: an Obsidian MCP server the user already configured

    /// Vault paths mentioned by an Obsidian MCP server in any local Claude config.
    ///
    /// If somebody has already wired an Obsidian MCP server into a Claude client, they
    /// have already told a config file where their notes are. Asking them a second time,
    /// through a file dialog that cannot reach the folder, is the kind of thing that makes
    /// software feel like it is not paying attention.
    static func mcpConfigPaths(home: URL) -> [String] {
        let configs = [
            "Library/Application Support/Claude/claude_desktop_config.json",
            ".claude.json",
            ".config/claude/mcp.json",
        ].map { home.appending(path: $0) }

        var out: [String] = []
        for config in configs {
            guard let data = try? Data(contentsOf: config),
                  let root = try? JSONSerialization.jsonObject(with: data) else { continue }
            collectVaultPaths(from: root, into: &out)
        }
        return out
    }

    /// Walks any JSON shape looking for `mcpServers` blocks that smell of Obsidian.
    ///
    /// Deliberately structural rather than schema-bound: Claude Desktop keeps servers at
    /// the root, Claude Code nests them per project, and neither layout is ours to depend
    /// on. Recursing costs nothing on files this size and survives both.
    private static func collectVaultPaths(from node: Any, into out: inout [String]) {
        guard let object = node as? [String: Any] else {
            if let array = node as? [Any] {
                for child in array { collectVaultPaths(from: child, into: &out) }
            }
            return
        }
        if let servers = object["mcpServers"] as? [String: Any] {
            for (name, raw) in servers {
                guard let server = raw as? [String: Any] else { continue }
                let command = (server["command"] as? String) ?? ""
                let args = (server["args"] as? [String]) ?? []
                let mentionsObsidian = name.localizedCaseInsensitiveContains("obsidian")
                    || command.localizedCaseInsensitiveContains("obsidian")
                    || args.contains { $0.localizedCaseInsensitiveContains("obsidian") }
                guard mentionsObsidian else { continue }

                // An explicit env var wins; it is the unambiguous statement of intent.
                if let env = server["env"] as? [String: String] {
                    for key in ["OBSIDIAN_VAULT_PATH", "OBSIDIAN_VAULT", "VAULT_PATH"] {
                        if let value = env[key], !value.isEmpty { out.append(value) }
                    }
                }
                // Otherwise the vault is usually just an argument: the one that looks like
                // a path rather than a flag or a package name.
                for arg in args where arg.hasPrefix("/") || arg.hasPrefix("~") {
                    out.append((arg as NSString).expandingTildeInPath)
                }
            }
        }
        for (key, value) in object where key != "mcpServers" {
            collectVaultPaths(from: value, into: &out)
        }
    }

    // MARK: - Source 3: where vaults usually are

    /// Conventional locations, including the iCloud one the file dialog cannot reach.
    static func conventionalPaths(home: URL, fileManager: FileManager) -> [String] {
        var out: [String] = []
        let iCloud = home.appending(path: "Library/Mobile Documents/iCloud~md~obsidian/Documents")
        // Each child of the iCloud Obsidian folder is a vault in its own right.
        if let children = try? fileManager.contentsOfDirectory(
            at: iCloud, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            out += children.map(\.path)
        }
        for relative in ["Documents/Obsidian", "Obsidian", "Documents/Notes", "Notes"] {
            out.append(home.appending(path: relative).path)
        }
        return out
    }

    // MARK: - Counting

    /// Markdown files in a folder, bounded and shallow-ish.
    ///
    /// Capped because this runs while a settings pane is drawing and a vault can be
    /// enormous; the count only has to distinguish "a vault" from "not a vault" and give
    /// the user something honest to recognise it by.
    static func markdownCount(in url: URL, fileManager: FileManager, cap: Int = 500) -> Int {
        guard let walker = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var count = 0
        for case let item as URL in walker {
            if item.hasDirectoryPath {
                // Never count Memoir's own output, or Obsidian's internals, as evidence
                // that this is a vault worth importing.
                if VaultImporter.skippedFolders.contains(item.lastPathComponent.lowercased()) {
                    walker.skipDescendants()
                }
                continue
            }
            if item.pathExtension.lowercased() == "md" {
                count += 1
                if count >= cap { break }
            }
        }
        return count
    }
}
