import Foundation

/// Standard JSON-RPC 2.0 error codes, plus the ones MCP servers commonly reuse.
public enum RPCErrorCode: Int, Sendable {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

/// A JSON-RPC 2.0 error, thrown by handlers and rendered into an error frame.
public struct RPCError: Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public init(_ code: RPCErrorCode, _ message: String, data: JSONValue? = nil) {
        self.init(code: code.rawValue, message: message, data: data)
    }

    /// The `error` member of a JSON-RPC response.
    public var payload: JSONValue {
        var o: [String: JSONValue] = ["code": .int(code), "message": .string(message)]
        if let data { o["data"] = data }
        return .object(o)
    }
}

/// One decoded JSON-RPC 2.0 request or notification.
public struct RPCRequest: Sendable {
    /// Request id. `nil` means this is a notification and must not be answered.
    public let id: JSONValue?
    /// The method name, e.g. `tools/call`.
    public let method: String
    /// The `params` member, normalised to an object (or `.null` when absent).
    public let params: JSONValue

    /// True when the message is a notification (no `id` member at all).
    public var isNotification: Bool { id == nil }
}

/// Decoding and framing helpers for newline-delimited JSON-RPC 2.0.
public enum JSONRPC {
    /// The JSON-RPC version string this server speaks.
    public static let version = "2.0"

    /// Decodes one line into a request.
    ///
    /// - Returns: The decoded request.
    /// - Throws: `RPCError` with `parseError` for malformed JSON and
    ///   `invalidRequest` when required members are missing or ill-typed.
    public static func decode(line: String) throws -> RPCRequest {
        let value: JSONValue
        do {
            value = try JSONValue.parse(line)
        } catch {
            throw RPCError(.parseError, "Invalid JSON: \(error.localizedDescription)")
        }
        return try request(from: value)
    }

    /// Converts an already-parsed value into a request, validating the envelope.
    public static func request(from value: JSONValue) throws -> RPCRequest {
        guard let object = value.objectValue else {
            throw RPCError(.invalidRequest, "A JSON-RPC message must be a JSON object")
        }
        // `jsonrpc` must be "2.0" when present. Be forgiving if a client omits it.
        if let v = object["jsonrpc"]?.stringValue, v != version {
            throw RPCError(.invalidRequest, "Unsupported JSON-RPC version '\(v)', expected \(version)")
        }
        guard let method = object["method"]?.stringValue, !method.isEmpty else {
            throw RPCError(.invalidRequest, "Missing 'method'")
        }
        // A present-but-null id is treated as a notification, per common practice.
        var id = object["id"]
        if let concrete = id, concrete.isNull { id = nil }
        let params = object["params"] ?? .null
        return RPCRequest(id: id, method: method, params: params)
    }

    /// Builds a success response frame.
    public static func success(id: JSONValue?, result: JSONValue) -> String {
        JSONValue.object([
            "jsonrpc": .string(version),
            "id": id ?? .null,
            "result": result,
        ]).serialized()
    }

    /// Builds an error response frame.
    public static func failure(id: JSONValue?, error: RPCError) -> String {
        JSONValue.object([
            "jsonrpc": .string(version),
            "id": id ?? .null,
            "error": error.payload,
        ]).serialized()
    }
}
