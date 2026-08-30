import Foundation

/// Assembles dictated words on top of whatever the user already typed.
///
/// The transcriber reports two kinds of result. **Volatile** results are the live guess at the
/// tail of what is being said and get replaced wholesale as the guess improves. **Final**
/// results are settled text that will never change again. Rendering both correctly means
/// keeping them apart: finals accumulate, the volatile tail is always the last thing and is
/// always thrown away and rewritten.
///
/// The buffer never owns the whole text field. Anything the user typed before dictation
/// started, or types in the middle of it via ``rebase(to:)``, is held as an untouchable
/// prefix. **Voice appends. It never clobbers.**
public struct DictationBuffer: Sendable, Equatable {

    /// Text the buffer must not touch: what the user typed.
    public private(set) var prefix: String

    /// Finalised dictation, in order.
    public private(set) var committed: String

    /// The live, still-changing tail. Replaced on every volatile result.
    public private(set) var volatileTail: String

    /// - Parameter prefix: whatever is already in the field.
    public init(prefix: String = "") {
        self.prefix = prefix
        self.committed = ""
        self.volatileTail = ""
    }

    /// The full text the field should show.
    public var text: String {
        [prefix, committed, volatileTail]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// True when this session has not produced a single word yet.
    public var isEmpty: Bool {
        committed.isEmpty && volatileTail.isEmpty
    }

    /// Accepts a settled segment. Clears the volatile tail, which this segment supersedes.
    public mutating func commit(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        volatileTail = ""
        guard !trimmed.isEmpty else { return }
        committed = committed.isEmpty ? trimmed : committed + " " + trimmed
    }

    /// Replaces the live tail with the transcriber's latest guess.
    public mutating func setVolatile(_ segment: String) {
        volatileTail = segment.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Adopts the field's current contents as the untouchable prefix.
    ///
    /// Called when the field no longer matches what the buffer last wrote, which means the
    /// user typed or edited while the mic was open. Everything on screen (their edit *and*
    /// the dictation so far) becomes prefix, and new speech continues after it. Without this
    /// the next volatile result would overwrite what they just typed.
    public mutating func rebase(to fieldText: String) {
        prefix = fieldText
        committed = ""
        volatileTail = ""
    }
}
