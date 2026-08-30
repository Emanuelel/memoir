import Foundation
import Security

/// The one and only home for the Anthropic API key.
///
/// The key is stored as a generic password in the user's login keychain under
/// service `sh.memoir.brain`, account `anthropic`.
///
/// It is **never** written to SQLite, **never** to `UserDefaults`, **never** to `config.json`
/// and **never** to the log file. `BrainConfig` deliberately drops it when encoding, and every
/// log statement in this module goes through ``BrainKeychain/redact(_:)``.
public enum BrainKeychain {
    /// Keychain service identifier, per the architecture contract.
    public static let service = "sh.memoir.brain"
    /// Keychain account identifier, per the architecture contract.
    public static let account = "anthropic"

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
    /// CF-4 has to save a key through the *real* Security framework (an in-memory stand-in
    /// would prove nothing about what lands on disk), but `save(apiKey:)` replaces whatever
    /// is stored under `sh.memoir.brain` / `anthropic`, which is the user's own key. Binding
    /// this sends the test's sentinel to a throwaway item instead.
    ///
    /// It is a **task local**, not a global: parallel tests cannot see each other's binding,
    /// and production, which never binds it, is byte-identical to before.
    ///
    /// ```swift
    /// try await BrainKeychain.$itemOverride.withValue(.init(service: "sh.memoir.tests.x", account: "anthropic")) {
    ///     try BrainKeychain.save(apiKey: sentinel)
    ///     defer { try? BrainKeychain.delete() }
    /// }
    /// ```
    @TaskLocal public static var itemOverride: Item?

    /// The service identifier in force right now.
    static var currentService: String { itemOverride?.service ?? service }

    /// The account identifier in force right now.
    static var currentAccount: String { itemOverride?.account ?? account }

    // MARK: - CRUD

    /// Stores (or replaces) the API key in the login keychain.
    ///
    /// Saving an empty or whitespace-only string deletes the item instead, so "clear the field
    /// and save" does the obvious thing.
    /// - Throws: `MemoirError.invalidConfig` when the keychain refuses the write.
    public static func save(apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try delete()
            return
        }
        guard let data = trimmed.data(using: .utf8) else {
            throw MemoirError.invalidConfig("API key is not valid UTF-8.")
        }

        // Try an in-place update first so we keep the item's ACL and avoid re-prompting.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
        ]
        let update: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            Log.shared.info("Anthropic API key updated in Keychain.")
            return
        }
        if updateStatus != errSecItemNotFound {
            // Fall through to a delete + add, which recovers from most odd states.
            SecItemDelete(query as CFDictionary)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrLabel as String] = "Memoir: Anthropic API key"
        insert[kSecAttrDescription as String] = "Used only when the Anthropic brain is enabled."

        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw MemoirError.invalidConfig("Keychain write failed: \(message(for: addStatus))")
        }
        Log.shared.info("Anthropic API key saved to Keychain.")
    }

    /// Reads the API key, or nil when there is none (or the user denied access).
    ///
    /// Never throws: an unreadable key simply means the Anthropic brain is unavailable.
    public static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                Log.shared.warn("Keychain read failed: \(message(for: status))")
            }
            return nil
        }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Removes the API key. Succeeds silently when there was nothing to remove.
    /// - Throws: `MemoirError.invalidConfig` when the keychain refuses the delete.
    public static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: currentService,
            kSecAttrAccount as String: currentAccount,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MemoirError.invalidConfig("Keychain delete failed: \(message(for: status))")
        }
        Log.shared.info("Anthropic API key removed from Keychain.")
    }

    /// True when a key is present. Convenience for settings UI that must not display the key itself.
    public static func hasKey() -> Bool { load() != nil }

    // MARK: - Helpers

    /// Strips anything that looks like an API key out of a string before it reaches the log.
    /// Belt and braces: nothing in this module intentionally logs key material.
    public static func redact(_ text: String) -> String {
        guard text.contains("sk-") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            if text[index...].hasPrefix("sk-") {
                out += "sk-<redacted>"
                // Skip the whole token.
                var j = index
                while j < text.endIndex, !text[j].isWhitespace, text[j] != "\"", text[j] != "'" {
                    j = text.index(after: j)
                }
                index = j
            } else {
                out.append(text[index])
                index = text.index(after: index)
            }
        }
        return out
    }

    /// Human readable form of an `OSStatus` from the Security framework.
    private static func message(for status: OSStatus) -> String {
        if let s = SecCopyErrorMessageString(status, nil) as String? { return "\(s) (\(status))" }
        return "OSStatus \(status)"
    }
}
