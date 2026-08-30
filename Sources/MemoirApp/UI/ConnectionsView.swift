import SwiftUI
import AppKit
import MemoirKit

/// Drives the Connections pane: what is wired up, and what one click would change.
///
/// Lives in the app rather than in MemoirKit because it is the consent layer. Writing into
/// another application's configuration is something to be asked for, once, per client, so the
/// model never connects anything on its own, and every write here is the direct result of a
/// button the user pressed.
@MainActor
final class ConnectionsModel: ObservableObject {

    @Published private(set) var findings: [MCPInstaller.Finding] = []
    /// The last thing that happened, in the user's words.
    @Published var status: String?
    @Published var statusIsProblem: Bool = false
    /// Clients connected in this session that have not been restarted yet.
    @Published private(set) var awaitingRestart: Set<String> = []
    @Published private(set) var skillStatus: String?

    /// The server binary belonging to the copy of Memoir that is running.
    let binary: URL?

    init(binary: URL? = MCPInstaller.bundledBinary()) {
        self.binary = binary
        refresh()
    }

    /// How many clients are present and not yet connected.
    var outstanding: Int { findings.filter(\.needsWork).count }

    /// Whether there is anything on this Mac worth connecting.
    var foundAnyClient: Bool { findings.contains { $0.status != .clientNotFound } }

    func refresh() {
        guard let binary else {
            findings = []
            status = "Memoir cannot find its own MCP server. This build is incomplete."
            statusIsProblem = true
            return
        }
        findings = MCPInstaller.survey(binary: binary)
    }

    func connect(_ surface: MCPInstaller.Surface) {
        guard let binary else { return }
        let outcome = MCPInstaller.connect(surface, binary: binary)
        report(outcome)
        refresh()
    }

    /// Connects everything present that is not already wired up.
    ///
    /// Deliberately skips clients that are not installed. Creating a config file for an app the
    /// user does not have would leave litter in their home directory for a program they never
    /// asked about.
    func connectEverything() {
        guard let binary else { return }
        let targets = findings.filter(\.needsWork).map(\.surface)
        guard !targets.isEmpty else {
            status = "Everything on this Mac is already connected."
            statusIsProblem = false
            return
        }
        var failures: [String] = []
        var connected: [String] = []
        for surface in targets {
            let outcome = MCPInstaller.connect(surface, binary: binary)
            if outcome.succeeded {
                connected.append(surface.name)
                if surface.needsRestart { awaitingRestart.insert(surface.id) }
            } else {
                failures.append(outcome.failure ?? "\(surface.name) could not be verified")
            }
        }
        refresh()
        statusIsProblem = !failures.isEmpty
        status = failures.isEmpty
            ? "Connected \(connected.formattedList())."
            : failures.joined(separator: " ")
    }

    func disconnect(_ surface: MCPInstaller.Surface) {
        let outcome = MCPInstaller.disconnect(surface)
        awaitingRestart.remove(surface.id)
        if let failure = outcome.failure {
            status = failure
            statusIsProblem = true
        } else {
            status = "Removed from \(surface.name). It stops seeing Memoir when it restarts."
            statusIsProblem = false
        }
        refresh()
    }

    /// Puts the paste-it-yourself JSON on the clipboard, for a file we will not edit.
    func copySnippet(for surface: MCPInstaller.Surface) {
        guard let binary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPInstaller.snippet(for: surface, binary: binary), forType: .string)
        status = "Copied. Paste it into \(surface.name)'s settings file yourself."
        statusIsProblem = false
    }

    func installSkill() {
        switch SkillInstaller.install() {
        case .installed(let url):
            skillStatus = "Installed at \(url.path)."
        case .alreadyCurrent:
            skillStatus = "Already up to date."
        case .updated(_, let backup):
            skillStatus = "Updated. Your previous copy is at \(backup.lastPathComponent)."
        case .notBundled:
            skillStatus = "This build did not ship the skill."
        case .failed(let reason):
            skillStatus = reason
        }
    }

    private func report(_ outcome: MCPInstaller.Outcome) {
        if let failure = outcome.failure {
            status = failure
            statusIsProblem = true
            return
        }
        statusIsProblem = !outcome.verified
        if !outcome.verified {
            // The honest version of this. `~/.claude.json` is written by every running Claude
            // Code session, so a correct write can be undone seconds later by a session that
            // had already loaded the older copy.
            status = "\(outcome.surface.name) was written but did not read back. Something else is writing that file. Try again with it closed."
            return
        }
        if outcome.surface.needsRestart { awaitingRestart.insert(outcome.surface.id) }
        var line = "Connected \(outcome.surface.name)."
        if !outcome.removedLegacy.isEmpty {
            line += " Removed the dead \(outcome.removedLegacy.formattedList()) entry left by the rename."
        }
        switch outcome.preapproval {
        case .granted(let count):
            line += " Approved \(count) read-only tools, so lookups will not stop to ask."
        case .skipped(let reason):
            // Worth saying out loud rather than swallowing: the connection works, and the
            // user is about to be asked about every tool one at a time. Better they know why.
            line += " Its settings were left alone (\(reason)), so it will ask before each lookup."
        case .alreadyPresent, .none:
            break
        }
        status = line
        statusIsProblem = false
    }
}

private extension Array where Element == String {
    /// "a", "a and b", "a, b and c".
    func formattedList() -> String {
        switch count {
        case 0: return ""
        case 1: return self[0]
        default: return dropLast().joined(separator: ", ") + " and " + self[count - 1]
        }
    }
}

// MARK: - The pane

/// The list of clients, shared by Settings and by onboarding so the two can never drift.
struct ConnectionsPanel: View {
    @ObservedObject var model: ConnectionsModel
    /// Onboarding shows a shorter version; Settings shows everything.
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !model.foundAnyClient {
                Text("No agent clients found on this Mac yet. Install Claude Desktop, Claude Code, Cursor, Windsurf or Zed and come back. This pane will find them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.findings) { finding in
                    if !compact || finding.status != .clientNotFound {
                        row(finding)
                    }
                }
            }

            if model.outstanding > 1 {
                Button("Connect all \(model.outstanding)") { model.connectEverything() }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }

            if !model.awaitingRestart.isEmpty {
                Label(
                    "Quit and reopen the apps you just connected. Fully quit, not just close the window. They read this file once, at launch.",
                    systemImage: "arrow.clockwise"
                )
                .font(.caption)
                .foregroundStyle(Theme.warn)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let status = model.status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(model.statusIsProblem ? Theme.accent : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func row(_ finding: MCPInstaller.Finding) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol(finding.status))
                .foregroundStyle(tint(finding.status))
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.surface.name).font(.system(size: 12, weight: .medium))
                Text(caption(finding))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !compact {
                    // Name the file. A pane that writes into other applications' configuration
                    // without saying which file is asking for trust it has not earned.
                    Text("~/" + finding.surface.path)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)
            action(finding)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func action(_ finding: MCPInstaller.Finding) -> some View {
        switch finding.status {
        case .notConnected:
            Button("Connect") { model.connect(finding.surface) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .stale:
            Button("Repair") { model.connect(finding.surface) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .connected:
            if !compact {
                Button("Remove") { model.disconnect(finding.surface) }
                    .controlSize(.small)
            }
        case .unreadable:
            Button("Copy snippet") { model.copySnippet(for: finding.surface) }
                .controlSize(.small)
        case .clientNotFound:
            EmptyView()
        }
    }

    private func caption(_ finding: MCPInstaller.Finding) -> String {
        switch finding.status {
        case .clientNotFound: return "Not installed."
        case .notConnected: return finding.surface.detail
        case .connected: return "Connected."
        case .stale(let recorded):
            return "Points at \(recorded), which is not where Memoir is now."
        case .unreadable(let reason):
            return "Memoir will not edit this file: it \(reason). Copy the snippet and paste it in yourself."
        }
    }

    private func symbol(_ status: MCPInstaller.Status) -> String {
        switch status {
        case .connected: return "checkmark.circle.fill"
        case .stale: return "exclamationmark.triangle.fill"
        case .unreadable: return "hand.raised.fill"
        case .notConnected: return "circle.dashed"
        case .clientNotFound: return "circle.dotted"
        }
    }

    private func tint(_ status: MCPInstaller.Status) -> Color {
        switch status {
        case .connected: return Theme.good
        case .stale: return Theme.warn
        case .unreadable: return Theme.accent
        case .notConnected: return Theme.dim
        case .clientNotFound: return Theme.ghost
        }
    }
}

// MARK: - The Settings tab

struct ConnectionsTab: View {
    @StateObject private var model = ConnectionsModel()

    var body: some View {
        Form {
            Section {
                ConnectionsPanel(model: model)
            } header: {
                Text("Let your agent read your memory")
            } footer: {
                Text("Each of these reads its own configuration file, which is why connecting one says nothing about the others: Claude's chat app and Claude Code keep separate files and neither can see the other's. Memoir adds one entry, leaves everything else in the file alone, and keeps a copy of the file as it was before the first change.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Install the skill") { model.installSkill() }
                        .controlSize(.small)
                    Spacer()
                }
                if let skillStatus = model.skillStatus {
                    Text(skillStatus).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("The half that tells it when to look")
            } footer: {
                Text("The server gives an agent the tools. The skill is the page that says to consult them before asserting anything about your work, and to cite what it finds rather than claim it. Without it a model has twelve tools and no reason to prefer them to guessing. Installs into ~/.claude/skills/memoir. Claude Code reads that directory; the chat app does not.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let binary = model.binary {
                Section {
                    Text(binary.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary).textSelection(.enabled)
                } header: {
                    Text("The server being registered")
                } footer: {
                    Text("Read-only. It opens Memoir's database without write access and can only answer questions. Move or rename Memoir.app and every entry above points at nothing. This pane will say so, and Repair puts it right.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // A client can be installed, or quit, while this pane is open.
        .task { model.refresh() }
    }
}
