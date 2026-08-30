import Foundation

/// The user's own Anthropic API key, talking to `https://api.anthropic.com/v1/messages`.
///
/// **This is the only code in the entire project that touches the network.** There is no
/// analytics, no telemetry, no crash reporting, no update check. If this file is not executing,
/// Memoir is not making requests.
///
/// It is only ever reached when the user has explicitly set `BrainConfig.allowCloud = true` and
/// stored a key. `BrainRouter` will never fall back *to* this brain.
public struct AnthropicBrain: Brain {
    /// Model used when the caller does not specify one.
    public static let defaultModel = "claude-sonnet-5"

    /// The single endpoint this project is allowed to contact.
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    /// API version header value required by the messages API.
    public static let apiVersion = "2023-06-01"

    /// The user's API key. Held in memory only, never logged, never persisted by this type.
    private let apiKey: String

    /// Model identifier sent with every request.
    private let model: String

    /// Creates the brain.
    /// - Parameters:
    ///   - apiKey: the user's key, normally loaded from the Keychain via ``BrainKeychain``.
    ///   - model: model identifier; defaults to ``defaultModel``.
    public init(apiKey: String, model: String = AnthropicBrain.defaultModel) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = m.isEmpty ? Self.defaultModel : m
    }

    /// Always `.anthropicAPI`.
    public var kind: BrainKind { .anthropicAPI }

    // MARK: - Session

    /// Ephemeral session: no disk cache, no cookies, no credential storage, bounded timeouts.
    /// One per process, so connections are reused and nothing is ever written to disk.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 90
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.allowsCellularAccess = true
        return URLSession(configuration: config)
    }()

    // MARK: - Brain

    /// True when a non-empty key is configured.
    ///
    /// Deliberately does **not** make a network call: probing availability must never cost a
    /// request, and must never send anything off the machine as a side effect of opening settings.
    public func isAvailable() async -> Bool { !apiKey.isEmpty }

    /// Explains the current state for the settings UI.
    public func availabilityDetail() async -> String {
        apiKey.isEmpty
            ? "No Anthropic API key saved. Add one in Settings to use this brain."
            : "Anthropic API key is saved. Questions you ask this brain are sent to Anthropic."
    }

    /// Answers a question against the context packet.
    /// - Throws: `MemoirError.brainUnavailable(.anthropicAPI, _)` for missing keys, HTTP errors,
    ///   rate limits, transport failures and malformed response bodies.
    public func answer(question: String, context: ContextPacket) async throws -> BrainAnswer {
        let started = Date()
        let text = try await send(
            system: BrainPrompt.system,
            user: BrainPrompt.user(question: question, context: context),
            maxTokens: 1024
        )
        return BrainAnswer(
            text: BrainPrompt.clean(text),
            brain: .anthropicAPI,
            citedCaptureIDs: context.captureIDs,
            latency: Date().timeIntervalSince(started)
        )
    }

    /// Raw completion used by the extraction pipeline.
    /// - Throws: `MemoirError.brainUnavailable(.anthropicAPI, _)`.
    public func complete(prompt: String, maxTokens: Int) async throws -> String {
        let text = try await send(system: nil, user: prompt, maxTokens: maxTokens)
        return BrainPrompt.clean(text, fallback: "")
    }

    // MARK: - Transport

    /// Performs the POST and extracts the text blocks from the response.
    private func send(system: String?, user: String, maxTokens: Int) async throws -> String {
        guard !apiKey.isEmpty else {
            throw MemoirError.brainUnavailable(.anthropicAPI, "No API key configured.")
        }

        let payload = RequestBody(
            model: model,
            maxTokens: min(max(64, maxTokens), 8192),
            system: system,
            messages: [.init(role: "user", content: user)]
        )

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 60

        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw MemoirError.brainUnavailable(.anthropicAPI, "Could not encode the request.")
        }

        let data: Data
        let response: URLResponse
        // Counted here, on the line before the send, because a request that is made and then
        // fails still left the machine. See ``OutboundMonitor``.
        OutboundMonitor.shared.record(destination: Self.endpoint.host ?? "api.anthropic.com")
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let urlError as URLError {
            let detail = Self.describe(urlError)
            Log.shared.warn("Anthropic request failed: \(detail)")
            throw MemoirError.brainUnavailable(.anthropicAPI, detail)
        } catch {
            Log.shared.warn("Anthropic request failed: \(error.localizedDescription)")
            throw MemoirError.brainUnavailable(.anthropicAPI, "Network request failed.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw MemoirError.brainUnavailable(.anthropicAPI, "Unexpected response from the API.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let detail = Self.describeHTTP(status: http.statusCode, body: data, headers: http)
            Log.shared.warn("Anthropic API returned \(http.statusCode): \(BrainKeychain.redact(detail))")
            throw MemoirError.brainUnavailable(.anthropicAPI, detail)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            Log.shared.warn("Anthropic response could not be parsed.")
            throw MemoirError.brainUnavailable(.anthropicAPI, "The API returned a response Memoir could not read.")
        }

        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw MemoirError.brainUnavailable(.anthropicAPI, "The API returned an empty answer.")
        }
        return text
    }

    // MARK: - Error shaping

    /// Maps an HTTP failure onto a sentence worth showing a person.
    private static func describeHTTP(status: Int, body: Data, headers: HTTPURLResponse) -> String {
        let apiMessage = (try? JSONDecoder().decode(ErrorBody.self, from: body))?.error.message
        switch status {
        case 401:
            return "The API key was rejected. Check it in Settings."
        case 403:
            return "This API key is not allowed to use that model."
        case 404:
            return "The model was not found. Check the model name in Settings."
        case 413:
            return "The question plus its context was too large for the API."
        case 429:
            let retry = headers.value(forHTTPHeaderField: "retry-after").map { " Try again in \($0)s." } ?? " Try again shortly."
            return "Rate limited by the API." + retry
        case 500...599:
            return "The API is having trouble right now (HTTP \(status))."
        default:
            if let apiMessage, !apiMessage.isEmpty {
                return "API error \(status): \(apiMessage)"
            }
            return "API error \(status)."
        }
    }

    /// Maps a transport failure onto a sentence worth showing a person.
    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return "No internet connection."
        case .timedOut:
            return "The API did not respond in time."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return "Could not reach api.anthropic.com."
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "The secure connection to the API failed."
        case .cancelled:
            return "The request was cancelled."
        default:
            return "Network request failed (\(error.code.rawValue))."
        }
    }

    // MARK: - Wire types

    /// Request payload for `POST /v1/messages`.
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let maxTokens: Int
        let system: String?
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    /// Successful response payload. Only the text blocks are used.
    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    /// Error response payload.
    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            let type: String?
            let message: String?
        }
        let error: Detail
    }
}
