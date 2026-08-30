import Testing
import Foundation
@testable import MemoirKit

// MARK: - Helpers

/// A throwaway keychain item, so no test can touch the key that unlocks the real memory.
private func withScratchItem<T>(_ body: () throws -> T) throws -> T {
    try VaultKey.$itemOverride.withValue(
        .init(service: "sh.memoir.tests.vault.\(UUID().uuidString)", account: "database")
    ) {
        defer { try? VaultKey.delete() }
        return try body()
    }
}

// MARK: - The recovery key round-trips

@Test("A recovery key survives a round trip through paper")
func recoveryKeyRoundTrips() throws {
    let key = try VaultKey.randomKey()
    let recovery = try VaultKey.recoveryKey(for: key)
    #expect(try VaultKey.key(fromRecoveryKey: recovery) == key)
}

@Test("A recovery key reads like something a person can copy down")
func recoveryKeyIsLegible() throws {
    let recovery = try VaultKey.recoveryKey(for: VaultKey.randomKey())

    // Fourteen groups of four: 52 characters of key, 4 of checksum.
    let groups = recovery.split(separator: "-")
    #expect(groups.count == 14)
    #expect(groups.allSatisfy { $0.count == 4 })

    // Nothing in it can be misread as something else.
    #expect(!recovery.contains("I"))
    #expect(!recovery.contains("L"))
    #expect(!recovery.contains("O"))
    #expect(!recovery.contains("U"))
}

@Test("Presentation is forgiven: case, spacing and hyphens carry no meaning")
func recoveryKeyIgnoresPresentation() throws {
    let key = try VaultKey.randomKey()
    let recovery = try VaultKey.recoveryKey(for: key)

    let lowercased = recovery.lowercased()
    let unhyphenated = recovery.replacingOccurrences(of: "-", with: "")
    let spaced = recovery.replacingOccurrences(of: "-", with: " ")
    let ragged = "  \(lowercased)\n"

    for variant in [lowercased, unhyphenated, spaced, ragged] {
        #expect(try VaultKey.key(fromRecoveryKey: variant) == key)
    }
}

@Test("The three characters people mistype from paper are absorbed")
func recoveryKeyForgivesTranscriptionSlips() throws {
    // The alphabet never emits I, L or O, so anyone typing one meant 1, 1 and 0.
    #expect(VaultKey.normalise("IL0-oO1") == "1100" + "01")
    #expect(VaultKey.normalise("i l o") == "110")
}

// MARK: - A wrong key is refused, not half-accepted

@Test("A single mistyped character is caught by the checksum")
func typoIsRejected() throws {
    let recovery = try VaultKey.recoveryKey(for: VaultKey.randomKey())

    // Change one character in the body to a different valid one.
    var characters = Array(recovery)
    let index = characters.firstIndex { $0 != "-" }!
    characters[index] = characters[index] == "7" ? "9" : "7"
    let typo = String(characters)

    #expect(throws: MemoirError.self) {
        _ = try VaultKey.key(fromRecoveryKey: typo)
    }
}

@Test("A truncated recovery key is refused before it can be stored")
func truncatedKeyIsRejected() throws {
    let recovery = try VaultKey.recoveryKey(for: VaultKey.randomKey())
    #expect(throws: MemoirError.self) {
        _ = try VaultKey.key(fromRecoveryKey: String(recovery.dropLast(6)))
    }
    #expect(throws: MemoirError.self) {
        _ = try VaultKey.key(fromRecoveryKey: "")
    }
}

@Test("A character outside the alphabet is refused")
func foreignCharacterIsRejected() throws {
    let recovery = try VaultKey.recoveryKey(for: VaultKey.randomKey())
    let corrupted = "£" + recovery.dropFirst()
    #expect(throws: MemoirError.self) {
        _ = try VaultKey.key(fromRecoveryKey: corrupted)
    }
}

// MARK: - The keychain, through the real Security framework

@Test("First run creates a key; the second launch finds the same one")
func loadOrCreateIsStable() throws {
    try withScratchItem {
        let first = try VaultKey.loadOrCreate(containerExists: { false })
        #expect(first.created)
        #expect(first.key.count == VaultKey.keyLength)

        let second = try VaultKey.loadOrCreate(containerExists: { false })
        #expect(!second.created)
        #expect(second.key == first.key)
    }
}

@Test("A key is never minted while an encrypted memory exists")
func neverMintsAKeyOverAnExistingVault() throws {
    try withScratchItem {
        // The state that cost a real user 480 MB: a container on disk and no key for it.
        // Minting one here is not a recovery, it is the last step of the loss: the new key
        // cannot open the old vault, and storing it overwrites the slot the real key would
        // have been restored into.
        #expect(throws: MemoirError.self) {
            _ = try VaultKey.loadOrCreate(containerExists: { true })
        }
        #expect(
            !VaultKey.exists(),
            "refusing to create a key must also mean not having created one"
        )
    }
}

@Test("A keychain that refuses is not a keychain that is empty")
func aRefusalNeverLooksLikeFirstRun() throws {
    try withScratchItem {
        // `lookup` is the whole distinction: absent may create, refused may not. This is the
        // line that was `try? load()` on 12 August 2026, when a keychain that was merely
        // unavailable was read as "first run" and answered with a brand new key.
        #expect(try VaultKey.lookup() == .absent)

        let created = try VaultKey.loadOrCreate(containerExists: { false })
        #expect(created.created)

        guard case .found(let stored) = try VaultKey.lookup() else {
            Issue.record("a stored key must look up as found")
            return
        }
        #expect(stored == created.key)
    }
}

@Test("With no key stored, loading says so rather than inventing one")
func loadWithoutKeyThrows() throws {
    try withScratchItem {
        #expect(throws: MemoirError.self) { _ = try VaultKey.load() }
        #expect(!VaultKey.exists())
    }
}

@Test("A restored recovery key produces the identical secret")
func restoreRebuildsTheSameKey() throws {
    try withScratchItem {
        let original = try VaultKey.loadOrCreate(containerExists: { false }).key
        let recovery = try VaultKey.recoveryKey()

        // The machine is gone: the keychain item with it.
        try VaultKey.delete()
        #expect(!VaultKey.exists())

        try VaultKey.restore(fromRecoveryKey: recovery)
        #expect(try VaultKey.load() == original)
    }
}

@Test("Deleting the key leaves nothing behind that could be mistaken for one")
func deleteIsIdempotent() throws {
    try withScratchItem {
        _ = try VaultKey.loadOrCreate(containerExists: { false })
        try VaultKey.delete()
        try VaultKey.delete()          // deleting nothing is not an error
        #expect(!VaultKey.exists())
    }
}

@Test("Keys are random, not derived from anything guessable")
func keysAreDistinct() throws {
    var seen = Set<Data>()
    for _ in 0..<32 { seen.insert(try VaultKey.randomKey()) }
    #expect(seen.count == 32)
}
