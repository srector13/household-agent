import Foundation

/// Any JSON value. Settings values and a few loosely shaped payloads use it.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            if n.rounded() == n && abs(n) < 1e15 { try c.encode(Int(n)) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var double: Double? { if case .number(let n) = self { return n }; return nil }
    public var int: Int? { double.map { Int($0) } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { object?[key] }

    /// A short human-readable form for showing values in lists.
    public var display: String {
        switch self {
        case .null: return "—"
        case .bool(let b): return b ? "On" : "Off"
        case .number(let n): return n.rounded() == n ? String(Int(n)) : String(n)
        case .string(let s): return s.isEmpty ? "—" : s
        case .array(let a): return a.map(\.display).joined(separator: ", ")
        case .object(let o): return "\(o.count) fields"
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, b in b }))
    }
    public init(nilLiteral: ()) { self = .null }
}

public extension JSONValue {
    static func from(_ s: String?) -> JSONValue { s.map { .string($0) } ?? .null }
    static func from(_ i: Int?) -> JSONValue { i.map { .number(Double($0)) } ?? .null }

    /// Builds a nested object from a dotted path: "daily.weekly_day" = "fri" → {"daily": {"weekly_day": "fri"}}.
    static func nested(_ path: String, _ value: JSONValue) -> JSONValue {
        path.split(separator: ".").reversed().reduce(value) { acc, key in .object([String(key): acc]) }
    }

    /// Deep-merges two objects (used to send several settings changes in one PATCH).
    func merged(with other: JSONValue) -> JSONValue {
        guard case .object(var a) = self, case .object(let b) = other else { return other }
        for (k, v) in b { a[k] = a[k].map { $0.merged(with: v) } ?? v }
        return .object(a)
    }
}
