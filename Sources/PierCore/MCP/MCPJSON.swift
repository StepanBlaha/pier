import Foundation

/// Minimal JSON value used by the MCP server (JSON-RPC envelopes, tool schemas, tool results).
public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var arrayValue: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.rounded() == d && abs(d) < 1e15 ? Int(d) : nil
        default: return nil
        }
    }
    public var doubleValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    public var isNull: Bool { if case .null = self { return true } else { return false } }

    // MARK: Serialization

    private static let compactEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return e
    }()

    /// Single-line JSON (no raw newlines: strings escape them), safe for newline-delimited transport.
    public var compact: String { Self.render(Self.compactEncoder, self) }
    public var pretty: String { Self.render(Self.prettyEncoder, self) }

    private static func render(_ enc: JSONEncoder, _ v: JSON) -> String {
        guard let data = try? enc.encode(v.sanitized()), let s = String(data: data, encoding: .utf8) else { return "null" }
        return s
    }

    /// Non-finite doubles are not representable in JSON.
    func sanitized() -> JSON {
        switch self {
        case .double(let d): return d.isFinite ? self : .null
        case .array(let a): return .array(a.map { $0.sanitized() })
        case .object(let o): return .object(o.mapValues { $0.sanitized() })
        default: return self
        }
    }

    public static func parse(_ text: String) -> JSON? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    /// Bridge any Encodable (e.g. `Service`) into a JSON value. Dates become ISO-8601 strings.
    public static func encoding<T: Encodable>(_ value: T) -> JSON {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value), let json = try? JSONDecoder().decode(JSON.self, from: data) else { return .null }
        return json
    }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSON: ExpressibleByNilLiteral { public init(nilLiteral: ()) { self = .null } }
extension JSON: ExpressibleByBooleanLiteral { public init(booleanLiteral value: Bool) { self = .bool(value) } }
extension JSON: ExpressibleByIntegerLiteral { public init(integerLiteral value: Int) { self = .int(value) } }
extension JSON: ExpressibleByFloatLiteral { public init(floatLiteral value: Double) { self = .double(value) } }
extension JSON: ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(stringInterpolation: DefaultStringInterpolation) { self = .string(String(stringInterpolation: stringInterpolation)) }
}
extension JSON: ExpressibleByArrayLiteral { public init(arrayLiteral elements: JSON...) { self = .array(elements) } }
extension JSON: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}
