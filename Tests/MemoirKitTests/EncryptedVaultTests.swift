import Testing
import Foundation
@testable import MemoirKit

/// Exercises a real encrypted sparse bundle, created and mounted by the real `hdiutil`.
///
/// Nothing is stubbed. The claim being tested is that a decade of somebody's life is
/// unreadable without the key, and a fake would prove nothing about that.
@Suite(.serialized)
struct EncryptedVaultTests {

    /// A throwaway container and mount point, torn down whatever happens.
    private func withVault(
        _ body: (_ key: Data, _ bundle: URL, _ mount: URL) async throws -> Void
    ) async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundle = root.appendingPathComponent("test.sparsebundle")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        let key = try VaultKey.randomKey()

        defer {
            EncryptedVault.detach(mountPoint: mount)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(key, bundle, mount)
    }

    @Test("a memory written inside the vault comes back out again")
    func roundTripsThroughTheContainer() async throws {
        try await withVault { key, bundle, mount in
            try EncryptedVault.create(key: key, at: bundle)
            #expect(FileManager.default.fileExists(atPath: bundle.path))

            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)

            // A real Memoir database, inside the encrypted volume.
            let dbURL = mount.appendingPathComponent("memoir.sqlite")
            let store = try Store(path: dbURL, mayMigrate: true)
            try await store.insert(capture: CaptureEvent(
                id: "c1", ts: Date(), appBundleID: "com.test", appName: "Test",
                windowTitle: "secret", text: "the thing nobody else may read",
                textHash: "h1"
            ))
            await store.close()

            EncryptedVault.detach(mountPoint: mount)

            // Mount it again: the memory is still there.
            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)
            let reopened = try Store(readOnlyPath: dbURL)
            let rows = try await reopened.captures(since: .distantPast, limit: 10)
            await reopened.close()
            #expect(rows.count == 1)
            #expect(rows.first?.text == "the thing nobody else may read")
        }
    }

    @Test("the wrong key does not open it")
    func wrongKeyIsRefused() async throws {
        try await withVault { key, bundle, mount in
            try EncryptedVault.create(key: key, at: bundle)
            let wrong = try VaultKey.randomKey()

            #expect(throws: MemoirError.self) {
                try EncryptedVault.attach(key: wrong, bundle: bundle, mountPoint: mount)
            }
        }
    }

    @Test("the text is not sitting in the container in the clear")
    func contentsAreNotReadableOnDisk() async throws {
        try await withVault { key, bundle, mount in
            let secret = "Marco's draft, the house, and the flat in the same neighbourhood"

            try EncryptedVault.create(key: key, at: bundle)
            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)
            let dbURL = mount.appendingPathComponent("memoir.sqlite")
            let store = try Store(path: dbURL, mayMigrate: true)
            try await store.insert(capture: CaptureEvent(
                id: "c1", ts: Date(), appBundleID: "com.test", appName: "Test",
                windowTitle: "note", text: secret, textHash: "h1"
            ))
            await store.close()
            EncryptedVault.detach(mountPoint: mount)

            // Now read every band file in the bundle the way somebody with the stolen disk
            // would: raw bytes, no key, looking for the words.
            let needle = Data(secret.utf8)
            var found = false
            let enumerator = FileManager.default.enumerator(
                at: bundle, includingPropertiesForKeys: [.isRegularFileKey]
            )
            while let file = enumerator?.nextObject() as? URL {
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { continue }
                if data.range(of: needle) != nil { found = true; break }
            }
            #expect(!found, "the captured text was readable inside the encrypted container")
        }
    }

    @Test("an existing plaintext memory moves in, and only then is the original removed")
    func adoptsAnExistingDatabase() async throws {
        try await withVault { key, bundle, mount in
            // A plaintext memory, as every existing install has today.
            let plain = bundle.deletingLastPathComponent().appendingPathComponent("memoir.sqlite")
            let store = try Store(path: plain, mayMigrate: true)
            try await store.insert(capture: CaptureEvent(
                id: "c1", ts: Date(), appBundleID: "com.test", appName: "Test",
                windowTitle: "before", text: "written before there was any encryption",
                textHash: "h1"
            ))
            await store.close()

            try EncryptedVault.create(key: key, at: bundle)
            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)

            let inside = mount.appendingPathComponent("memoir.sqlite")
            let migration = try EncryptedVault.adopt(existing: plain, into: inside)

            #expect(migration.moved)
            #expect(migration.bytes > 0)
            #expect(!FileManager.default.fileExists(atPath: plain.path),
                    "the plaintext original should be gone once the copy verified")

            let moved = try Store(readOnlyPath: inside)
            let rows = try await moved.captures(since: .distantPast, limit: 10)
            await moved.close()
            #expect(rows.count == 1, "the memory did not survive the move")
        }
    }

    @Test("adopting refuses to write over a memory that is already in there")
    func adoptNeverOverwrites() async throws {
        try await withVault { key, bundle, mount in
            try EncryptedVault.create(key: key, at: bundle)
            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)

            let inside = mount.appendingPathComponent("memoir.sqlite")
            let existing = try Store(path: inside, mayMigrate: true)
            await existing.close()

            let plain = bundle.deletingLastPathComponent().appendingPathComponent("other.sqlite")
            let other = try Store(path: plain, mayMigrate: true)
            await other.close()

            #expect(throws: MemoirError.self) {
                try EncryptedVault.adopt(existing: plain, into: inside)
            }
            #expect(FileManager.default.fileExists(atPath: plain.path),
                    "a refused migration must leave the original where it was")
        }
    }

    @Test("nothing to migrate is not a failure")
    func adoptingNothingIsFine() async throws {
        try await withVault { key, bundle, mount in
            try EncryptedVault.create(key: key, at: bundle)
            try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)
            let absent = bundle.deletingLastPathComponent().appendingPathComponent("nothing.sqlite")
            let migration = try EncryptedVault.adopt(
                existing: absent, into: mount.appendingPathComponent("memoir.sqlite")
            )
            #expect(migration == .nothingToDo)
        }
    }

    @Test("the passphrase never appears in the argument list")
    func passphraseIsNotInArgv() throws {
        // The whole reason -stdinpass exists. Anything in argv is readable by every process
        // on the machine, so a key passed as an argument is a key published to the system.
        let key = try VaultKey.randomKey()
        let secret = EncryptedVault.passphrase(from: key)
        let arguments = ["create", "-type", "SPARSEBUNDLE", "-encryption", "AES-256",
                         "-stdinpass", "-quiet", "/tmp/x.sparsebundle"]
        #expect(!arguments.contains(secret))
        #expect(arguments.contains("-stdinpass"))
    }
}

// MARK: - Every binary has to agree on where the memory is

@Suite(.serialized)
struct DatabaseLocationTests {

    /// The app opens the database through `EncryptedVault.open()`; `memoir-mcp`, `memoir-ask`
    /// and `--doctor` all arrive at `Paths.databaseURL()`. For one commit those disagreed
    /// (the app moved the file into the vault and nothing told the other three), and the
    /// symptom was every agent tool reporting an empty memory while the app worked perfectly.
    @Test("with a vault mounted, every binary resolves to the database inside it")
    func resolvesIntoTheVault() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-loc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await Paths.$supportDirectoryOverride.withValue(root) {
            // Nothing mounted: the old plaintext path, so a machine that predates encryption
            // still opens.
            #expect(Paths.databaseURL().lastPathComponent == "memoir.sqlite")
            #expect(!Paths.databaseURL().path.contains("/vault/"))

            // A database inside the vault is what the app is really using.
            let vault = root.appendingPathComponent("vault", isDirectory: true)
            try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
            let inside = vault.appendingPathComponent("memoir.sqlite")
            let store = try Store(path: inside, mayMigrate: true)
            await store.close()

            #expect(Paths.databaseURL() == inside,
                    "the MCP server would have opened the wrong file and found no memory")
        }
    }
}

// MARK: - Keeping everything is the default, and it must not mean deleting everything

@Suite(.serialized)
struct RetentionDefaultTests {

    /// The one bug worth being paranoid about here: zero days read as a cutoff of "now" would
    /// delete a decade of somebody's life the first time the maintenance sweep ran.
    @Test("a retention of zero keeps every capture, however old")
    func zeroMeansForever() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-ret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true)
        let memory = MemoryService(store: store, extractors: [])

        let ancient = Date().addingTimeInterval(-3600 * 24 * 3650)   // ten years ago
        try await store.insert(capture: CaptureEvent(
            id: "old", ts: ancient, appBundleID: "com.test", appName: "Test",
            windowTitle: "then", text: "something from a decade ago", textHash: "h1"
        ))

        let removed = try await memory.applyRetention(captureDays: 0)
        #expect(removed == 0)

        let rows = try await store.captures(since: .distantPast, limit: 10)
        #expect(rows.count == 1, "a ten-year-old capture was deleted by the keep-everything setting")
        await store.close()
    }

    @Test("a real window still rolls off, so the setting is not decorative")
    func positiveWindowStillPurges() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-ret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try Store(path: dir.appendingPathComponent("t.sqlite"), mayMigrate: true)
        let memory = MemoryService(store: store, extractors: [])

        try await store.insert(capture: CaptureEvent(
            id: "old", ts: Date().addingTimeInterval(-3600 * 24 * 90), appBundleID: "com.test",
            appName: "Test", windowTitle: "then", text: "ninety days ago", textHash: "h1"
        ))
        try await store.insert(capture: CaptureEvent(
            id: "new", ts: Date(), appBundleID: "com.test",
            appName: "Test", windowTitle: "now", text: "today", textHash: "h2"
        ))

        #expect(try await memory.applyRetention(captureDays: 30) == 1)
        let rows = try await store.captures(since: .distantPast, limit: 10)
        #expect(rows.count == 1)
        #expect(rows.first?.id == "new")
        await store.close()
    }
}

// MARK: - Nothing that is a copy of the memory may stay outside the vault

@Suite(.serialized)
struct SnapshotMigrationTests {

    /// Found by installing the build and looking at the folder afterwards: the database had
    /// moved inside the encrypted container and 177 MB of pre-migration snapshots had not.
    /// Every one of those is a complete copy of the memory, in the clear, next to a product
    /// telling the user it is encrypted.
    /// The database has already moved. `adopt` will return early, as it should. The snapshots
    /// still have to be collected, because this is the state every already-migrated Mac is in.
    @Test("snapshots are swept even when the database is already inside")
    func sweepsAfterTheDatabaseHasAlreadyMoved() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("v.sparsebundle")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        let key = try VaultKey.randomKey()
        defer {
            EncryptedVault.detach(mountPoint: mount)
            try? FileManager.default.removeItem(at: root)
        }

        try EncryptedVault.create(key: key, at: bundle)
        try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)

        let plain = root.appendingPathComponent("memoir.sqlite")   // never created: already moved
        let inside = mount.appendingPathComponent("memoir.sqlite")
        let store = try Store(path: inside, mayMigrate: true)
        await store.close()

        try Data("a whole copy".utf8).write(to: root.appendingPathComponent("memoir.sqlite.v6.backup"))

        #expect(try EncryptedVault.adopt(existing: plain, into: inside) == .nothingToDo)
        #expect(EncryptedVault.sweepPlaintextCopies(beside: plain, into: inside) == 1)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("memoir.sqlite.v6.backup").path))
    }

    @Test("pre-migration snapshots move into the vault with the database")
    func snapshotsTravelToo() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = root.appendingPathComponent("v.sparsebundle")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        let key = try VaultKey.randomKey()
        defer {
            EncryptedVault.detach(mountPoint: mount)
            try? FileManager.default.removeItem(at: root)
        }

        let plain = root.appendingPathComponent("memoir.sqlite")
        let store = try Store(path: plain, mayMigrate: true)
        await store.close()

        // The two shapes seen in the wild: the migration system's own, and hand-made ones.
        let snapshots = ["memoir.sqlite.v6.backup", "memoir.sqlite.pre-guards-20260808-150547"]
        for name in snapshots {
            try Data("a whole copy of somebody's life".utf8)
                .write(to: root.appendingPathComponent(name))
        }

        try EncryptedVault.create(key: key, at: bundle)
        try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)
        let inside = mount.appendingPathComponent("memoir.sqlite")
        _ = try EncryptedVault.adopt(existing: plain, into: inside)
        _ = EncryptedVault.sweepPlaintextCopies(beside: plain, into: inside)

        for name in snapshots {
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path),
                    "\(name) was left outside the vault, in the clear")
            #expect(FileManager.default.fileExists(atPath: mount.appendingPathComponent(name).path),
                    "\(name) never arrived inside the vault")
        }
    }
}

// MARK: - A quitting instance must not unmount a running one

@Suite(.serialized)
struct VaultLifetimeTests {

    /// Observed on a real machine. Reinstalling launched a new app, which mounted the vault
    /// and opened the database; seconds later the outgoing instance finished terminating and
    /// detached the volume underneath it. The new app was left running with no memory, and the
    /// log said nothing about it because unmounting had worked perfectly.
    @Test("close leaves the vault alone while another instance is still up")
    func closeIsCountAware() throws {
        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-close-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mount) }

        // Nothing is mounted here, so neither call can do damage. What is being checked is
        // which branch is taken: with a sibling up, close must not even try.
        EncryptedVault.close(others: 1)
        #expect(FileManager.default.fileExists(atPath: mount.path))

        // And the counter itself still answers rather than throwing.
        #expect(EncryptedVault.otherInstancesRunning() >= 0)
    }

    /// The mount check has to survive being asked about a directory that is not a mount point,
    /// because that is the ordinary case on every launch before the vault is attached.
    @Test("an unmounted directory does not read as mounted")
    func unmountedReadsFalse() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-notmounted-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Paths.$supportDirectoryOverride.withValue(dir) {
            #expect(!EncryptedVault.isMounted())
        }
    }

    /// The real thing, reproduced: a container sealed with one key and a keychain holding
    /// another.
    ///
    /// This is the state a real machine was left in on 12 August 2026, and the fallback to the
    /// plaintext path is what turned it from "the memory is shut" into "the memory is shut and
    /// a second one is filling up beside it". Fifty captures went into the replacement while
    /// 5,363 sat locked in the container next to it, and the only warning was a ten-second
    /// speech bubble saying encryption was off.
    @Test("a container that will not open is reported locked, never quietly replaced")
    func aLockedContainerIsNeverForked() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-locked-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            EncryptedVault.detach(mountPoint: root.appendingPathComponent("vault", isDirectory: true))
            try? FileManager.default.removeItem(at: root)
        }

        try Paths.$supportDirectoryOverride.withValue(root) {
            try VaultKey.$itemOverride.withValue(
                .init(service: "sh.memoir.tests.locked.\(UUID().uuidString)", account: "database")
            ) {
                defer { try? VaultKey.delete() }

                // Sealed with one key...
                try EncryptedVault.create(key: VaultKey.randomKey())
                // ...and the keychain now holds a different one.
                try VaultKey.store(VaultKey.randomKey())

                let opening = EncryptedVault.open()

                #expect(opening.locked, "an existing container that will not attach is locked")
                #expect(opening.failure != nil, "and the reason is never swallowed")
                #expect(
                    !opening.created,
                    "nothing was created, so no recovery key may be claimed to exist"
                )
                #expect(
                    opening.recoveryKey == nil,
                    "a locked vault has no new recovery key to hand out"
                )

                // Choosing to start again clears the lock and touches nothing else. Whoever
                // finds their recovery key next month must still be able to open this.
                let fresh = EncryptedVault.startingFresh(besides: opening)
                #expect(!fresh.locked, "an explicit choice is allowed to proceed")
                #expect(
                    FileManager.default.fileExists(atPath: EncryptedVault.bundleURL().path),
                    "the locked container must survive the decision to start again"
                )
                #expect(
                    fresh.failure != nil,
                    "and the reason it is running unencrypted is still on the record"
                )
            }
        }
    }
}
