import Foundation

/// What dictation is doing right now.
///
/// This is the single thing the UI renders. The user must never be unsure whether the
/// microphone is hot, so every state has an unambiguous label and colour in the ask bar.
public enum VoiceState: Sendable, Equatable {
    /// Not listening. The microphone is closed and the audio engine is torn down.
    case idle
    /// Waiting on the user's answer to a Speech Recognition or Microphone prompt.
    case requestingPermission
    /// Fetching the on-device speech model for the selected language. `Double` is 0...1.
    /// This is a download from Apple, not an upload: no audio and no text is sent.
    case downloadingModel(Double)
    /// The microphone is open. `level` is the smoothed RMS of the input, 0...1.
    case listening(level: Float)
    /// Dictation cannot run, with a sentence the user can act on.
    case unavailable(String)

    /// True only when the microphone is actually open.
    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// True while something is in flight that the user is waiting on.
    public var isPreparing: Bool {
        switch self {
        case .requestingPermission, .downloadingModel: return true
        case .idle, .listening, .unavailable: return false
        }
    }

    /// The live input level, or zero when not listening.
    public var level: Float {
        if case .listening(let level) = self { return level }
        return 0
    }

    /// The reason dictation is unavailable, if it is.
    public var unavailableReason: String? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }

    /// Short label for the mic button.
    public var shortLabel: String {
        switch self {
        case .idle: return "Dictate"
        case .requestingPermission: return "Waiting for permission…"
        case .downloadingModel(let progress): return "Downloading speech model… \(Int(progress * 100))%"
        case .listening: return "Listening"
        case .unavailable: return "Voice unavailable"
        }
    }
}

// MARK: - State machine

/// The part of dictation that has no microphone in it.
///
/// `VoiceInput` owns one of these and asks it before touching any audio hardware, which is
/// what makes `start()` and `stop()` idempotent: the machine is the only thing that decides
/// whether a session is already running, so a double `stop()` can never tear down a tap twice
/// and a double `start()` can never leave a second `AVAudioEngine` running with the mic lit.
public struct VoiceMachine: Sendable, Equatable {

    /// What the UI shows.
    public private(set) var state: VoiceState = .idle

    /// True between an accepted `requestStart()` and the matching `requestStop()`.
    public private(set) var isRunning: Bool = false

    /// Increments on every accepted start. Late results from a finished session carry an old
    /// token and are discarded, so a previous dictation can never bleed into a new one.
    public private(set) var session: Int = 0

    public init() {}

    /// Asks to begin a session.
    /// - Returns: `true` when the caller must actually spin audio up. `false` when a session is
    ///   already running, in which case the caller must do nothing at all.
    public mutating func requestStart() -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        session &+= 1
        state = .requestingPermission
        return true
    }

    /// Asks to end a session.
    /// - Returns: `true` when the caller must actually tear audio down. `false` when nothing is
    ///   running, in which case the caller must do nothing at all.
    public mutating func requestStop() -> Bool {
        guard isRunning else { return false }
        isRunning = false
        // A failure the user still needs to read survives the stop; anything else goes quiet.
        if state.unavailableReason == nil { state = .idle }
        return true
    }

    /// Model assets are being fetched. Ignored once the session has ended.
    public mutating func downloading(_ progress: Double) {
        guard isRunning else { return }
        state = .downloadingModel(min(max(progress, 0), 1))
    }

    /// The microphone is now open.
    public mutating func opened() {
        guard isRunning else { return }
        state = .listening(level: 0)
    }

    /// Updates the meter. Only meaningful while listening.
    public mutating func setLevel(_ level: Float) {
        guard isRunning, state.isListening else { return }
        state = .listening(level: min(max(level, 0), 1))
    }

    /// Dictation cannot run. Ends the session and leaves the reason on screen.
    public mutating func fail(_ reason: String) {
        isRunning = false
        state = .unavailable(reason)
    }

    /// Clears a previous failure so the mic button reads as ready again.
    public mutating func clearFailure() {
        guard !isRunning, state.unavailableReason != nil else { return }
        state = .idle
    }
}

// MARK: - Permissions

/// Maps the two authorization answers dictation needs onto the state the user sees.
///
/// Kept free of any framework call so the mapping, including the exact System Settings pane
/// named in each message, is unit-testable without a microphone or a TCC prompt.
public enum VoicePermissions {

    /// One authorization answer, in framework-independent terms.
    public enum Grant: Sendable, Equatable, CaseIterable {
        case granted
        case denied
        case restricted
        case notDetermined
    }

    /// Which System Settings pane grants Speech Recognition.
    public static let speechPane = "System Settings > Privacy & Security > Speech Recognition"

    /// Which System Settings pane grants the microphone.
    public static let microphonePane = "System Settings > Privacy & Security > Microphone"

    /// - Returns: `nil` when both are granted and dictation may proceed, otherwise the
    ///   `.unavailable` state to publish, naming the pane the user has to open.
    public static func blockingState(speech: Grant, microphone: Grant) -> VoiceState? {
        // Speech first: it is the permission users are least likely to have granted, and
        // naming one pane at a time is more actionable than naming two.
        if let reason = reason(for: speech, what: "Speech Recognition", pane: speechPane) {
            return .unavailable(reason)
        }
        if let reason = reason(for: microphone, what: "the microphone", pane: microphonePane) {
            return .unavailable(reason)
        }
        return nil
    }

    private static func reason(for grant: Grant, what: String, pane: String) -> String? {
        switch grant {
        case .granted:
            return nil
        case .denied:
            return "Memoir is not allowed to use \(what). Turn Memoir on in \(pane), then try again."
        case .restricted:
            return "\(what.prefix(1).uppercased() + what.dropFirst()) is restricted on this Mac, "
                + "so Memoir cannot listen. Check \(pane)."
        case .notDetermined:
            return "Memoir has not been granted \(what) yet. Allow it when macOS asks, "
                + "or turn Memoir on in \(pane)."
        }
    }
}
