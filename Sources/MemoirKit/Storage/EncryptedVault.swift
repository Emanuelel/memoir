import Foundation
import SQLite3

/// The encrypted container the database lives inside.
///
/// ## Why a container and not an encrypted SQLite
///
/// The usual answer is SQLCipher, and it is a good library. It is also a third-party C
/// dependency, and `Packaging/Memoir.entitlements` states as a fact that Memoir has none,
/// which is why it can refuse `disable-library-validation`, and part of why the security
/// story is auditable at all. Hand-rolling page encryption instead means writing a custom VFS
/// with reserved bytes and hot-journal handling, and getting that subtly wrong corrupts a
/// decade of somebody's life rather than throwing an error.
///
/// So the file is put inside an AES-256 sparse bundle that macOS itself encrypts. Apple's
/// crypto, no dependency, and SQLite is untouched: WAL, FTS5 and the embeddings all behave
/// exactly as before, because as far as SQLite is concerned nothing has changed.
///
/// ## Everything, not just the journal
///
/// Encrypting only the private entries and leaving the rest is the tempting cheap version and
/// it breaks search: a full-text index cannot be built over ciphertext, so the most personal
/// thing in the memory would become the one thing that could not be found. Whole-container is
/// the only coherent choice.
///
/// ## What this defends
///
/// A stolen laptop, a copied database, a leaked backup, a disk pulled out of a dead Mac.
/// **Not** something running as the user while they are logged in: at that moment the volume
/// is mounted because they are using it. Recall's mistake was letting people assume more, so
/// this is stated in `PRIVACY.md` in the same words.
public enum EncryptedVault {

    /// The container itself, beside the plaintext database it replaces.
    public static func bundleURL() -> URL {
        Paths.supportDirectory().appendingPathComponent("memoir.sparsebundle")
    }

    /// Where it mounts. Inside Application Support rather than `/Volumes`, and `-nobrowse`, so
    /// it never appears in Finder's sidebar as a disk the user might eject mid-write.
    public static func mountPoint() -> URL {
        Paths.supportDirectory().appendingPathComponent("vault", isDirectory: true)
    }

    /// The database, once the container is mounted.
    public static func databaseURL() -> URL {
        mountPoint().appendingPathComponent("memoir.sqlite")
    }

    /// Sparse: it occupies what it uses, not what it may one day use. A decade of captures
    /// projects to about 15 GB, so the ceiling is set far above any real memory and costs nothing.
    static let maximumSize = "200g"

    // MARK: - State

    /// True when the container exists on disk, mounted or not.
    public static func exists() -> Bool {
        FileManager.default.fileExists(atPath: bundleURL().path)
    }

    /// True when the container is mounted and the database inside it is reachable.
    public static func isMounted() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: mountPoint().path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        // A mount point is a directory either way; what distinguishes a mounted one is that it
        // sits on a different volume from its own parent.
        let mounted = try? mountPoint().resourceValues(forKeys: [.volumeIdentifierKey])
        let parent = try? Paths.supportDirectory().resourceValues(forKeys: [.volumeIdentifierKey])
        guard let a = mounted?.volumeIdentifier, let b = parent?.volumeIdentifier else { return false }
        return !a.isEqual(b)
    }

    // MARK: - Lifecycle

    /// Creates the container, encrypted with the key from the login keychain.
    ///
    /// The passphrase goes in over **stdin**, never as an argument: everything in `argv` is
    /// readable by any process on the machine through `ps`, which would put the key that
    /// unlocks the memory on the system bus every time the app started.
    public static func create(key: Data, at bundle: URL? = nil) throws {
        let target = bundle ?? bundleURL()
        guard !FileManager.default.fileExists(atPath: target.path) else { return }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        try run(
            "/usr/bin/hdiutil",
            ["create",
             "-type", "SPARSEBUNDLE",
             "-fs", "APFS",
             "-size", maximumSize,
             "-volname", "Memoir",
             "-encryption", "AES-256",
             "-stdinpass",
             "-quiet",
             target.path],
            passphrase: passphrase(from: key),
            failure: "could not create the encrypted vault"
        )
        Log.shared.info("encrypted vault created at \(target.path)")
    }

    /// Mounts the container. Safe to call when it is already mounted.
    public static func attach(key: Data, bundle: URL? = nil, mountPoint mount: URL? = nil) throws {
        let target = bundle ?? bundleURL()
        let point = mount ?? mountPoint()
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw MemoirError.storage("there is no encrypted vault at \(target.path)")
        }
        if mount == nil, isMounted() { return }

        try FileManager.default.createDirectory(at: point, withIntermediateDirectories: true)
        try run(
            "/usr/bin/hdiutil",
            ["attach", target.path,
             "-stdinpass",
             "-nobrowse",
             "-mountpoint", point.path,
             "-quiet"],
            passphrase: passphrase(from: key),
            failure: "could not unlock the memory"
        )
    }

    /// Unmounts the container. Never throws on "it was not mounted".
    ///
    /// Called on quit and on sleep. A forced detach is deliberately not used: SQLite may still
    /// be checkpointing, and tearing the volume out from under it is how a WAL gets truncated.
    public static func detach(mountPoint mount: URL? = nil) {
        let point = mount ?? mountPoint()
        do {
            try run(
                "/usr/bin/hdiutil", ["detach", point.path, "-quiet"],
                passphrase: nil,
                failure: "could not close the vault"
            )
        } catch {
            // Swallowed, not ignored. The common failure is "it was not mounted", which is the
            // state the caller wanted anyway and is not worth a word. The one that matters is
            // the other one: the volume is still mounted after being asked to close, so the
            // memory stays readable until something else unmounts it. That deserves a line,
            // because otherwise the app quits looking like it locked up and did not.
            if mount == nil, isMounted() {
                Log.shared.warn("the vault is still mounted after detach: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Moving an existing memory in

    /// What a migration did, so the app can say it plainly rather than claim more than happened.
    public struct Migration: Sendable, Equatable {
        public let moved: Bool
        public let bytes: Int64
        public static let nothingToDo = Migration(moved: false, bytes: 0)
    }

    /// Moves an existing plaintext database into the container.
    ///
    /// Copy, verify, then remove the original, in that order, so a failure at any point
    /// leaves the user with a working plaintext memory rather than none at all.
    ///
    /// **The honest caveat, and it belongs in the copy too:** deleting the plaintext file does
    /// not scrub it. On an APFS SSD the old blocks persist until they are reused and no
    /// userspace overwrite changes that. Encryption is only wholly true for a memory that was
    /// encrypted from its first byte, which is why this runs at first launch rather than being
    /// offered as a setting later.
    @discardableResult
    public static func adopt(existing plaintext: URL, into destination: URL? = nil) throws -> Migration {
        let target = destination ?? databaseURL()
        let fm = FileManager.default

        guard fm.fileExists(atPath: plaintext.path) else { return .nothingToDo }
        guard !fm.fileExists(atPath: target.path) else {
            throw MemoirError.storage("there is already a memory inside the vault; refusing to overwrite it")
        }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: plaintext, to: target)

        // The WAL and shared-memory files travel with it, or recent writes are lost.
        for suffix in ["-wal", "-shm"] {
            let from = URL(fileURLWithPath: plaintext.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            try? fm.copyItem(at: from, to: URL(fileURLWithPath: target.path + suffix))
        }

        // Verify by opening it as a Memoir database. A copy that produced a file but not a
        // readable memory must not be followed by deleting the original. Checked with the C
        // API rather than through `Store`, so this whole function stays synchronous and can be
        // called on the launch path before there is anything to await on.
        try verifyIsAMemoir(at: target)

        let size = (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(at: URL(fileURLWithPath: plaintext.path + suffix))
        }
        Log.shared.info("memory moved into the encrypted vault (\(size) bytes)")
        return Migration(moved: true, bytes: size)
    }

    /// Moves any plaintext copy of the memory sitting beside the vault into it.
    ///
    /// Separate from ``adopt(existing:into:)`` on purpose, and this is the whole lesson: adopt
    /// returns early once the database is already inside, which is correct, and meant this
    /// sweep was unreachable on exactly the machines that most needed it: the ones that had
    /// already migrated and still had 177 MB of pre-migration snapshots lying in the clear
    /// next to a product telling them their memory was encrypted.
    ///
    /// So it runs on every launch instead. It is a directory listing.
    ///
    /// Matched by prefix rather than by the `.v{N}.backup` pattern, because anything at all
    /// sitting next to the database wearing its name is a complete copy of somebody's life.
    @discardableResult
    public static func sweepPlaintextCopies(beside plaintext: URL? = nil, into destination: URL? = nil) -> Int {
        let source = plaintext ?? Paths.supportDirectory().appendingPathComponent("memoir.sqlite")
        let target = destination ?? databaseURL()
        let fm = FileManager.default
        let folder = source.deletingLastPathComponent()
        let name = source.lastPathComponent
        var moved = 0

        let siblings = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in siblings
            where file.hasPrefix(name + ".") && !file.hasSuffix("-wal") && !file.hasSuffix("-shm") {
            let from = folder.appendingPathComponent(file)
            let to = target.deletingLastPathComponent().appendingPathComponent(file)
            guard !fm.fileExists(atPath: to.path) else { continue }
            do {
                try fm.copyItem(at: from, to: to)
                try fm.removeItem(at: from)
                moved += 1
                Log.shared.info("moved plaintext copy \(file) inside the vault")
            } catch {
                Log.shared.warn("could not move \(file): \(error.localizedDescription)")
            }
        }
        return moved
    }

    // MARK: - The one call the app makes

    /// What unlocking did, so first run can show the recovery key exactly once.
    public struct Opening: Sendable {
        /// Where the database is. Inside the vault when it opened, the old plaintext path
        /// when it could not.
        public let databaseURL: URL
        /// True when this launch created the vault. The only moment a recovery key may be
        /// shown for the first time.
        public let created: Bool
        /// The recovery key, present only on the launch that created the vault.
        public let recoveryKey: String?
        /// An existing plaintext memory that was moved in.
        public let migration: Migration
        /// Set when the vault could not be opened and the app is running unencrypted. Never
        /// silent: the user has to be told the memory is not protected.
        public let failure: String?
        /// Set when a container exists on disk and could not be unlocked.
        ///
        /// Different from ``failure`` in the only way that matters: there is a memory here,
        /// it is just shut. Falling back to the plaintext path in that state does not degrade
        /// gracefully, it forks: a second, empty memory starts filling up beside the real one
        /// while the user is told, for ten seconds, that encryption is off. Observed: 50
        /// captures written into a fresh database while 5,363 sat locked next to it.
        ///
        /// The caller must not open a database when this is set. It must say what happened and
        /// offer the recovery key.
        public let locked: Bool
    }

    /// Unlocks the memory, creating and migrating on first run.
    ///
    /// Falls back to the plaintext path rather than refusing to start **when there is nothing
    /// to fall back from**. A memory tool that will not open is worse than one that opens and
    /// says plainly that it is not encrypted, and `failure` is not optional for the caller to
    /// ignore quietly.
    ///
    /// That reasoning does not extend to a container that exists and is merely shut, which is
    /// what ``Opening/locked`` marks. There the fallback is not a degraded mode, it is a
    /// second memory: the app starts a fresh database beside the real one and captures into
    /// it, and the user's evidence that anything is wrong is a ten-second speech bubble.
    public static func open() -> Opening {
        let plaintext = Paths.supportDirectory().appendingPathComponent("memoir.sqlite")

        do {
            let (key, createdKey) = try VaultKey.loadOrCreate()
            let creating = createdKey || !exists()

            if !exists() { try create(key: key) }
            try attach(key: key)

            let migration = (try? adopt(existing: plaintext)) ?? .nothingToDo
            // Every launch, not just the migrating one. See the note on the sweep.
            sweepPlaintextCopies(beside: plaintext)

            return Opening(
                databaseURL: databaseURL(),
                created: creating,
                recoveryKey: creating ? try? VaultKey.recoveryKey(for: key) : nil,
                migration: migration,
                failure: nil,
                locked: false
            )
        } catch {
            let reason = (error as? MemoirError)?.localizedDescription ?? error.localizedDescription
            Log.shared.error("could not open the encrypted vault: \(reason)")
            // A container on disk that will not open is not the same as no container. The
            // plaintext fallback is right for the second and actively harmful for the first.
            let locked = exists()
            if locked {
                Log.shared.error("an encrypted memory exists and is locked; refusing to start a second one")
            }
            return Opening(
                databaseURL: plaintext,
                created: false,
                recoveryKey: nil,
                migration: .nothingToDo,
                failure: reason,
                locked: locked
            )
        }
    }

    /// The same opening, with the lock deliberately stood down.
    ///
    /// For the one case that justifies a second memory: the user has been shown the locked
    /// container, has been asked for the recovery key, and has said they do not have it. That
    /// is a decision somebody made, which is the entire difference between this and the
    /// fallback it replaced.
    ///
    /// Nothing is deleted, moved or re-keyed. The container stays sealed and on disk, because
    /// a recovery key found next month has to still be worth something.
    public static func startingFresh(besides locked: Opening) -> Opening {
        Opening(
            databaseURL: locked.databaseURL,
            created: false,
            recoveryKey: nil,
            migration: .nothingToDo,
            failure: locked.failure,
            locked: false
        )
    }

    /// Closes the memory. Called on quit.
    ///
    /// Only when nobody else is still using it. A quitting instance used to detach the volume
    /// unconditionally, which is fine exactly once and wrong the moment two instances overlap:
    /// relaunching the app starts the new one, the new one mounts and opens the database, and
    /// then the old one finishes terminating and pulls the volume out from under it. Observed
    /// on a real machine: the replacement launched cleanly at :53 and was left with no
    /// database at :01, with nothing in the log to say why.
    ///
    /// Counting processes rather than holding a lock file, because a lock file survives a
    /// crash and a process does not, and a stale lock that refuses to unmount somebody's
    /// memory is a worse failure than the one being fixed.
    /// - Parameter others: how many other copies are up. Injectable so the decision can be
    ///   tested without a test asserting facts about whatever else happens to be running on
    ///   the machine, which is a test that fails for reasons that are nobody's fault.
    public static func close(others: Int? = nil) {
        guard (others ?? otherInstancesRunning()) == 0 else {
            Log.shared.info("leaving the vault mounted: another Memoir is still running")
            return
        }
        detach()
    }

    /// How many *other* copies of this executable are running.
    static func otherInstancesRunning() -> Int {
        let me = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.executablePath ?? ""
        guard !path.isEmpty else { return 0 }

        let out = (try? run("/bin/ps", ["-Ao", "pid=,comm="], passphrase: nil,
                            failure: "could not list processes")) ?? ""
        var count = 0
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let pid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) ?? -1
            let comm = parts[1].trimmingCharacters(in: .whitespaces)
            if pid != me, comm == path { count += 1 }
        }
        return count
    }

    /// Opens a file as a Memoir database and throws unless it really is one.
    ///
    /// `user_version` is the schema marker `Store` itself checks. A truncated copy usually
    /// still opens, and reports zero, which is the failure this catches before the original
    /// gets deleted.
    static func verifyIsAMemoir(at url: URL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw MemoirError.storage("the copy at \(url.path) is not a readable database")
        }
        defer { sqlite3_close_v2(handle) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw MemoirError.storage("the copy at \(url.path) could not be read")
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw MemoirError.storage("the copy at \(url.path) could not be read")
        }
        let version = sqlite3_column_int(statement, 0)
        guard version > 0 else {
            throw MemoirError.storage("the copy at \(url.path) has no Memoir schema in it")
        }
    }

    // MARK: - Helpers

    /// The key as text `hdiutil` will accept. Base64 of the raw 32 bytes: the whole 256 bits,
    /// no encoding surprises, and nothing derived that could weaken it.
    static func passphrase(from key: Data) -> String { key.base64EncodedString() }

    /// Runs a tool, feeding the passphrase over stdin and never over the argument list.
    @discardableResult
    static func run(
        _ tool: String,
        _ arguments: [String],
        passphrase: String?,
        failure: String
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        if let passphrase {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            input.fileHandleForWriting.write(Data(passphrase.utf8))
            try? input.fileHandleForWriting.close()
        } else {
            try process.run()
        }

        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let detail = String(data: err, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw MemoirError.storage(detail.isEmpty ? failure : "\(failure): \(detail)")
        }
        return String(data: out, encoding: .utf8) ?? ""
    }
}
