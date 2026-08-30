import AVFoundation
import Foundation
import Speech
import MemoirKit
import os

/// Native, on-device dictation for the ask bar.
///
/// Click the microphone: it opens, words appear in the field as you say them, Return sends and
/// closes it. **Nothing else ever opens it**: not ⌥Space, not landing on the Ask tab. Typing is
/// untouched; dictation only ever appends to what is already in the field (see
/// ``DictationBuffer``).
///
/// **Nothing here touches the network.** On macOS 26 this drives `SpeechAnalyzer` +
/// `SpeechTranscriber`, which run against locally installed models. On macOS 15 it falls back to
/// `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`; if a locale cannot be
/// recognised locally, Memoir reports the feature unavailable rather than streaming audio to Apple.
/// Audio is never written to disk and never leaves the process.
@MainActor
public final class VoiceInput: ObservableObject {

    // MARK: - Published state

    /// What dictation is doing. The ask bar renders this and nothing else.
    @Published public private(set) var state: VoiceState = .idle

    // MARK: - Wiring

    /// Reads the field's current text. Used to notice that the user typed mid-dictation.
    public var currentText: (@MainActor () -> String)?

    /// Writes the assembled text back into the field.
    public var applyText: (@MainActor (String) -> Void)?

    // MARK: - Configuration

    private var config: VoiceConfig

    public init(config: VoiceConfig = VoiceConfig()) {
        self.config = config
    }

    /// Applies new settings. Changing the language ends any running session, because the
    /// analyzer is built around exactly one locale.
    public func updateConfig(_ config: VoiceConfig) {
        let localeChanged = config.localeIdentifier != self.config.localeIdentifier
        self.config = config
        guard localeChanged else { return }
        stop()
        machine.clearFailure()
        publish()
    }

    /// The language dictation will use.
    public var locale: Locale { config.locale }

    // MARK: - Private state

    private var machine = VoiceMachine()
    private var buffer = DictationBuffer()

    private var audio: AudioSession?

    /// Ends whichever input pipe the current session is using. Set by the path that opened it,
    /// so no macOS 26 type ever has to be stored on a macOS 15 class.
    private var finishInput: (@Sendable () -> Void)?

    private var analyzerBox: AnyObject?         // SpeechAnalyzer, macOS 26 only
    private var transcriberBox: AnyObject?      // SpeechTranscriber, macOS 26 only
    private var legacyTask: SFSpeechRecognitionTask?

    private var startTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var meterTask: Task<Void, Never>?
    private var downloadObservation: NSKeyValueObservation?

    /// Written from the realtime audio thread, read from the main actor.
    /// `OSAllocatedUnfairLock` is `Sendable` and cheap enough to take in a tap callback.
    private let meter = OSAllocatedUnfairLock(initialState: Float(0))

    /// The text this object last wrote into the field. When the field differs from this, the
    /// user typed, and the buffer rebases rather than overwriting them.
    private var lastEmitted: String = ""

    // MARK: - Lifecycle

    /// Opens the microphone. Idempotent: calling it while a session is running does nothing.
    public func start() {
        machine.clearFailure()
        guard machine.requestStart() else { return }
        let session = machine.session
        publish()

        // Whatever is already typed becomes the untouchable prefix. `lastEmitted` holds the
        // field verbatim, so the first result is not mistaken for the user having edited.
        let existing = currentText?() ?? ""
        buffer = DictationBuffer(prefix: existing)
        lastEmitted = existing

        startTask?.cancel()
        startTask = Task { [weak self] in
            await self?.begin(session: session)
        }
    }

    /// Closes the microphone and tears everything down. Idempotent, and safe to call from
    /// `dismiss()`, from submit, from Escape, and in any order.
    ///
    /// A leaked `AVAudioEngine` keeps the orange microphone indicator lit in the menu bar, so
    /// the tap comes off and the engine stops before anything else, unconditionally.
    public func stop() {
        let wasRunning = machine.requestStop()
        teardownAudio()

        startTask?.cancel(); startTask = nil
        meterTask?.cancel(); meterTask = nil
        downloadObservation?.invalidate(); downloadObservation = nil

        // Let the analyzer drain rather than cancelling it: the last volatile words become
        // final only after the input ends, and those are words the user actually said.
        // `resultsTask` finishes by itself when the stream does.
        finishInput?(); finishInput = nil

        if #available(macOS 26.0, *), let analyzer = analyzerBox as? SpeechAnalyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
        analyzerBox = nil
        transcriberBox = nil
        legacyTask?.finish(); legacyTask = nil

        if wasRunning { publish() }
    }

    /// Mic button behaviour: hot becomes cold, cold becomes hot.
    public func toggle() {
        if machine.isRunning { stop() } else { start() }
    }

    deinit {
        // `deinit` is nonisolated, so this cannot call `stop()`. Kill the hardware directly:
        // leaving the tap installed would keep the microphone indicator lit. `AudioSession`
        // exists precisely so this line is reachable from here.
        audio?.shutdown()
        finishInput?()
    }

    // MARK: - Session

    private func begin(session: Int) async {
        // An unbundled binary has no usage strings, and asking for the microphone without one
        // terminates the process. A missing prerequisite has cost this project a crash before;
        // refuse loudly instead of dying.
        guard hasUsageDescriptions else {
            fail("Voice needs the bundled Memoir.app. Run Scripts/build-app.sh and launch that.")
            return
        }

        let speech = await requestSpeechAuthorization()
        guard isCurrent(session) else { return }
        let microphone = await requestMicrophoneAccess()
        guard isCurrent(session) else { return }

        if let blocked = VoicePermissions.blockingState(speech: speech, microphone: microphone) {
            fail(blocked.unavailableReason ?? "Memoir is not allowed to listen.")
            return
        }

        if #available(macOS 26.0, *) {
            await beginModern(session: session)
        } else {
            await beginLegacy(session: session)
        }
    }

    /// True when `session` is still the live one and has not been stopped.
    private func isCurrent(_ session: Int) -> Bool {
        machine.session == session && machine.isRunning
    }

    /// True when the running bundle declares the two usage strings TCC requires.
    private var hasUsageDescriptions: Bool {
        let info = Bundle.main.infoDictionary
        return info?["NSMicrophoneUsageDescription"] != nil
            && info?["NSSpeechRecognitionUsageDescription"] != nil
    }

    // MARK: - macOS 26: SpeechAnalyzer + SpeechTranscriber

    @available(macOS 26.0, *)
    private func beginModern(session: Int) async {
        guard SpeechTranscriber.isAvailable else {
            await beginLegacy(session: session)
            return
        }

        let requested = config.locale
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            fail("macOS does not transcribe \(languageName(requested)) on this Mac. "
                 + "Pick another language in Settings > Voice.")
            return
        }
        guard isCurrent(session) else { return }

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )

        guard await ensureModel(for: transcriber, locale: locale, session: session) else { return }
        guard isCurrent(session) else { return }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            fail("No audio format on this Mac works with the speech model. Try another language.")
            return
        }
        guard isCurrent(session) else { return }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        finishInput = { continuation.finish() }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        analyzerBox = analyzer
        transcriberBox = transcriber

        do {
            try await analyzer.start(inputSequence: stream)
        } catch {
            Log.shared.error("speech analyzer would not start: \(error)")
            fail("The speech engine would not start. Try again, or turn voice off in Settings > Voice.")
            return
        }
        guard isCurrent(session) else { return }

        resultsTask?.cancel()
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(
                        text: String(result.text.characters),
                        isFinal: result.isFinal,
                        session: session
                    )
                }
            } catch {
                Log.shared.error("transcription stream ended: \(error)")
            }
        }

        let started = startAudio(convertingTo: format, session: session) { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        guard started else { return }

        machine.opened()
        publish()
        startMeter(session: session)
    }

    /// Makes sure the on-device model for `locale` is present, downloading it if it is not.
    ///
    /// A missing model is a first-class state, never a crash and never a silent failure: the
    /// user watches a percentage on the mic button while it fetches. Returns `false` when the
    /// model cannot be made available, having already published the reason.
    @available(macOS 26.0, *)
    private func ensureModel(
        for transcriber: SpeechTranscriber,
        locale: Locale,
        session: Int
    ) async -> Bool {
        let installed = await SpeechTranscriber.installedLocales
        let wanted = locale.identifier(.bcp47)
        if installed.contains(where: { $0.identifier(.bcp47) == wanted }) { return true }

        machine.downloading(0)
        publish()

        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
                // Nothing left to install, yet the locale still is not installed.
                fail("macOS has no downloadable speech model for \(languageName(locale)). "
                     + "Pick another language in Settings > Voice.")
                return false
            }
            guard isCurrent(session) else { return false }

            downloadObservation?.invalidate()
            downloadObservation = request.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
                let fraction = progress.fractionCompleted
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(session) else { return }
                    self.machine.downloading(fraction)
                    self.publish()
                }
            }

            try await request.downloadAndInstall()
            downloadObservation?.invalidate(); downloadObservation = nil
            return isCurrent(session)
        } catch {
            downloadObservation?.invalidate(); downloadObservation = nil
            Log.shared.error("speech model download failed: \(error)")
            fail("The \(languageName(locale)) speech model could not be downloaded. Check your "
                 + "connection and try again. This is a one-off download from Apple; nothing of "
                 + "yours is uploaded.")
            return false
        }
    }

    // MARK: - macOS 15: SFSpeechRecognizer

    private func beginLegacy(session: Int) async {
        guard let recognizer = SFSpeechRecognizer(locale: config.locale) else {
            fail("macOS has no speech recogniser for this language. Pick another in Settings > Voice.")
            return
        }
        guard recognizer.isAvailable else {
            fail("The speech recogniser is not available right now. Try again in a moment.")
            return
        }
        // Hard privacy requirement: no locale is ever allowed to fall through to Apple's servers.
        guard recognizer.supportsOnDeviceRecognition else {
            fail(OnDeviceSpeech.offDeviceReason(locale: config.locale))
            return
        }

        let request = OnDeviceSpeech.makeRequest()
        guard OnDeviceSpeech.isOnDeviceOnly(request) else {
            fail("Memoir refused to start dictation because it could not guarantee it stays on this Mac.")
            return
        }

        let sink = LegacyRequestSink(request: request)
        finishInput = { sink.finish() }

        legacyTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error { Log.shared.error("legacy recognition ended: \(error)") }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            let isFinal = result.isFinal
            Task { @MainActor [weak self] in
                self?.receive(text: text, isFinal: isFinal, session: session)
            }
        }

        // The recogniser accepts the input node's own format, so no conversion is needed here.
        let started = startAudio(convertingTo: nil, session: session) { buffer in
            sink.append(buffer)
        }
        guard started else { return }

        machine.opened()
        publish()
        startMeter(session: session)
    }

    // MARK: - Audio

    /// Opens the input node and pumps buffers into `sink`.
    ///
    /// - Parameter format: the format the transcriber asked for, or `nil` when the consumer takes
    ///   the input node's own format. **Formats are never assumed to match**: an
    ///   `AVAudioConverter` sits in between whenever they differ.
    /// - Returns: `false` when audio could not start, having already published the reason.
    private func startAudio(
        convertingTo format: AVAudioFormat?,
        session: Int,
        sink: @escaping @Sendable (AVAudioPCMBuffer) -> Void
    ) -> Bool {
        let audio = AudioSession()
        let inputFormat = audio.inputFormat

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            fail("No microphone is available. Connect one, or pick a different input in "
                 + "System Settings > Sound.")
            return false
        }

        let pipe: AudioConversionPipe?
        if let format, format != inputFormat {
            guard let made = AudioConversionPipe(from: inputFormat, to: format) else {
                fail("This Mac's microphone format cannot be converted for the speech model.")
                return false
            }
            pipe = made
        } else {
            pipe = nil
        }

        let meter = self.meter
        do {
            try audio.start { buffer, _ in
                let level = AudioLevel.rms(of: buffer)
                meter.withLock { $0 = level }
                // The tap reuses its buffer between callbacks, so anything handed to an async
                // consumer is copied first or it gets overwritten mid-flight.
                guard let outgoing = pipe?.convert(buffer) ?? buffer.detachedCopy() else { return }
                sink(outgoing)
            }
        } catch {
            Log.shared.error("audio engine would not start: \(error)")
            fail("The microphone could not be opened. Another app may be using it.")
            return false
        }

        guard isCurrent(session) else {
            audio.shutdown()
            return false
        }
        self.audio = audio
        return true
    }

    private func teardownAudio() {
        audio?.shutdown()
        audio = nil
        meter.withLock { $0 = 0 }
    }

    /// Publishes the input level on a slow, fixed cadence.
    ///
    /// Deliberately not driven from the tap: that fires ~90 times a second on a realtime thread
    /// and would redraw the ask bar (text field included) at the same rate.
    private func startMeter(session: Int) {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var lastPublished: Float = -1
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard !Task.isCancelled, let self, self.isCurrent(session) else { return }
                let level = self.meter.withLock { $0 }
                guard abs(level - lastPublished) > 0.02 else { continue }
                lastPublished = level
                self.machine.setLevel(level)
                self.publish()
            }
        }
    }

    // MARK: - Text

    /// Folds one transcription result into the field.
    private func receive(text: String, isFinal: Bool, session: Int) {
        guard machine.session == session else { return }   // a finished session's tail

        // The user typed while the mic was open. Take what is on screen as the new floor so
        // their keystrokes survive; dictation carries on after them.
        let onScreen = currentText?() ?? lastEmitted
        if onScreen != lastEmitted { buffer.rebase(to: onScreen) }

        if isFinal {
            buffer.commit(text)
        } else {
            buffer.setVolatile(text)
        }

        let assembled = buffer.text
        guard assembled != lastEmitted else { return }
        lastEmitted = assembled
        applyText?(assembled)
    }

    // MARK: - Helpers

    private func fail(_ reason: String) {
        teardownAudio()
        finishInput?(); finishInput = nil
        legacyTask?.finish(); legacyTask = nil
        analyzerBox = nil
        transcriberBox = nil
        meterTask?.cancel(); meterTask = nil
        downloadObservation?.invalidate(); downloadObservation = nil
        machine.fail(reason)
        publish()
    }

    private func publish() {
        if state != machine.state { state = machine.state }
    }

    private func languageName(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func requestSpeechAuthorization() async -> VoicePermissions.Grant {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined { return OnDeviceSpeech.grant(for: current) }
        let status: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            // `requestAuthorization` calls back on an arbitrary XPC queue. This type is
            // @MainActor, so an unannotated closure inherits main-actor isolation, Swift 6
            // asserts the executor on entry and the process dies with SIGTRAP the instant
            // the user clicks Allow. @Sendable opts the closure out of that inheritance.
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
        return OnDeviceSpeech.grant(for: status)
    }

    private func requestMicrophoneAccess() async -> VoicePermissions.Grant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio) ? .granted : .denied
        @unknown default: return .denied
        }
    }
}

// MARK: - Audio plumbing

/// Owns the capture engine and its tap.
///
/// A class rather than a stored `AVAudioEngine` so that `VoiceInput.deinit`, which is
/// nonisolated and therefore cannot touch a non-`Sendable` stored property, can still
/// guarantee the tap comes off. A leaked tap keeps the microphone indicator lit in the menu
/// bar, which is exactly the bug users never forgive.
private final class AudioSession: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let tapped = OSAllocatedUnfairLock(initialState: false)

    /// The hardware's own format. Never assumed to match what the transcriber wants.
    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    func start(tap: @escaping AVAudioNodeTapBlock) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat, block: tap)
        tapped.withLock { $0 = true }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            shutdown()
            throw error
        }
    }

    /// Idempotent: removing a tap twice would trap, so the flag is checked and cleared atomically.
    func shutdown() {
        let wasTapped = tapped.withLock { state -> Bool in
            let previous = state
            state = false
            return previous
        }
        if wasTapped { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
    }
}

/// Converts microphone buffers into the format the transcriber asked for.
///
/// Its own class because the tap block runs on a realtime audio thread and `AVAudioConverter`
/// is not `Sendable`. The instance is created before the tap is installed and only ever touched
/// from inside it, which is what the unchecked conformance asserts.
private final class AudioConversionPipe: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat

    init?(from input: AVAudioFormat, to output: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: output) else { return nil }
        self.converter = converter
        self.outputFormat = output
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let source = SingleBufferSource(buffer)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            source.next(outStatus)
        }

        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Hands one buffer to `AVAudioConverter` and then reports "no more".
///
/// The converter's input block is `@Sendable`, so the buffer and the has-been-supplied flag
/// cannot simply be captured. Both live here instead, touched only from the single synchronous
/// `convert` call that created it.
private final class SingleBufferSource: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let pending = buffer else {
            status.pointee = .noDataNow
            return nil
        }
        buffer = nil
        status.pointee = .haveData
        return pending
    }
}

/// Feeds the macOS 15 recogniser from the audio thread.
///
/// `SFSpeechAudioBufferRecognitionRequest` is documented as safe to append to from a capture
/// callback but is not `Sendable`, so it is fenced off here rather than captured directly.
private final class LegacyRequestSink: @unchecked Sendable {
    private let request: SFSpeechAudioBufferRecognitionRequest

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func finish() { request.endAudio() }
}

/// Input loudness for the meter.
private enum AudioLevel {
    /// Root mean square of a buffer, mapped onto a roughly perceptual 0...1.
    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let frames = Int(buffer.frameLength)
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<frames {
            let sample = samples[index]
            sum += sample * sample
        }
        let mean = sum / Float(frames)
        guard mean > 0 else { return 0 }
        // -50 dBFS reads as silence, 0 dBFS as full scale.
        let decibels = 10 * log10f(mean)
        return min(max((decibels + 50) / 50, 0), 1)
    }
}

private extension AVAudioPCMBuffer {
    /// A copy that the tap is free to overwrite.
    func detachedCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let source = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }
        for index in 0..<source.count {
            guard let from = source[index].mData, let to = destination[index].mData else { continue }
            memcpy(to, from, Int(min(source[index].mDataByteSize, destination[index].mDataByteSize)))
        }
        return copy
    }
}
