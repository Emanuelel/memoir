import Foundation

/// A model running on another machine you own, reached over your own private network.
///
/// The third trust tier, and it genuinely is a third one rather than a rename of the second.
/// A Mac mini on your own Tailscale is not a cloud service: no third party sees the request,
/// nothing is retained by anyone, and there is no account. But it is also not "on this
/// machine": the bytes leave over the network, and pretending otherwise would be exactly the
/// kind of comfortable lie this project exists to avoid.
///
/// So it is **consented, like cloud, and private, unlike cloud**: off by default, listed with
/// the host it will talk to, and never selected by a fallback that the user did not ask for.
///
/// The reason it exists: the on-device model is ~3B parameters and the open question is
/// whether the product's recall failures come from the model being small or from the context
/// being wrong. Nobody can answer that from one model. This makes the comparison possible by
/// sending **the identical prompt and the identical context packet** to a much larger model,
/// so the only variable is the model itself.
///
/// OpenAI-compatible `/v1/chat/completions`, which is what LM Studio, Ollama and vLLM all
/// speak, so this is not tied to one server.
public struct LocalNetworkBrain: Brain {

    /// Where the model lives and what it is called.
    public struct Endpoint: Sendable, Equatable, Codable {
        /// Base URL including `/v1`, e.g. `http://100.66.109.26:1234/v1`.
        public var baseURL: URL
        /// Model id as the server reports it, e.g. `qwen3-30b-a3b-instruct-2507-mlx`.
        public var model: String
        /// Optional, because a machine on your own network usually needs no key.
        public var apiKey: String?

        public init(baseURL: URL, model: String, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    private let endpoint: Endpoint

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
    }

    public var kind: BrainKind { .localNetwork }

    /// One ephemeral session: no disk cache, no cookies, bounded timeouts.
    ///
    /// The timeout is generous because a 30B model on a Mac mini is not fast, and because the
    /// mini may be asleep, in which case failing quickly is right and the chain moves on.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 120
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    /// True when an endpoint is configured.
    ///
    /// Deliberately does not probe the network, for the same reason the Anthropic brain does
    /// not: opening settings must never cost a request. The mini being asleep is discovered
    /// when a question is actually asked, and the chain falls through to the on-device model.
    public func isAvailable() async -> Bool { !endpoint.model.isEmpty }

    public func availabilityDetail() async -> String {
        "\(endpoint.model) on \(endpoint.baseURL.host ?? "your network"). "
        + "Questions go to that machine and nowhere else."
    }

    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let started = Date()
        let text = try await complete(
            prompt: BrainPrompt.user(question: question, context: context),
            maxTokens: 400
        )
        return BrainAnswer(
            text: text,
            brain: .localNetwork,
            citedCaptureIDs: context.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: endpoint.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = endpoint.apiKey, !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": endpoint.model,
            "messages": [
                ["role": "system", "content": BrainPrompt.system],
                ["role": "user", "content": prompt],
            ],
            "max_tokens": maxTokens,
            // Low but not zero: the same reasoning as the on-device brain. This job is to
            // phrase supplied evidence, not to be creative about it.
            "temperature": 0.2,
            "stream": false,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        // Not "cloud", but it is still a packet on a wire, so it is counted exactly like one.
        // The honesty panel would be a lie if the only egress it missed were the one the
        // `isCloud` flag happens to call local.
        OutboundMonitor.shared.record(destination: endpoint.baseURL.host ?? "your network")
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            // The mini asleep, off the network, or unreachable. Not an error worth shouting
            // about: the chain has an on-device model behind this one.
            throw MemoirError.brainUnavailable(
                .localNetwork,
                "could not reach \(endpoint.baseURL.host ?? "the model host"): \(error.localizedDescription)"
            )
        }

        guard let http = response as? HTTPURLResponse else {
            throw MemoirError.brainUnavailable(.localNetwork, "no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw MemoirError.brainUnavailable(.localNetwork, "HTTP \(http.statusCode): \(detail)")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw MemoirError.brainUnavailable(.localNetwork, "unexpected response shape")
        }

        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoirError.brainUnavailable(.localNetwork, "empty completion")
        }
        return trimmed
    }
}
