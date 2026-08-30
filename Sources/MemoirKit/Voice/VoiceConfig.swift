import Foundation

/// Dictation settings persisted in `config.json`.
///
/// Voice is a **local** feature: audio is transcribed by Apple's on-device speech models and
/// never leaves the machine, never touches the network, and is never written to disk. The
/// microphone only ever opens because somebody clicked the mic button, and closes with the band.
///
/// Decoding tolerates a missing or hand-edited section: every absent key falls back to its
/// default, so a `config.json` written before voice existed still loads cleanly.
public struct VoiceConfig: Sendable, Codable, Equatable {

    /// BCP-47 identifier of the language being dictated, e.g. `"en-US"`.
    /// Only locales in `SpeechTranscriber.supportedLocales` can actually be used.
    public var localeIdentifier: String = VoiceConfig.systemLocaleIdentifier

    /// Creates a configuration. Every parameter has the documented default.
    public init(localeIdentifier: String = VoiceConfig.systemLocaleIdentifier) {
        self.localeIdentifier = localeIdentifier
    }

    /// The configured language as a `Locale`.
    public var locale: Locale { Locale(identifier: localeIdentifier) }

    /// The user's current language, normalised to `language-REGION` where a region is known.
    /// Falls back to `en-US`, which is the one locale Apple ships transcription for everywhere.
    public static var systemLocaleIdentifier: String {
        let current = Locale.current
        guard let language = current.language.languageCode?.identifier else { return "en-US" }
        if let region = current.region?.identifier { return "\(language)-\(region)" }
        return language
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case localeIdentifier
    }

    /// Decodes a configuration, filling in defaults for any key the file omits.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VoiceConfig()
        localeIdentifier = try c.decodeIfPresent(String.self, forKey: .localeIdentifier)
            ?? defaults.localeIdentifier
    }
}
