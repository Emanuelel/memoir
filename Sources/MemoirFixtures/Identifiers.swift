//
//  Identifiers.swift
//  Deterministic identifiers for anything seeded from this module.
//

import CryptoKit
import Foundation
import MemoirKit

// MARK: - Deterministic identifiers

/// UUID-shaped identifiers derived from their inputs, so a fixture built twice is byte
/// identical. Nothing that seeds a world may call `UUID()`: not the suite, not the seeder.
public enum TestID {

    /// A stable lowercase UUID-shaped `ID` for the given parts.
    public static func stable(_ parts: String...) -> ID { stable(parts) }

    /// A stable lowercase UUID-shaped `ID` for the given parts.
    public static func stable(_ parts: [String]) -> ID {
        let joined = parts.joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(joined.utf8))
        let hex = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let c = Array(hex)
        func slice(_ from: Int, _ to: Int) -> String { String(c[from..<to]) }
        return "\(slice(0, 8))-\(slice(8, 12))-\(slice(12, 16))-\(slice(16, 20))-\(slice(20, 32))"
    }
}
