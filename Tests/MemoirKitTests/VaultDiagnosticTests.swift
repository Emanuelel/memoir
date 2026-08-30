import Testing
import Foundation
@testable import MemoirKit

/// A diagnostic, not a contract: does the real vault on this machine open with the real key?
///
/// Kept because the answer decided whether a live memory was recoverable, and because the
/// question "can our own code open the container our own code made" is worth being able to ask
/// again without hand-deriving a passphrase in a shell.
@Suite(.serialized)
struct VaultDiagnosticTests {

    @Test("the vault on this machine opens with the key in this keychain", .disabled("diagnostic: reads the real keychain, which prompts"))
    func realVaultOpens() throws {
        let key = try VaultKey.load()
        let bundle = EncryptedVault.bundleURL()
        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("memoir-diag-\(UUID().uuidString)", isDirectory: true)
        defer { EncryptedVault.detach(mountPoint: mount) }

        print("key bytes: \(key.count)")
        print("bundle   : \(bundle.path)")
        try EncryptedVault.attach(key: key, bundle: bundle, mountPoint: mount)
        let db = mount.appendingPathComponent("memoir.sqlite")
        print("database exists: \(FileManager.default.fileExists(atPath: db.path))")
    }
}
