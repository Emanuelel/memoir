import Foundation

/// Why a capture happened.
///
/// Stored with nothing and shown to no one: it exists so the decision to spend a tree walk
/// is explicit and testable rather than "the timer went off again".
public enum CaptureTrigger: String, Sendable, Equatable, CaseIterable {
    /// The frontmost application changed.
    case appSwitch
    /// Same app, different window or document.
    case windowChange
    /// The user typed and then stopped. The moment their text is worth reading.
    case typingPause
    /// Nothing happened for a while; take one anyway so a long read is still recorded.
    case idleFallback
    /// Capture was resumed, or the loop just started.
    case resume
    /// A caller asked directly. Never debounced.
    case manual

    /// Burst-prone triggers get a higher floor than the global one: continuous typing
    /// would otherwise chain a full tree walk per keystroke.
    var isCheckpoint: Bool { self == .typingPause }
}

/// The cheap signals sampled on every loop tick.
///
/// Reading these costs microseconds: a `NSWorkspace` property, one accessibility title
/// read, and two `CGEventSource` counters. Nothing here walks a tree.
public struct CaptureSignals: Sendable, Equatable {
    public let bundleID: String?
    public let windowTitle: String?
    /// Seconds since any HID event. Drives idleness.
    public let idleSeconds: Double
    /// Seconds since the last key press. Drives typing-pause detection.
    public let secondsSinceKeystroke: Double

    public init(
        bundleID: String?,
        windowTitle: String?,
        idleSeconds: Double,
        secondsSinceKeystroke: Double
    ) {
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.idleSeconds = idleSeconds
        self.secondsSinceKeystroke = secondsSinceKeystroke
    }
}

/// Decides whether a set of cheap signals justifies an expensive capture.
///
/// Pure and clock-injected so every rule is unit-testable without a screen, a keyboard or a
/// sleep. This is the whole point of the event-driven rewrite: the expensive work is gated
/// by a decision you can read, rather than by a timer you can only wait out.
public struct TriggerDetector: Sendable {
    private var lastBundleID: String?
    private var lastWindowTitle: String?
    private var lastCaptureAt: Date?
    /// True once a keystroke has been seen and we are waiting for the pause that follows.
    private var typingInFlight = false

    public init() {}

    /// Strips the volatile decorations apps put in their own title bars.
    ///
    /// A WhatsApp tab retitles itself "(1) WhatsApp", "(2) WhatsApp", "(3) WhatsApp" as
    /// messages arrive, and a fullscreen toggle appends its own hint. Comparing raw titles
    /// made each of those a `windowChange`, so one conversation produced four near-identical
    /// captures, the exact duplication the event-driven rewrite exists to prevent.
    static func normalizeTitle(_ raw: String) -> String {
        var t = raw
        // Leading unread/notification counters: "(3) Inbox", "[2] Slack".
        if let match = t.range(of: "^\\s*[\\(\\[]\\d+[\\)\\]]\\s*", options: .regularExpression) {
            t.removeSubrange(match)
        }
        // Trailing bullet some apps use for unsaved changes.
        while t.hasSuffix("•") || t.hasSuffix("*") { t.removeLast() }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// - Returns: the trigger to capture on, or nil to stay quiet this tick.
    public mutating func evaluate(
        _ signals: CaptureSignals,
        config: CaptureConfig,
        now: Date,
        isFirstTick: Bool = false
    ) -> CaptureTrigger? {
        let candidate = detect(signals, config: config, isFirstTick: isFirstTick)

        // Record what we saw regardless of whether we capture, so a change that is
        // debounced away is not reported again on the next tick.
        lastBundleID = signals.bundleID
        lastWindowTitle = signals.windowTitle.map(Self.normalizeTitle)

        guard let candidate else { return nil }
        guard passesDebounce(candidate, now: now, config: config) else { return nil }
        lastCaptureAt = now
        return candidate
    }

    /// Marks a capture as having happened without one being triggered here. Used when the
    /// loop captures for its own reasons, so the floors stay honest.
    public mutating func noteCapture(at now: Date) {
        lastCaptureAt = now
    }

    private mutating func detect(
        _ signals: CaptureSignals,
        config: CaptureConfig,
        isFirstTick: Bool
    ) -> CaptureTrigger? {
        if isFirstTick { return .resume }

        // The user is away. One fallback capture per idle interval, no more.
        if signals.idleSeconds >= config.effectiveIdleThreshold {
            typingInFlight = false
            return nil
        }

        if signals.bundleID != lastBundleID { typingInFlight = false; return .appSwitch }

        let title = signals.windowTitle.map(Self.normalizeTitle)
        if let title, title != lastWindowTitle, lastWindowTitle != nil {
            typingInFlight = false
            return .windowChange
        }

        // Typing pause: a keystroke was seen recently, and the keyboard has now been quiet
        // long enough that what is on screen has settled.
        if signals.secondsSinceKeystroke < config.typingPauseSeconds {
            typingInFlight = true
        } else if typingInFlight {
            typingInFlight = false
            return .typingPause
        }

        return nil
    }

    private func passesDebounce(
        _ trigger: CaptureTrigger,
        now: Date,
        config: CaptureConfig
    ) -> Bool {
        if trigger == .manual { return true }
        guard let last = lastCaptureAt else { return true }
        let elapsed = now.timeIntervalSince(last)
        let floor = trigger.isCheckpoint
            ? max(config.checkpointIntervalSeconds, config.minCaptureIntervalSeconds)
            : config.minCaptureIntervalSeconds
        return elapsed >= floor
    }

    /// Whether enough quiet time has passed to justify the periodic fallback capture.
    public func idleFallbackDue(now: Date, config: CaptureConfig) -> Bool {
        guard let last = lastCaptureAt else { return true }
        return now.timeIntervalSince(last) >= config.idleCaptureIntervalSeconds
    }
}
