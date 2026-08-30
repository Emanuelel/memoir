import CryptoKit
import Foundation
import Security

/// The key that unlocks the memory, and the one piece of paper that can rescue it.
///
/// A 256-bit random secret lives in the login keychain under service `sh.memoir.vault`,
/// account `database`. macOS unlocks it when the user logs in, so the memory opens without
/// anyone being asked for a password. That is the whole point of the auto-unlock decision.
/// The cost of auto-unlock is that a forgotten Mac password, a wiped machine or a restored
/// backup would otherwise take a decade of someone's life with it, which is why every key
/// this type creates can be written down.
///
/// ## What this defends against, and what it does not
///
/// Encryption protects the **file**, not the **session**. A stolen laptop, a copied database,
/// a leaked backup: defended. Something running as the user while they are logged in: not
/// defended, because at that moment the memory is unlocked by design. Say this plainly
/// wherever the product describes it: Recall's mistake was letting people assume more.
///
/// ## The item is deliberately device-local
///
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` keeps the key out of iCloud Keychain. A key
/// that syncs is a key that leaves the machine, which would quietly contradict the promise the
/// rest of this product is built on.
public enum VaultKey {
    /// Keychain service identifier for the database key.
    public static let service = "sh.memoir.vault"
    /// Keychain account identifier for the database key.
    public static let account = "database"

    /// Length of the secret, in bytes. 256 bits.
    public static let keyLength = 32

    /// Which generic-password item this type reads and writes.
    public struct Item: Sendable, Equatable {
        /// `kSecAttrService`.
        public let service: String
        /// `kSecAttrAccount`.
        public let account: String

        public init(service: String, account: String) {
            self.service = service
            self.account = account
        }
    }

    /// Redirects the Keychain item for the duration of a scope.
    ///
    /// Tests have to exercise the real Security framework (an in-memory stand-in would prove
    /// nothing about what lands on disk), but they must never touch the item that unlocks the
    /// user's actual memory. Binding this sends them to a throwaway item.
    ///
    /// A task local rather than a global, so parallel tests cannot see each other's binding and
    /// production, which never binds it, behaves exactly as if this did not exist.
    @TaskLocal public static var itemOverride: Item?

    /// The service identifier in force right now.
    static var currentService: String { itemOverride?.service ?? service }

    /// The account identifier in force right now.
    static var currentAccount: String { itemOverride?.account ?? account }

    // MARK: - Lifecycle

    /// True when a key already exists. Cheap enough to call on every launch.
    public static func exists() -> Bool { (try? load()) != nil }

    /// What the keychain said when asked for the key.
    ///
    /// The distinction exists because exactly one of these may lead to a new key being minted,
    /// and collapsing them cost a user their memory. See ``loadOrCreate()``.
    public enum Lookup: Sendable, Equatable {
        /// The keychain returned the key.
        case found(Data)
        /// The keychain positively reported that no such item exists.
        case absent
    }

    /// Returns the existing key, creating one **only** when the keychain positively reports
    /// that there is none.
    ///
    /// The create path is the only moment a recovery key can be shown for the first time, so
    /// callers that create must route the user to ``recoveryKey()`` before going any further.
    ///
    /// This used to read `if let existing = try? load()`, which threw away the distinction
    /// ``load()`` is careful to draw and its own documentation asks callers to respect. Every
    /// failure (a locked keychain, a denied prompt, an item this build is not trusted to read)
    /// looked identical to "first run", so the answer to a keychain that was merely
    /// unavailable was to mint a new key and overwrite the old one.
    ///
    /// That happened, on a real machine, at 10:04:51 on 12 August 2026. The vault was already
    /// mounted from the previous launch, so ``EncryptedVault/open()`` took its
    /// already-mounted early return and never tried the new key against the container. The
    /// database opened, the app ran normally, and nothing was wrong for five days, until the
    /// first unmount, when the vault turned out to be sealed with a key that no longer existed
    /// anywhere. 480 MB of memory, and the only copy of the key that opened it was gone.
    ///
    /// So: `absent` creates, everything else propagates. And a key is never minted while a
    /// container exists, because a new key cannot open an old vault and writing one is how the
    /// old vault stops being openable at all.
    /// - Parameter containerExists: whether an encrypted container is already on disk. A
    ///   parameter rather than a direct call so this stays a decision about the arguments it
    ///   is given: the real implementation reads a fixed path in the support directory, and a
    ///   test that had to pass through it would be asserting on whatever the machine running
    ///   it happens to have encrypted.
    /// - Returns: the 32-byte secret, and whether this call was the one that created it.
    @discardableResult
    public static func loadOrCreate(
        containerExists: () -> Bool = EncryptedVault.exists
    ) throws -> (key: Data, created: Bool) {
        switch try lookup() {
        case .found(let existing):
            return (existing, false)
        case .absent:
            guard !containerExists() else {
                throw MemoirError.storage(
                    """
                    there is an encrypted memory here but no key to open it. Refusing to \
                    create a new one: a new key cannot open the existing vault, and storing \
                    it would destroy the last chance of ever opening it. Restore from your \
                    recovery key instead.
                    """
                )
            }
            let fresh = try randomKey()
            try store(fresh)
            Log.shared.info("vault key created; the user has not seen a recovery key yet.")
            return (fresh, true)
        }
    }

    /// Asks the keychain for the key, separating "there is none" from "you cannot have it".
    ///
    /// - Throws: `MemoirError.storage` for every refusal that is *not* a plain absence.
    public static func lookup() throws -> Lookup {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        guard status != errSecItemNotFound else { return .absent }
        guard status == errSecSuccess, let data = item as? Data else {
            throw MemoirError.storage("keychain refused the vault key: \(message(for: status))")
        }
        guard data.count == keyLength else {
            throw MemoirError.storage("vault key is \(data.count) bytes, expected \(keyLength)")
        }
        return .found(data)
    }

    /// Reads the key from the login keychain.
    /// - Throws: `MemoirError.storage` when there is no key, or the keychain refuses to hand
    ///   it over: the two cases a caller has to tell apart before it decides to create one.
    ///   ``lookup()`` is what tells them apart; this is the form for callers that need a key
    ///   and have nothing useful to do about either failure.
    public static func load() throws -> Data {
        switch try lookup() {
        case .found(let data): return data
        case .absent: throw MemoirError.storage("no vault key in the keychain")
        }
    }

    /// Writes a key, replacing any existing one.
    ///
    /// Used by first run and by ``restore(fromRecoveryKey:)``. Kept internal on purpose:
    /// nothing outside this file should be inventing keys for the user's database.
    static func store(_ key: Data) throws {
        guard key.count == keyLength else {
            throw MemoirError.storage("refusing to store a \(key.count)-byte vault key")
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
        ]

        // Update in place first, so the item keeps its ACL and macOS does not re-prompt.
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: key] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound {
            SecItemDelete(query as CFDictionary)
        }

        var insert = query
        insert[kSecValueData as String] = key
        insert[kSecAttrLabel as String] = "Memoir: database key"
        insert[kSecAttrDescription as String] = "Unlocks your Memoir database. Losing this loses the memory."
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MemoirError.storage("keychain write failed: \(message(for: addStatus))")
        }
    }

    /// Removes the key.
    ///
    /// This is not "forget everything": it makes an encrypted database unreadable without
    /// deleting a byte of it. Only call it from a path that has already said so out loud.
    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MemoirError.storage("keychain delete failed: \(message(for: status))")
        }
    }

    /// 32 cryptographically random bytes from the system.
    static func randomKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        let status = SecRandomCopyBytes(kSecRandomDefault, keyLength, &bytes)
        guard status == errSecSuccess else {
            throw MemoirError.storage("the system refused to provide random bytes (\(status))")
        }
        return Data(bytes)
    }

    // MARK: - The recovery key

    /// The current key, rendered as something a person can write on paper.
    ///
    /// Fourteen groups of four characters. Crockford's Base32 alphabet, which leaves out
    /// `I`, `L`, `O` and `U` so that nothing in it can be misread as something else, plus a
    /// four-character checksum so a mistyped key is rejected immediately rather than failing
    /// later as an unreadable database.
    ///
    /// ```
    /// A1B2-C3D4-E5F6-G7H8-J9K0-M1N2-P3Q4-R5S6-T7V8-W9X0-Y1Z2-3456-789A-BCDE
    /// ```
    public static func recoveryKey() throws -> String {
        try recoveryKey(for: load())
    }

    /// Renders a specific key as a recovery key. Exposed for the create path, which has the
    /// bytes in hand before anything has been stored.
    public static func recoveryKey(for key: Data) throws -> String {
        guard key.count == keyLength else {
            throw MemoirError.storage("cannot render a \(key.count)-byte key")
        }
        let body = base32Encode(key)
        let full = body + checksum(for: key)
        return stride(from: 0, to: full.count, by: 4).map { offset in
            let start = full.index(full.startIndex, offsetBy: offset)
            let end = full.index(start, offsetBy: min(4, full.count - offset))
            return String(full[start..<end])
        }.joined(separator: "-")
    }

    /// Restores a key from something the user typed or pasted.
    ///
    /// Forgiving about presentation and strict about content: case, spaces, hyphens and the
    /// classic transcription slips (`I` and `L` for one, `O` for zero) are all absorbed, and
    /// anything that fails the checksum is refused before it can be stored.
    ///
    /// - Throws: `MemoirError.storage` with a message written for a person who is having a
    ///   bad day: they are doing this because something already went wrong.
    public static func restore(fromRecoveryKey text: String) throws {
        let key = try key(fromRecoveryKey: text)
        try store(key)
        Log.shared.info("vault key restored from a recovery key.")
    }

    /// Decodes a recovery key without storing it. The half of ``restore(fromRecoveryKey:)``
    /// worth testing on its own, and what a "check this before I write it down" button calls.
    public static func key(fromRecoveryKey text: String) throws -> Data {
        let cleaned = normalise(text)
        guard !cleaned.isEmpty else {
            throw MemoirError.storage("That recovery key is empty.")
        }
        let expected = base32Length(forBytes: keyLength) + checksumLength
        guard cleaned.count == expected else {
            throw MemoirError.storage(
                "A recovery key has \(expected) characters; that one has \(cleaned.count)."
            )
        }

        let bodyEnd = cleaned.index(cleaned.endIndex, offsetBy: -checksumLength)
        let body = String(cleaned[cleaned.startIndex..<bodyEnd])
        let given = String(cleaned[bodyEnd...])

        let key = try base32Decode(body, byteCount: keyLength)
        guard checksum(for: key) == given else {
            throw MemoirError.storage(
                "That recovery key has a typo in it: the check characters at the end do not match."
            )
        }
        return key
    }

    // MARK: - Crockford Base32

    /// No `I`, `L`, `O` or `U`. The first three because they are read as `1` and `0`; the
    /// fourth so that no combination of characters can spell something unfortunate.
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// How many characters of Base32 a given number of bytes needs.
    static func base32Length(forBytes count: Int) -> Int { (count * 8 + 4) / 5 }

    /// Characters of checksum on the end. Four gives roughly one in a million odds that a
    /// mistyped key is wrongly accepted.
    static let checksumLength = 4

    static func base32Encode(_ data: Data) -> String {
        var out = ""
        out.reserveCapacity(base32Length(forBytes: data.count))
        var accumulator = 0
        var bits = 0
        for byte in data {
            accumulator = (accumulator << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                out.append(alphabet[(accumulator >> bits) & 31])
            }
        }
        if bits > 0 {
            out.append(alphabet[(accumulator << (5 - bits)) & 31])
        }
        return out
    }

    static func base32Decode(_ text: String, byteCount: Int) throws -> Data {
        var out = Data()
        out.reserveCapacity(byteCount)
        var accumulator = 0
        var bits = 0
        for character in text {
            guard let value = alphabet.firstIndex(of: character) else {
                throw MemoirError.storage("“\(character)” is not part of a recovery key.")
            }
            accumulator = (accumulator << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((accumulator >> bits) & 255))
                if out.count == byteCount { break }
            }
        }
        guard out.count == byteCount else {
            throw MemoirError.storage("That recovery key is too short to be complete.")
        }
        return out
    }

    /// Uppercases, drops anything decorative, and forgives the three characters people
    /// reliably mistype when copying from paper.
    static func normalise(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text.uppercased() {
            switch character {
            case "-", " ", "\n", "\t", "\r": continue
            case "I", "L": out.append("1")
            case "O": out.append("0")
            case "U": continue          // never emitted; only ever a slip for V
            default: out.append(character)
            }
        }
        return out
    }

    /// Four characters derived from the key itself, so a transcription error is caught at the
    /// moment of typing rather than as a database that will not open.
    static func checksum(for key: Data) -> String {
        let digest = Data(SHA256.hash(data: key))
        return String(base32Encode(digest).prefix(checksumLength))
    }

    // MARK: - Helpers

    /// Human readable form of an `OSStatus` from the Security framework.
    private static func message(for status: OSStatus) -> String {
        if let s = SecCopyErrorMessageString(status, nil) as String? { return "\(s) (\(status))" }
        return "OSStatus \(status)"
    }
}
