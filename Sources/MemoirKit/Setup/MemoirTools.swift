import Foundation

/// The tools Memoir exposes over MCP, divided by what agreeing to one costs the user.
///
/// Lives here rather than beside the catalogue in `MemoirMCP` because two places need the
/// division and neither can own it alone: `ToolCatalog` advertises these over the wire, and
/// ``MCPInstaller`` writes the read-only ones into a client's allowlist at connect time.
/// `MemoirMCP` already depends on `MemoirKit`, so this is the direction that does not invent
/// a cycle.
public enum MemoirTools {

    /// Tools that only read.
    ///
    /// Every one answers out of a database this server opens read-only. A permission prompt
    /// exists to put a decision in front of someone before something happens to them, and
    /// nothing happens to them here, so on these the prompt is pure friction. Twelve tools
    /// asked about one at a time is the first thing a new user meets, at the exact moment
    /// they are deciding whether any of this was worth installing.
    public static let readOnly = [
        "recall", "who_is", "what_happened", "open_commitments", "today",
        "what_changed_since", "prior_art", "working_set", "sources_for", "verify",
        "timesheet",
    ]

    /// Tools that leave something behind.
    ///
    /// `propose_memory` still never writes the database (it stages a suggestion to a review
    /// file), but it is the one call that produces something the user will later be asked
    /// about, so it keeps its prompt. Pre-approving it would mean deciding, on their behalf,
    /// that they do not need to see it happen. Anyone who wants it silent can say so once, in
    /// their own settings; that is not a default to hand out.
    public static let staging = ["propose_memory"]

    /// Every tool, in the order they are advertised.
    public static let all = readOnly + staging

    /// What Claude Code calls one tool in a permission rule: `mcp__<server>__<tool>`.
    public static func permissionRule(_ tool: String, server: String = MCPInstaller.serverName) -> String {
        "mcp__\(server)__\(tool)"
    }

    /// The rules that buy a user silence on everything that only reads.
    public static func readOnlyPermissionRules(server: String = MCPInstaller.serverName) -> [String] {
        readOnly.map { permissionRule($0, server: server) }
    }
}
