import SwiftUI
import MemoirKit

/// The eight states the memory can be in.
///
/// Deliberately few. Each has to be readable at 19pt and distinguishable from every other at
/// a glance. Rendered as ``FoldMark``; see ``Expression/fold`` for what each one now means.
public enum Expression: String, Sendable, CaseIterable {
    case idle, happy, thinking, sleepy, alert, celebrate, concerned, wink

}

extension Expression {
    /// The same eight states, drawn as the mark instead of as a face.
    ///
    /// The vocabulary is inherited, the meaning is not. Each case now answers a question about
    /// the **memory** (is capture landing, is anything waiting, is the machine working), and
    /// none of them answers a question about how the user should feel.
    ///
    /// `happy`, `celebrate` and `wink` have no honest job here and render exactly as `idle`.
    /// They survive only because call sites still name them; new code should not.
    var fold: FoldTraits {
        switch self {
        // Capture is landing. The resting state, and what should be on screen almost always.
        case .idle, .happy, .celebrate, .wink:
            return FoldTraits(gap: 1.00, left: 1.00, right: 1.00, turn: 0.00, glow: 0.00)

        // Working: extraction, consolidation, an answer being assembled.
        case .thinking:
            return FoldTraits(gap: 1.35, left: 1.00, right: 1.00, turn: 0.10, glow: 0.00)

        // Idle or paused. The fold shuts: a book set down, not a light switched off. The
        // halves stay their own colours and only soften: dimming both towards grey would
        // compete with `concerned`, and the two states must never be confusable.
        case .sleepy:
            return FoldTraits(gap: 0.04, left: 0.78, right: 0.78, turn: 0.00, glow: 0.00)

        // Something is waiting on the user: a proposal to accept or reject. The gap lights,
        // because the gap is where everything the product will not decide for itself lives.
        case .alert:
            return FoldTraits(gap: 1.70, left: 1.00, right: 1.00, turn: 0.00, glow: 1.00)

        // Capture is not landing. The violet half (what it saw) goes dark, so half the
        // memory is visibly missing at any size. The one state that must never be subtle.
        case .concerned:
            return FoldTraits(gap: 1.00, left: 1.00, right: 0.10, turn: 0.00, glow: 0.00)
        }
    }
}

/// Drives the mark and the speech band.
///
/// Owns no timers the caller has to manage: expressions given a duration revert to
/// `.idle` on their own, and speech clears itself.
@MainActor
public final class CharacterModel: ObservableObject {

    @Published public private(set) var expression: Expression = .idle
    /// What capture is actually doing. A separate axis from ``expression`` on purpose.
    ///
    /// Expressions are moods: they are set for a few seconds and revert. Health is a fact,
    /// it holds for as long as it is true, and it outranks every mood: a mark that shows
    /// "thinking" while the memory is dead is the exact lie this exists to stop.
    @Published public private(set) var health: CaptureHealth = .starting
    @Published public private(set) var speech: String?
    /// Where the pupils are looking, in unit coordinates from -1 to 1.
    @Published private(set) var gaze: CGPoint = .zero
    /// 0 open, 1 fully shut. Driven by the blink timer.
    @Published private(set) var blink: Double = 0
    /// The alarm pulse, 0…1, driven while capture is faulted. Zero at every other time.
    @Published private(set) var alarm: Double = 0

    /// What the mark should actually draw: the mood, overruled by the fact.
    ///
    /// Every call site renders this rather than `expression.fold`, so there is exactly one
    /// place where health beats mood and no view can forget to apply it.
    var traits: FoldTraits {
        var traits = expression.fold
        switch health {
        case .starting, .capturing:
            return traits
        case .paused:
            // Deliberate, so it must not alarm. The fold shuts and both halves soften further
            // than any mood does: a book set down. Reads as *off*, never as broken.
            var shut = Expression.sleepy.fold
            shut.left = 0.62
            shut.right = 0.62
            return shut
        case .blocked, .stalled:
            // A fault. The violet half (what it saw) turns red and breathes, and keeps
            // doing so for as long as the fault lasts. Nothing else in this app pulses.
            //
            // The colour is at FULL red the whole time and only the *presence* breathes. The
            // first version pulsed the colour itself, between violet-ish and red, which meant
            // that half of every cycle the notch looked perfectly normal. A warning you
            // can catch at a healthy-looking moment is a warning that will be missed. Rendered
            // and looked at, which is the only way that was going to be noticed.
            traits.alarm = 1
            traits.right = 0.6 + alarm * 0.4
            traits.glow = 0
            return traits
        }
    }

    private var revertTask: Task<Void, Never>?
    private var speechTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var alarmTask: Task<Void, Never>?
    private var reduceMotion: Bool

    public init(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        self.reduceMotion = reduceMotion
        startIdleBehaviour()
    }

    deinit {
        revertTask?.cancel()
        speechTask?.cancel()
        idleTask?.cancel()
        alarmTask?.cancel()
    }

    /// Reports what capture is doing. Idempotent: an unchanged verdict does nothing.
    public func setHealth(_ new: CaptureHealth) {
        guard new != health else { return }
        health = new
        if new.isFault { startAlarm() } else { stopAlarm() }
    }

    /// The alarm heartbeat: a slow two-second breath, forever, until the fault clears.
    ///
    /// Slow on purpose. A fast blink in a menu bar is read as a glitch and then ignored;
    /// something breathing at the pace of a resting pulse is read as a state. Under Reduce
    /// Motion it holds at full alarm instead of moving; the colour still carries it.
    private func startAlarm() {
        alarmTask?.cancel()
        guard !reduceMotion else {
            withAnimation(.easeInOut(duration: 0.3)) { alarm = 1 }
            return
        }
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 1.0)) { self?.alarm = 1 }
                }
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 1.0)) { self?.alarm = 0 }
                }
                try? await Task.sleep(for: .milliseconds(1000))
            }
        }
    }

    private func stopAlarm() {
        alarmTask?.cancel()
        alarmTask = nil
        withAnimation(.easeInOut(duration: 0.3)) { alarm = 0 }
    }

    /// Sets an expression, optionally reverting to idle after a delay.
    public func set(_ e: Expression, for duration: TimeInterval? = nil) {
        revertTask?.cancel()
        expression = e
        guard let duration else { return }
        revertTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.expression = .idle }
        }
    }

    /// Says something with an expression, clearing both when the duration elapses.
    public func say(_ text: String, expression e: Expression = .happy, duration: TimeInterval = 6) {
        speechTask?.cancel()
        speech = text
        set(e, for: duration)
        speechTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.speech = nil }
        }
    }

    /// Clears speech and returns to idle immediately.
    public func clear() {
        revertTask?.cancel()
        speechTask?.cancel()
        speech = nil
        expression = .idle
    }

    /// Re-reads the system Reduce Motion setting.
    public func refreshMotionPreference() {
        reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if health.isFault { startAlarm() }
    }

    /// Blinks and lets the eyes wander so an idle face still looks alive.
    ///
    /// Skipped entirely under Reduce Motion.
    private func startIdleBehaviour() {
        guard !reduceMotion else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                let wait = Double.random(in: 3...7)
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.expression != .sleepy else { return }
                    // The breath is the "alive" signal, so it stops the moment the memory
                    // is not. Movement then means exactly one thing in each direction.
                    guard self.health.isHealthy else { return }
                    withAnimation(.easeInOut(duration: 0.07)) { self.blink = 1 }
                }
                try? await Task.sleep(for: .milliseconds(90))
                await MainActor.run {
                    guard let self else { return }
                    withAnimation(.easeInOut(duration: 0.09)) { self.blink = 0 }
                    if Bool.random() {
                        withAnimation(.easeInOut(duration: 0.8)) {
                            self.gaze = CGPoint(x: .random(in: -0.5...0.5), y: .random(in: -0.35...0.35))
                        }
                    }
                }
            }
        }
    }
}
