/// A dynamic JSON value.
///
/// The harness event vocabulary is open — `docs/dsh-api-inventory.md` is explicit
/// that unknown frame types must be tolerated, and plugins add new ones. Modelling
/// every payload as a Swift struct would mean a new app build every time someone
/// installs a plugin, so payloads are kept as values and read by key path. The
/// handful of shapes the UI actually renders get typed accessors on top.

import Foundation

/// One JSON value, preserving everything the wire carried.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            // Whole numbers go out without a decimal point: `"seq":8`, not
            // `"seq":8.0`. The harness accepts both, but the parity vectors
            // compare bytes.
            if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - Reading

public extension JSONValue {
    /// Member of an object, or nil for anything else.
    subscript(key: String) -> JSONValue? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    /// Element of an array, or nil when out of range or not an array.
    subscript(index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    /// Follow a dotted path, e.g. `payload.data.chunk.type`.
    func path(_ keys: String...) -> JSONValue? {
        var value: JSONValue? = self
        for key in keys { value = value?[key] }
        return value
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }
}

// MARK: - Writing

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

public extension JSONValue {
    /// An empty object, the payload most harness methods take.
    static let emptyObject = JSONValue.object([:])

    /// Build an object, dropping members whose value is nil.
    static func object(dropping fields: [String: JSONValue?]) -> JSONValue {
        .object(fields.compactMapValues { $0 })
    }
}

// MARK: - Bridging

public extension JSONValue {
    /// Decode from raw JSON bytes.
    init(data: Data) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Encode to raw JSON bytes with the harness's key ordering rules: none.
    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}
