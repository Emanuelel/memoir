import Foundation

/// A minimal, `Sendable` JSON tree.
///
/// JSON-RPC payloads are dynamically shaped, so the server models them as a value
/// tree rather than as fixed `Codable` structs. This type deliberately avoids
/// `JSONEncoder`/`JSONDecoder` for output so that every emitted frame is compact,
/// deterministic (keys sorted) and guaranteed to contain no raw newline, which is
/// what the newline-delimited framing requires.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Convenience accessors

extension JSONValue {
    /// The string payload, when this value is a string.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// The integer payload, accepting a whole `double` as well.
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite && d == d.rounded(): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// The boolean payload, when this value is a boolean.
    public var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    /// The object payload, when this value is an object.
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// The array payload, when this value is an array.
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// True when this value is `null`.
    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// Member lookup on objects; `nil` for every other case.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }
}

// MARK: - Parsing

extension JSONValue {
    /// Parses UTF-8 JSON text into a value tree.
    /// - Throws: Whatever `JSONSerialization` reports for malformed input.
    public static func parse(_ data: Data) throws -> JSONValue {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return convert(any)
    }

    /// Parses a UTF-8 JSON string into a value tree.
    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    private static func convert(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull:
            return .null
        case let n as NSNumber:
            if CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            switch CFNumberGetType(n as CFNumber) {
            case .float32Type, .float64Type, .floatType, .doubleType, .cgFloatType:
                return .double(n.doubleValue)
            default:
                return .int(n.intValue)
            }
        case let s as String:
            return .string(s)
        case let a as [Any]:
            return .array(a.map(convert))
        case let o as [String: Any]:
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(o.count)
            for (k, v) in o { out[k] = convert(v) }
            return .object(out)
        default:
            return .null
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Serializes to compact, single-line JSON with sorted object keys.
    ///
    /// The output never contains an unescaped newline, so it can be written
    /// directly as one newline-delimited JSON-RPC frame.
    public func serialized() -> String {
        var out = ""
        out.reserveCapacity(256)
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let b):
            out += b ? "true" : "false"
        case .int(let i):
            out += String(i)
        case .double(let d):
            if !d.isFinite {
                out += "null"
            } else if d == d.rounded(), abs(d) < 1e15 {
                out += String(Int64(d))
            } else {
                out += String(d)
            }
        case .string(let s):
            JSONValue.writeEscaped(s, into: &out)
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            var first = true
            for key in members.keys.sorted() {
                if !first { out += "," }
                first = false
                JSONValue.writeEscaped(key, into: &out)
                out += ":"
                members[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeEscaped(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04x", scalar.value)
                } else if scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

// MARK: - Ergonomic construction

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var o: [String: JSONValue] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
}
