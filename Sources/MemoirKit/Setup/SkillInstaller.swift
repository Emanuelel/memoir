import Foundation

/// Installs the agent skill that tells a model when to reach for Memoir.
///
/// The MCP server and the skill are two different things, and shipping only the first is how
/// this looks broken. The server hands an agent twelve tools; the skill is the paragraph that
/// says *before you assert something about the user's projects, look it up*. Without it a model
/// has the tools and no reason to prefer them over guessing, which reads from the outside as a
/// memory that does not work.
///
/// Claude Code only. Claude Desktop does not read `~/.claude/skills`; its equivalent arrives
/// through plugins, which is a distribution channel rather than a directory we can write.
public enum SkillInstaller {

    /// Where Claude Code looks for user-scope skills.
    public static let relativeDestination = ".claude/skills/memoir"

    /// What an install attempt did.
    public enum Outcome: Sendable, Equatable {
        /// Nothing shipped in the bundle to install. Not an error the user caused.
        case notBundled
        /// Written for the first time.
        case installed(URL)
        /// Already there, byte for byte. Nothing was touched.
        case alreadyCurrent(URL)
        /// Replaced an older or edited copy; the previous one is at the second URL.
        case updated(URL, backup: URL)
        case failed(String)
    }

    /// Copies the bundled skill into the user's skills directory.
    ///
    /// Replaces rather than merges, because a skill is a document we author and ship, not user
    /// data. But it keeps the previous copy, because a user who edited theirs deserves to get it
    /// back rather than to discover the edit is gone.
    @discardableResult
    public static func install(
        from source: URL? = bundledSkill(),
        home: URL = MCPInstaller.defaultHome()
    ) -> Outcome {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            return .notBundled
        }
        let manager = FileManager.default
        let destination = home.appending(path: relativeDestination)

        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)

            if manager.fileExists(atPath: destination.path) {
                if directoriesMatch(source, destination) { return .alreadyCurrent(destination) }
                let backup = destination.appendingPathExtension("previous")
                try? manager.removeItem(at: backup)
                try manager.moveItem(at: destination, to: backup)
                try manager.copyItem(at: source, to: destination)
                return .updated(destination, backup: backup)
            }

            try manager.copyItem(at: source, to: destination)
            return .installed(destination)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Whether two skill directories hold the same files with the same contents.
    ///
    /// Compares contents rather than modification dates: a copy has a fresh mtime the moment it
    /// lands, so a date comparison would report every freshly installed skill as out of date and
    /// rewrite it on every launch.
    static func directoriesMatch(_ a: URL, _ b: URL) -> Bool {
        let manager = FileManager.default
        guard let left = try? manager.contentsOfDirectory(atPath: a.path).sorted(),
              let right = try? manager.contentsOfDirectory(atPath: b.path).sorted(),
              left == right
        else { return false }

        for name in left {
            let leftURL = a.appending(path: name)
            let rightURL = b.appending(path: name)
            var leftIsDirectory: ObjCBool = false
            var rightIsDirectory: ObjCBool = false
            manager.fileExists(atPath: leftURL.path, isDirectory: &leftIsDirectory)
            manager.fileExists(atPath: rightURL.path, isDirectory: &rightIsDirectory)
            guard leftIsDirectory.boolValue == rightIsDirectory.boolValue else { return false }

            if leftIsDirectory.boolValue {
                guard directoriesMatch(leftURL, rightURL) else { return false }
            } else {
                guard let l = try? Data(contentsOf: leftURL),
                      let r = try? Data(contentsOf: rightURL), l == r
                else { return false }
            }
        }
        return true
    }

    /// The skill directory inside the running app bundle, if the build put one there.
    ///
    /// `Scripts/build-app.sh` copies `Skills/memoir/` to exactly this path, before signing:
    /// Resources are sealed by the signature, so anything added afterwards invalidates the
    /// bundle. The two must not drift; a mismatch shows up as an "install the skill" button
    /// that reports success and installs nothing.
    public static func bundledSkill(bundleURL: URL = Bundle.main.bundleURL) -> URL? {
        let url = bundleURL.appending(path: "Contents/Resources/Skills/memoir")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
