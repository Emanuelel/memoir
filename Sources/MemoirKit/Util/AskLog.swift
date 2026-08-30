import Foundation

/// A local, append-only transcript of every question, the context it was given, and the
/// answer that came back.
///
/// This exists to make answer quality *reviewable*. Without it there is no way to tell a
/// bad answer from a bad context packet from the wrong brain: you only see the final
/// string and have to guess which stage failed.
///
/// Stays on this machine like everything else: one JSONL file next to the database, never
/// transmitted, capped so it cannot grow without bound, and deleted by "Delete everything"
/// along with the rest.
public struct AskLog: Sendable {
    public static let shared = AskLog()
    private init() {}

    /// Roughly a few thousand exchanges. Old lines are dropped from the front.
    private static let maxBytes = 4 * 1024 * 1024

    public struct Entry: Codable, Sendable {
        public let ts: Date
        public let question: String
        public let answer: String
        public let brain: String
        public let latency: TimeInterval
        /// What the brain was actually shown. The usual cause of a useless answer.
        public let contextSummary: String
        public let contextTokens: Int
        public let citedCaptureIDs: [ID]
        public let entityIDs: [ID]
        /// Set when the preferred brain failed and the router fell through.
        public let fallbackReason: String?
    }

    public static func url() -> URL {
        Paths.logsDirectory().appendingPathComponent("asks.jsonl")
    }

    /// Appends one exchange. Never throws: a logging failure must not break an answer.
    public func record(
        question: String,
        answer: String,
        brain: BrainKind,
        latency: TimeInterval,
        context: ContextPacket,
        fallbackReason: String? = nil
    ) {
        let entry = Entry(
            ts: Date(),
            question: question,
            answer: answer,
            brain: brain.rawValue,
            latency: latency,
            contextSummary: context.summary,
            contextTokens: context.approxTokens,
            citedCaptureIDs: context.captureIDs,
            entityIDs: context.entityIDs,
            fallbackReason: fallbackReason
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entry),
              var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"

        let url = Self.url()
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
        trimIfNeeded(url)
    }

    /// Reads the most recent exchanges, newest first.
    public func recent(limit: Int = 20) -> [Entry] {
        guard let text = try? String(contentsOf: Self.url(), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text
            .split(separator: "\n")
            .suffix(limit)
            .reversed()
            .compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    public func purge() {
        try? FileManager.default.removeItem(at: Self.url())
    }

    private func trimIfNeeded(_ url: URL) {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
              size > Self.maxBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.suffix(lines.count / 2).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
