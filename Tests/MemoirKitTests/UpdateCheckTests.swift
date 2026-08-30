import Testing
import Foundation
@testable import MemoirKit

/// The update check, without touching the network.
///
/// CF-2 says nothing leaves the machine when local-only, and it is asserted structurally by a
/// counting `URLProtocol`. The same discipline applies here: a test that reached
/// raw.githubusercontent.com would be a test that fails on a train and passes in an office.
@Suite(.serialized)
struct UpdateCheckTests {

    // MARK: - Version comparison

    @Test("a newer version is offered, an older or equal one is not")
    func comparesVersions() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("1.0.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test("the tenth release still offers itself")
    func doubleDigitsSortNumerically() {
        // String comparison puts "0.10.0" before "0.9.0", so this is the release where a
        // lexicographic check silently stops updating anybody. It has bitten real shipping
        // software more than once.
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("1.2.10", than: "1.2.9"))
        #expect(!UpdateCheck.isNewer("0.9.0", than: "0.10.0"))
    }

    @Test("decoration around the number cannot make a real version read as zero")
    func toleratesPrefixesAndSuffixes() {
        #expect(UpdateCheck.parts("v0.2.0") == [0, 2, 0])
        #expect(UpdateCheck.parts("0.2.0-beta.1") == [0, 2, 0, 1])
        #expect(UpdateCheck.isNewer("v0.2.0", than: "0.1.0"))
    }

    // MARK: - Fetching

    /// Answers every request from memory, and records what was asked for.
    final class FakeProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var body: Data?
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var requested: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.requested.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let body = Self.body { client?.urlProtocol(self, didLoad: body) }
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession {
        FakeProtocol.requested = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeProtocol.self]
        return URLSession(configuration: config)
    }

    private static let manifest = """
    {"version":"0.9.0","url":"https://example.com/Memoir-0.9.0.dmg","notes":"Encrypted at rest."}
    """

    @Test("a newer release comes back with somewhere to get it")
    func returnsANewerRelease() async {
        FakeProtocol.body = Data(Self.manifest.utf8)
        FakeProtocol.status = 200

        let release = await UpdateCheck.latest(current: "0.1.0", session: session())
        #expect(release?.version == "0.9.0")
        #expect(release?.notes == "Encrypted at rest.")
    }

    @Test("the version already running is not offered back")
    func staysQuietWhenCurrent() async {
        FakeProtocol.body = Data(Self.manifest.utf8)
        let release = await UpdateCheck.latest(current: "0.9.0", session: session())
        #expect(release == nil)
    }

    @Test("every ordinary failure is silence, not an interruption")
    func failsQuietly() async {
        FakeProtocol.body = Data("not json".utf8)
        FakeProtocol.status = 200
        #expect(await UpdateCheck.latest(current: "0.1.0", session: session()) == nil)

        FakeProtocol.body = Data(Self.manifest.utf8)
        FakeProtocol.status = 404
        #expect(await UpdateCheck.latest(current: "0.1.0", session: session()) == nil)
    }

    // MARK: - What the request carries

    @Test("CF-2c the request says nothing about who is asking")
    func requestCarriesNothingIdentifying() async {
        FakeProtocol.body = Data(Self.manifest.utf8)
        FakeProtocol.status = 200
        _ = await UpdateCheck.latest(current: "0.1.0", session: session())

        let sent = try! #require(FakeProtocol.requested.first)

        // The claim in PRIVACY.md is that this asks a question rather than reporting on you.
        // If a version, an id or an account ever gets appended to make the server's life
        // easier, that claim becomes false and this test is what stops it.
        #expect(sent.url?.query == nil, "a query string would carry something about the caller")
        #expect(sent.httpBody == nil)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(sent.httpMethod == "GET")
    }

    @Test("CF-2c the check is counted like every other thing that leaves")
    func isCountedAsOutbound() async {
        OutboundMonitor.shared.resetForTesting()
        let before = OutboundMonitor.shared.snapshot.count

        FakeProtocol.body = Data(Self.manifest.utf8)
        FakeProtocol.status = 200
        _ = await UpdateCheck.latest(current: "0.1.0", session: session())

        #expect(OutboundMonitor.shared.snapshot.count == before + 1,
                "a request missing from the count makes the count a lie")
        OutboundMonitor.shared.resetForTesting()
    }
}

// MARK: - Resting the on-device model after a refusal

@Suite(.serialized)
struct OnDeviceRefusalTests {

    /// The whole diagnosis, in one error shape. `modelmanagerd` finds every asset, resolves
    /// the session, then refuses under `CriticalMemoryPressure` and reports 1013 with no
    /// message attached. Nothing but the domain chain identifies it.
    @Test("a refusal from the model service is recognised in a nested error chain")
    func recognisesTheRefusal() {
        AppleOnDeviceBrain.clearRefusal()
        let root = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        let mid = NSError(domain: "com.apple.SensitiveContentAnalysisML", code: 15,
                          userInfo: [NSUnderlyingErrorKey: root])
        let outer = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError",
                            code: -1, userInfo: [NSMultipleUnderlyingErrorsKey: [mid]])

        let now = Date(timeIntervalSince1970: 1_000_000)
        AppleOnDeviceBrain.noteFailure(outer, now: now)
        #expect(AppleOnDeviceBrain.isResting(now: now.addingTimeInterval(60)))
        AppleOnDeviceBrain.clearRefusal()
    }

    /// Relaxed guardrails drop the sensitive-content frame and keep 1013, which is how the
    /// classifier was ruled out as the cause. Both shapes have to be recognised.
    @Test("the same refusal is recognised without the sensitive-content frame")
    func recognisesItUnderPermissiveGuardrails() {
        AppleOnDeviceBrain.clearRefusal()
        let root = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        let outer = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError",
                            code: -1, userInfo: [NSUnderlyingErrorKey: root])

        let now = Date(timeIntervalSince1970: 2_000_000)
        AppleOnDeviceBrain.noteFailure(outer, now: now)
        #expect(AppleOnDeviceBrain.isResting(now: now))
        AppleOnDeviceBrain.clearRefusal()
    }

    /// The failure is memory pressure, so it passes. Resting has to end on its own, or one
    /// busy afternoon would cost the brain until the app was relaunched.
    @Test("the rest ends by itself")
    func restingExpires() {
        AppleOnDeviceBrain.clearRefusal()
        let root = NSError(domain: "ModelManagerServices.ModelManagerError", code: 1013)
        let now = Date(timeIntervalSince1970: 3_000_000)
        AppleOnDeviceBrain.noteFailure(root, now: now)

        #expect(AppleOnDeviceBrain.isResting(now: now.addingTimeInterval(AppleOnDeviceBrain.backoff - 1)))
        #expect(!AppleOnDeviceBrain.isResting(now: now.addingTimeInterval(AppleOnDeviceBrain.backoff + 1)))
        AppleOnDeviceBrain.clearRefusal()
    }

    /// A timeout means the model was reached and was slow. That is a different thing, and must
    /// not rest a brain that would answer the next question.
    @Test("an ordinary failure does not rest the brain")
    func ordinaryFailureIsNotARefusal() {
        AppleOnDeviceBrain.clearRefusal()
        let timeout = NSError(domain: "FoundationModels.LanguageModelSession.GenerationError",
                              code: -1, userInfo: [:])
        let now = Date(timeIntervalSince1970: 4_000_000)
        AppleOnDeviceBrain.noteFailure(timeout, now: now)
        #expect(!AppleOnDeviceBrain.isResting(now: now))
    }
}
