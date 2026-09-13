import Foundation

/// One JSON value, as it crosses the snapnedit native bridge.
///
/// The protocol's payloads are ordinary JSON, but two of them — `Document`
/// (the editor's document model) and a `run`'s `params` — are open-ended
/// enough that mirroring them as Swift structs would guarantee the wrapper
/// falls behind the editor. They are therefore surfaced as `JSONValue`, a
/// small, `Sendable`, `Codable` sum type you can read with subscripts or hand
/// straight back to ``SnapneditEditorHandle/setDocument(_:)``.
///
/// ```swift
/// let doc = try await handle.getDocument()
/// let width = doc["width"]?.intValue
/// ```
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Accessors

extension JSONValue {
    public var isNull: Bool { if case .null = self { return true }; return false }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    /// The value as an `Int`, when it is a whole number.
    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d >= Double(Int.min), d <= Double(Int.max) else { return nil }
        return Int(d)
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        switch self {
        case .array(let a): return a
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        switch self {
        case .object(let o): return o
        default: return nil
        }
    }

    /// Member of an object, or `nil` for any other kind of value.
    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Element of an array, or `nil` for any other kind of value / an out-of-range index.
    public subscript(index: Int) -> JSONValue? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let a = try? container.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? container.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }
}

// MARK: - Bridging to and from `Any`

extension JSONValue {
    /// Wraps an untyped Foundation value (`String`, `NSNumber`, `[Any]`,
    /// `[String: Any]`, `NSNull`, `nil`, or anything already a ``JSONValue``).
    ///
    /// Returns `nil` for a value JSON cannot represent, so an unencodable
    /// `params` dictionary is caught at the call site rather than silently
    /// dropped on the wire.
    public init?(any value: Any?) {
        guard let value else { self = .null; return }
        if let v = value as? JSONValue { self = v; return }
        if value is NSNull { self = .null; return }
        if let v = value as? String { self = .string(v); return }
        // NSNumber FIRST, and CFBoolean-checked: a Swift `Bool` in an `Any`
        // bridges to `__NSCFBoolean`, and an `NSNumber(1)` casts happily to
        // `Bool` — only the CoreFoundation type id tells the two apart, and
        // getting it wrong turns every `1` into `true` on the wire.
        if let v = value as? NSNumber {
            self = CFGetTypeID(v) == CFBooleanGetTypeID() ? .bool(v.boolValue) : .number(v.doubleValue)
            return
        }
        if let v = value as? Bool { self = .bool(v); return }
        if let v = value as? Int { self = .number(Double(v)); return }
        if let v = value as? Double { self = .number(v); return }
        if let v = value as? Float { self = .number(Double(v)); return }
        if let v = value as? [Any?] {
            var out: [JSONValue] = []
            out.reserveCapacity(v.count)
            for item in v {
                guard let encoded = JSONValue(any: item) else { return nil }
                out.append(encoded)
            }
            self = .array(out)
            return
        }
        if let v = value as? [String: Any?] {
            var out: [String: JSONValue] = [:]
            out.reserveCapacity(v.count)
            for (k, item) in v {
                guard let encoded = JSONValue(any: item) else { return nil }
                out[k] = encoded
            }
            self = .object(out)
            return
        }
        return nil
    }

    /// The value as plain Foundation objects, for handing to code that wants
    /// `[String: Any]`. `null` becomes `NSNull()`.
    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.anyValue)
        case .object(let o): return o.mapValues(\.anyValue)
        }
    }

    /// Encodes any `Encodable` into a ``JSONValue`` — how the typed option
    /// structs (theme, features, export options) reach the wire.
    public init<T: Encodable>(encoding value: T) throws {
        let data = try JSONEncoder().encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value into a `Decodable` type.
    public func decode<T: Decodable>(_ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

extension JSONValue: CustomStringConvertible {
    public var description: String {
        guard let data = try? JSONEncoder().encode(self), let s = String(data: data, encoding: .utf8) else { return "<json>" }
        return s
    }
}
