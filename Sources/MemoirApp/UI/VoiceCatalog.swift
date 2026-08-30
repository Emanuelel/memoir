import Foundation
import Speech
import MemoirKit

/// One language the user can dictate in.
struct VoiceLocaleOption: Sendable, Identifiable, Equatable {
    /// BCP-47 identifier, e.g. `"en-US"`.
    let identifier: String
    /// Localised language name for the picker.
    let name: String
    /// Whether the on-device model is already on disk. When false, using it triggers a download.
    let installed: Bool

    var id: String { identifier }
}

/// What Settings needs to know about speech models, without any of the audio machinery.
///
/// Everything here reads or downloads Apple's local models. The only network traffic Memoir can
/// ever produce from this file is Apple's own model download, which sends nothing of the user's.
enum VoiceCatalog {

    /// Every language dictation supports, sorted by name, marked with whether it is installed.
    static func options() async -> [VoiceLocaleOption] {
        if #available(macOS 26.0, *) {
            let supported = await SpeechTranscriber.supportedLocales
            let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            return supported
                .map { locale in
                    VoiceLocaleOption(
                        identifier: locale.identifier(.bcp47),
                        name: displayName(locale),
                        installed: installed.contains(locale.identifier(.bcp47))
                    )
                }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        // macOS 15: no asset inventory. A locale counts as usable only when it can be
        // recognised on-device, because Memoir will not fall back to Apple's servers.
        return SFSpeechRecognizer.supportedLocales()
            .map { locale in
                VoiceLocaleOption(
                    identifier: locale.identifier(.bcp47),
                    name: displayName(locale),
                    installed: SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A sentence describing whether the given language is ready to dictate in.
    static func status(for locale: Locale) async -> String {
        if #available(macOS 26.0, *) {
            guard SpeechTranscriber.isAvailable else {
                return "Speech transcription is not available on this Mac."
            }
            guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                return "\(displayName(locale)) is not supported for transcription on this Mac."
            }
            let installed = await SpeechTranscriber.installedLocales
            let present = installed.contains { $0.identifier(.bcp47) == matched.identifier(.bcp47) }
            return present
                ? "\(displayName(matched)) model is installed. Dictation runs entirely on this Mac."
                : "\(displayName(matched)) model is not downloaded yet. It downloads once, then stays local."
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return "macOS has no speech recogniser for \(displayName(locale))."
        }
        return recognizer.supportsOnDeviceRecognition
            ? "\(displayName(locale)) can be recognised on this Mac."
            : "\(displayName(locale)) cannot be recognised on this Mac, so Memoir will not use it."
    }

    /// True when the model is already present and nothing needs downloading.
    static func isInstalled(_ locale: Locale) async -> Bool {
        if #available(macOS 26.0, *) {
            guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return false }
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains { $0.identifier(.bcp47) == matched.identifier(.bcp47) }
        }
        return SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition ?? false
    }

    /// Downloads the on-device model for a language.
    ///
    /// - Parameter progress: called on the main actor with 0...1 as the download advances.
    /// - Throws: ``VoiceCatalogError`` when there is nothing to download or the OS refuses.
    static func downloadModel(
        for locale: Locale,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        guard #available(macOS 26.0, *) else {
            throw VoiceCatalogError.notDownloadable(
                "On this version of macOS, dictation languages are installed from "
                + "System Settings > Keyboard > Dictation."
            )
        }
        guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw VoiceCatalogError.notDownloadable(
                "\(displayName(locale)) is not supported for transcription on this Mac."
            )
        }
        let transcriber = SpeechTranscriber(
            locale: matched,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            throw VoiceCatalogError.notDownloadable(
                "macOS reports nothing to download for \(displayName(matched))."
            )
        }
        let observation = request.progress.observe(\.fractionCompleted) { reported, _ in
            let fraction = reported.fractionCompleted
            Task { @MainActor in progress(fraction) }
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        await MainActor.run { progress(1) }
    }

    static func displayName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier(.bcp47)
    }
}

enum VoiceCatalogError: LocalizedError {
    case notDownloadable(String)

    var errorDescription: String? {
        switch self {
        case .notDownloadable(let message): return message
        }
    }
}
