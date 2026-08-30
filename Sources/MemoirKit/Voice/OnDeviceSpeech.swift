import Foundation
import Speech

/// The privacy floor for dictation, in one place.
///
/// `SFSpeechRecognizer`, the macOS 15 fallback path, will happily stream audio to Apple's
/// servers if you let it. Memoir never lets it. Every request Memoir builds has
/// `requiresOnDeviceRecognition = true`, and when a locale cannot be recognised on-device Memoir
/// reports the feature as unavailable instead of quietly going over the wire.
///
/// These helpers exist as free functions so that requirement is testable without a microphone.
public enum OnDeviceSpeech {

    /// Builds a streaming recognition request that can only ever run on this Mac.
    ///
    /// - Important: `requiresOnDeviceRecognition` is set unconditionally. Nothing in Memoir may
    ///   construct an `SFSpeechRecognitionRequest` any other way.
    public static func makeRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        return request
    }

    /// True when the request is safe to run: on-device only, as Memoir requires.
    /// Used as a belt-and-braces assertion before any audio is fed in.
    public static func isOnDeviceOnly(_ request: SFSpeechRecognitionRequest) -> Bool {
        request.requiresOnDeviceRecognition
    }

    /// Why a locale cannot be dictated without leaving the Mac.
    public static func offDeviceReason(locale: Locale) -> String {
        let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        return "macOS cannot transcribe \(name) on this Mac without sending audio to Apple, "
            + "so Memoir will not use it. Pick another language in Settings > Voice, or install "
            + "the \(name) dictation language in System Settings > Keyboard > Dictation."
    }

    /// Translates the Speech framework's authorization status into the framework-independent
    /// value ``VoicePermissions`` reasons about.
    public static func grant(for status: SFSpeechRecognizerAuthorizationStatus) -> VoicePermissions.Grant {
        switch status {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}
