import Foundation

/// Writes accepted drafts into the vault, under exactly one rule: **a proposal,
/// reviewed and accepted, into Memoir's own subfolder. Never a sync.**
///
/// An Obsidian note is valuable because a human decided to write it. Auto-appending
/// observations turns a curated corpus into a clippings graveyard, so Memoir's write path
/// is deliberately narrow: the user asks for a draft, reads it, and only an explicit
/// accept writes a file, always inside `<vault>/Memoir/`, never anywhere else. The
/// importer skips that folder, so nothing Memoir writes is ever read back as memory.
public enum VaultWriteBack {

    /// The only folder Memoir may ever create files in. Also excluded from import.
    public static let folderName = "Memoir"

    /// Where an accepted daily note lands: `<vault>/Memoir/2026-03-16.md`.
    public static func dailyNoteURL(vaultRoot: URL, day: Date, calendar: Calendar = .current) -> URL {
        let comps = calendar.dateComponents([.year, .month, .day], from: day)
        let name = String(format: "%04d-%02d-%02d.md", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        return vaultRoot.appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent(name)
    }

    /// Writes an accepted draft. Creates `Memoir/` if needed; overwrites only its own
    /// previous file for the same day (re-accepting an updated draft is the one
    /// legitimate overwrite). Throws when the vault itself does not exist: a missing
    /// vault must never be silently created.
    @discardableResult
    public static func write(
        draft: String,
        vaultRoot: URL,
        day: Date,
        calendar: Calendar = .current
    ) throws -> URL {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: vaultRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MemoirError.storage("vault folder does not exist: \(vaultRoot.path)")
        }
        let target = dailyNoteURL(vaultRoot: vaultRoot, day: day, calendar: calendar)
        let pipFolder = target.deletingLastPathComponent()

        // "Only inside Memoir/" must hold on the real filesystem, not just on the path
        // string: a symlinked Memoir/ folder would carry an accepted draft anywhere it
        // points outside the vault, over an arbitrary file. Refuse the symlink and
        // verify the resolved destination still sits under the resolved vault root.
        if let attrs = try? fm.attributesOfItem(atPath: pipFolder.path),
           attrs[.type] as? FileAttributeType == .typeSymbolicLink {
            throw MemoirError.storage("\(folderName)/ in the vault is a symlink; refusing to write through it")
        }
        try fm.createDirectory(at: pipFolder, withIntermediateDirectories: true)
        let resolvedRoot = vaultRoot.resolvingSymlinksInPath().path
        let resolvedFolder = pipFolder.resolvingSymlinksInPath().path
        guard resolvedFolder == resolvedRoot + "/" + folderName else {
            throw MemoirError.storage("refusing to write outside the vault (resolved: \(resolvedFolder))")
        }

        try draft.write(to: target, atomically: true, encoding: .utf8)
        return target
    }
}

extension MemoryService {

    /// A daily-note draft for one day: where the time went, what came up, what is due.
    ///
    /// Pure read: generating a draft writes nothing anywhere. The draft is handed to
    /// the user for review; `VaultWriteBack.write` runs only on their explicit accept.
    public func dailyNoteDraft(for day: Date, now: Date = Date()) async throws -> String {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? now
        let end = min(dayEnd, now)
        let sheet = try await timesheet(from: start, to: end)

        var out: [String] = []
        out.append("# \(start.formatted(Date.FormatStyle().year().month(.wide).day().weekday(.wide)))")
        out.append("")

        if sheet.lines.isEmpty {
            out.append("Nothing tracked this day.")
        } else {
            out.append("## Where the time went: \(TimesheetBuilder.duration(sheet.totalSeconds))")
            for line in sheet.lines.prefix(10) {
                let name = line.entityID != nil ? "[[\(line.label)]]" : line.label
                out.append("- \(name): \(TimesheetBuilder.duration(line.seconds)) (\(line.apps.joined(separator: ", ")))")
            }
            out.append("")
        }

        let all = try await entitiesSnapshot()
        let touched = all.filter { $0.updatedAt >= start && $0.updatedAt <= end && !$0.deleted }
        if !touched.isEmpty {
            out.append("## Came up")
            for entity in touched.prefix(8) {
                out.append("- \(entity.kind.displayName): \(entity.title)")
            }
            out.append("")
        }

        let due = all.filter { $0.kind == .commitment && !$0.deleted && $0.dueAt != nil }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
        if !due.isEmpty {
            out.append("## On the hook")
            for entity in due.prefix(5) {
                let when = entity.dueAt.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                out.append("- \(entity.title), \(when)")
            }
            out.append("")
        }

        out.append("---")
        out.append("*Drafted by Memoir from this Mac's records, written only because you accepted it. Edit freely. Memoir only rewrites this file if you accept a new draft for the same day.*")
        return out.joined(separator: "\n")
    }

}
