import Testing
import Foundation
import Speech
@testable import MemoirKit

// Everything here runs without a microphone, without audio and without a TCC prompt.
// The audio path itself is not unit-testable and is deliberately not faked: what is tested is
// the logic that decides *whether* the microphone opens, what the user is told when it cannot,
// and how dictated words are folded into text the user typed.

// MARK: - State machine

@Suite("VoiceMachine")
struct VoiceMachineTests {

    @Test("a fresh machine is idle and not running")
    func startsIdle() {
        let machine = VoiceMachine()
        #expect(machine.state == .idle)
        #expect(machine.isRunning == false)
        #expect(machine.state.isListening == false)
    }

    @Test("start moves through permission to listening")
    func happyPath() {
        var machine = VoiceMachine()
        #expect(machine.requestStart() == true)
        #expect(machine.state == .requestingPermission)
        #expect(machine.isRunning)

        machine.opened()
        #expect(machine.state == .listening(level: 0))
        #expect(machine.state.isListening)

        machine.setLevel(0.4)
        #expect(machine.state == .listening(level: 0.4))
        #expect(machine.state.level == 0.4)
    }

    @Test("start is idempotent: a second start does nothing at all")
    func startIsIdempotent() {
        var machine = VoiceMachine()
        #expect(machine.requestStart() == true)
        let session = machine.session

        // The caller must be told "no", otherwise it spins up a second AVAudioEngine.
        #expect(machine.requestStart() == false)
        #expect(machine.requestStart() == false)
        #expect(machine.session == session, "a refused start must not open a new session")
        #expect(machine.isRunning)
    }

    @Test("stop is idempotent: only the first stop tears anything down")
    func stopIsIdempotent() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        machine.opened()

        #expect(machine.requestStop() == true)
        #expect(machine.state == .idle)
        #expect(machine.isRunning == false)

        #expect(machine.requestStop() == false)
        #expect(machine.requestStop() == false)
        #expect(machine.state == .idle)
    }

    @Test("stopping a machine that never started is harmless")
    func stopWithoutStart() {
        var machine = VoiceMachine()
        #expect(machine.requestStop() == false)
        #expect(machine.state == .idle)
    }

    @Test("each accepted start gets a new session token")
    func sessionTokenAdvances() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        let first = machine.session
        _ = machine.requestStop()
        _ = machine.requestStart()
        #expect(machine.session > first, "a new session must not accept the old one's results")
    }

    @Test("download progress is reported and clamped to 0...1")
    func downloadProgress() {
        var machine = VoiceMachine()
        _ = machine.requestStart()

        machine.downloading(0.5)
        #expect(machine.state == .downloadingModel(0.5))
        #expect(machine.state.isPreparing)

        machine.downloading(4)
        #expect(machine.state == .downloadingModel(1))
        machine.downloading(-1)
        #expect(machine.state == .downloadingModel(0))
    }

    @Test("a stopped session ignores late progress and level updates")
    func ignoresLateUpdates() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        machine.opened()
        _ = machine.requestStop()

        machine.downloading(0.9)
        machine.setLevel(0.8)
        machine.opened()
        #expect(machine.state == .idle, "a finished session must not reanimate the mic indicator")
    }

    @Test("a failure ends the session and survives stop, so the user can read it")
    func failureIsSticky() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        machine.fail("Memoir is not allowed to use the microphone.")

        #expect(machine.isRunning == false)
        #expect(machine.state == .unavailable("Memoir is not allowed to use the microphone."))

        // stop() runs on dismiss and must not wipe the explanation.
        #expect(machine.requestStop() == false)
        #expect(machine.state.unavailableReason != nil)

        machine.clearFailure()
        #expect(machine.state == .idle)
    }

    @Test("the level meter is clamped")
    func levelClamped() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        machine.opened()
        machine.setLevel(7)
        #expect(machine.state.level == 1)
        machine.setLevel(-3)
        #expect(machine.state.level == 0)
    }

    @Test("level updates are ignored unless the mic is actually open")
    func levelNeedsOpenMic() {
        var machine = VoiceMachine()
        _ = machine.requestStart()
        machine.setLevel(0.9)
        #expect(machine.state == .requestingPermission, "a meter must never imply a hot mic")
    }
}

// MARK: - Permissions

@Suite("Voice permissions")
struct VoicePermissionTests {

    @Test("both granted is the only case that lets the mic open")
    func bothGranted() {
        #expect(VoicePermissions.blockingState(speech: .granted, microphone: .granted) == nil)
    }

    @Test("denied speech authorization produces .unavailable naming the right pane")
    func speechDenied() {
        let state = VoicePermissions.blockingState(speech: .denied, microphone: .granted)
        let reason = try? #require(state?.unavailableReason)
        #expect(state?.isListening == false)
        #expect(reason?.contains("Speech Recognition") == true)
        #expect(reason?.contains("System Settings > Privacy & Security > Speech Recognition") == true)
    }

    @Test("denied microphone access produces .unavailable naming the right pane")
    func microphoneDenied() {
        let state = VoicePermissions.blockingState(speech: .granted, microphone: .denied)
        let reason = try? #require(state?.unavailableReason)
        #expect(reason?.contains("System Settings > Privacy & Security > Microphone") == true)
    }

    @Test("no non-granted combination is ever allowed through")
    func nothingSlipsThrough() {
        for speech in VoicePermissions.Grant.allCases {
            for microphone in VoicePermissions.Grant.allCases {
                let blocked = VoicePermissions.blockingState(speech: speech, microphone: microphone)
                if speech == .granted && microphone == .granted {
                    #expect(blocked == nil)
                } else {
                    #expect(blocked?.unavailableReason?.isEmpty == false,
                            "\(speech)/\(microphone) must be refused with an explanation")
                }
            }
        }
    }

    @Test("every authorization status maps to a grant, denied by default")
    func statusMapping() {
        #expect(OnDeviceSpeech.grant(for: .authorized) == .granted)
        #expect(OnDeviceSpeech.grant(for: .denied) == .denied)
        #expect(OnDeviceSpeech.grant(for: .restricted) == .restricted)
        #expect(OnDeviceSpeech.grant(for: .notDetermined) == .notDetermined)
    }
}

// MARK: - On-device only

@Suite("On-device speech")
struct OnDeviceSpeechTests {

    @Test("every request Memoir builds is on-device only")
    func requestIsOnDeviceOnly() {
        let request = OnDeviceSpeech.makeRequest()
        #expect(request.requiresOnDeviceRecognition, "audio must never be allowed to reach Apple")
        #expect(OnDeviceSpeech.isOnDeviceOnly(request))
    }

    @Test("partial results are on, so words stream into the field as they are said")
    func requestStreams() {
        #expect(OnDeviceSpeech.makeRequest().shouldReportPartialResults)
    }

    @Test("a request that is not on-device only is rejected by the guard")
    func offDeviceIsRejected() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = false
        #expect(OnDeviceSpeech.isOnDeviceOnly(request) == false)
    }

    @Test("the off-device refusal explains itself rather than silently uploading")
    func offDeviceReasonIsActionable() {
        let reason = OnDeviceSpeech.offDeviceReason(locale: Locale(identifier: "en-US"))
        #expect(reason.contains("will not use it"))
        #expect(reason.contains("Settings"))
    }
}

// MARK: - Dictation buffer

@Suite("DictationBuffer")
struct DictationBufferTests {

    @Test("an empty buffer renders nothing")
    func empty() {
        let buffer = DictationBuffer()
        #expect(buffer.text.isEmpty)
        #expect(buffer.isEmpty)
    }

    @Test("dictation appends to what was already typed, never replacing it")
    func appendsToTypedText() {
        var buffer = DictationBuffer(prefix: "remind me to")
        buffer.setVolatile("call")
        #expect(buffer.text == "remind me to call")
        buffer.setVolatile("call Ana")
        #expect(buffer.text == "remind me to call Ana",
                "a volatile result replaces the tail, not the typed prefix")
        buffer.commit("call Ana tomorrow")
        #expect(buffer.text == "remind me to call Ana tomorrow")
    }

    @Test("volatile results replace each other, final results accumulate")
    func volatileVersusFinal() {
        var buffer = DictationBuffer()
        buffer.setVolatile("hello")
        buffer.setVolatile("hello there")
        #expect(buffer.text == "hello there")

        buffer.commit("hello there")
        buffer.setVolatile("how")
        #expect(buffer.text == "hello there how")

        buffer.commit("how are you")
        #expect(buffer.text == "hello there how are you")
        #expect(buffer.isEmpty == false)
    }

    @Test("committing clears the volatile tail so nothing is said twice")
    func commitClearsVolatile() {
        var buffer = DictationBuffer()
        buffer.setVolatile("one two")
        buffer.commit("one two")
        #expect(buffer.text == "one two")
        #expect(buffer.volatileTail.isEmpty)
    }

    @Test("typing mid-dictation survives: rebasing keeps the keystrokes")
    func rebaseKeepsTyping() {
        var buffer = DictationBuffer(prefix: "")
        buffer.commit("send the report")
        buffer.setVolatile("to")
        #expect(buffer.text == "send the report to")

        // The user typed into the field. Everything on screen becomes untouchable.
        buffer.rebase(to: "send the report to Ana")
        #expect(buffer.text == "send the report to Ana")

        buffer.setVolatile("by Friday")
        #expect(buffer.text == "send the report to Ana by Friday",
                "new speech continues after the user's edit rather than overwriting it")
    }

    @Test("blank and whitespace-only results never introduce stray spaces")
    func whitespaceIsTidied() {
        var buffer = DictationBuffer(prefix: "  hello  ")
        buffer.commit("   ")
        #expect(buffer.text == "hello")
        buffer.setVolatile("  world  ")
        #expect(buffer.text == "hello world")
    }
}

// MARK: - Config

@Suite("VoiceConfig")
struct VoiceConfigTests {

    @Test("a config file written before voice existed still decodes")
    func toleratesMissingKeys() throws {
        let json = Data("{}".utf8)
        let decoded = try JSONDecoder().decode(VoiceConfig.self, from: json)
        #expect(decoded == VoiceConfig())
    }

    @Test("a section carrying the retired auto-listen key still decodes")
    func toleratesRetiredKeys() throws {
        // `startListeningOnOpen` is gone (the mic button is the only thing that opens the
        // mic), but it is sitting in every config.json written before that change.
        let json = Data(#"{"startListeningOnOpen": false}"#.utf8)
        let decoded = try JSONDecoder().decode(VoiceConfig.self, from: json)
        #expect(decoded.localeIdentifier == VoiceConfig.systemLocaleIdentifier)
    }

    @Test("the locale identifier round-trips into a usable Locale")
    func localeRoundTrip() throws {
        let config = VoiceConfig(localeIdentifier: "en-GB")
        #expect(config.locale.identifier(.bcp47) == "en-GB")

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VoiceConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("the default locale is a real, resolvable language")
    func defaultLocaleIsReal() {
        let identifier = VoiceConfig.systemLocaleIdentifier
        #expect(!identifier.isEmpty)
        #expect(Locale(identifier: identifier).language.languageCode != nil)
    }
}
