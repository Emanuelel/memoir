import Foundation

/// The state of the capture a provenance row points at, once it has been resolved
/// against storage.
///
/// Retention is two-tier: raw captures roll off after sixty days, structured memory
/// persists forever. That means a provenance row routinely outlives the capture it
/// names, and every reader has to cope with it. `capture_id` deliberately carries no
/// foreign key (see `Schema`), so the row survives; what disappears is the *source*,
/// not the evidence.
///
/// There is only one honest way to present that: the snippet is still shown, and the
/// source is labelled as expired. A missing capture is a normal, expected end state,
/// never an error and never a dangling identifier presented as if it still resolved.
public enum ProvenanceSource: Sendable, Equatable {

    /// The capture is still on disk.
    case available(CaptureEvent)

    /// The capture has been rolled off by retention. The snippet is all that is left.
    case expired

    /// The capture, or nil when it has expired.
    public var capture: CaptureEvent? {
        switch self {
        case .available(let capture): return capture
        case .expired: return nil
        }
    }

    /// True when the source capture is gone.
    public var isExpired: Bool {
        if case .expired = self { return true }
        return false
    }
}

/// One piece of evidence for one entity: the snippet, and whatever is left of where it
/// came from.
///
/// This is what a memory browser renders. It is deliberately a value type in `MemoirKit`
/// rather than a detail of the UI, so that the "source expired" state is testable and
/// so every reader (the app, the MCP server) degrades the same way.
public struct ProvenanceRecord: Sendable, Equatable, Identifiable {

    /// The stored provenance row. Never nil: the audit trail is what survives.
    public let provenance: Provenance

    /// The capture the row points at, or ``ProvenanceSource/expired``.
    public let source: ProvenanceSource

    /// Creates a record.
    public init(provenance: Provenance, source: ProvenanceSource) {
        self.provenance = provenance
        self.source = source
    }

    /// The provenance row's own identifier.
    public var id: ID { provenance.id }

    /// The exact text the entity field was derived from. Always present.
    public var snippet: String { provenance.snippet }

    /// Which entity field this evidence supports, e.g. `"title"`.
    public var field: String { provenance.field }

    /// When the evidence was recorded.
    public var ts: Date { provenance.ts }

    /// The capture this row names, whether or not it still exists.
    public var captureID: ID { provenance.captureID }

    /// The capture, or nil when it has rolled off.
    public var capture: CaptureEvent? { source.capture }

    /// True when the source capture has rolled off. The snippet is still valid.
    public var isSourceExpired: Bool { source.isExpired }

    /// What a user is shown in place of the source app and window.
    public static let expiredSourceLabel = "Source expired"

    /// A one line description of the source: app and window while the capture exists,
    /// ``expiredSourceLabel`` once it has rolled off.
    public var sourceDescription: String {
        guard let capture else { return Self.expiredSourceLabel }
        guard let title = capture.windowTitle, !title.isEmpty else { return capture.appName }
        return "\(capture.appName) · \(title)"
    }
}

extension Store {

    /// Every provenance row for an entity, each resolved against the capture it names.
    ///
    /// This is the read the memory browser performs. A capture that retention has
    /// removed resolves to ``ProvenanceSource/expired``: it never throws, never drops
    /// the row, and never hands back an identifier that no longer resolves.
    ///
    /// - Parameter entityID: The entity to explain. An unknown id yields an empty array.
    /// - Returns: Records newest first, matching ``provenance(entityID:)``.
    public func evidence(entityID: ID) throws -> [ProvenanceRecord] {
        let rows = try provenance(entityID: entityID)
        var resolved: [ID: ProvenanceSource] = [:]
        return try rows.map { row in
            if let known = resolved[row.captureID] {
                return ProvenanceRecord(provenance: row, source: known)
            }
            let source: ProvenanceSource = if let capture = try capture(id: row.captureID) {
                .available(capture)
            } else {
                .expired
            }
            resolved[row.captureID] = source
            return ProvenanceRecord(provenance: row, source: source)
        }
    }
}
