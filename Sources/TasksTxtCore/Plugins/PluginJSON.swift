import Foundation

public enum PluginJSONError: Error, Equatable {
    case duplicateKey(String)
    case malformed
}

/// Small structural scanner used before Foundation decoding, which otherwise
/// normalizes duplicate object keys and silently keeps only one value.
public enum PluginJSON {
    public static func rejectDuplicateKeys(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw PluginJSONError.malformed }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        mutating func value() throws {
            skipWhitespace()
            guard let byte = current else { throw PluginJSONError.malformed }
            switch byte {
            case 123: try object()
            case 91: try array()
            case 34: _ = try string()
            case 45, 48...57: number()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default: throw PluginJSONError.malformed
            }
        }

        mutating func object() throws {
            index += 1; skipWhitespace()
            var keys = Set<String>()
            if current == 125 { index += 1; return }
            while true {
                guard current == 34 else { throw PluginJSONError.malformed }
                let key = try string()
                guard keys.insert(key).inserted else { throw PluginJSONError.duplicateKey(key) }
                skipWhitespace(); guard current == 58 else { throw PluginJSONError.malformed }
                index += 1; try value(); skipWhitespace()
                if current == 125 { index += 1; return }
                guard current == 44 else { throw PluginJSONError.malformed }
                index += 1; skipWhitespace()
            }
        }

        mutating func array() throws {
            index += 1; skipWhitespace()
            if current == 93 { index += 1; return }
            while true {
                try value(); skipWhitespace()
                if current == 93 { index += 1; return }
                guard current == 44 else { throw PluginJSONError.malformed }
                index += 1; skipWhitespace()
            }
        }

        mutating func string() throws -> String {
            guard current == 34 else { throw PluginJSONError.malformed }
            let start = index; index += 1
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 && !escaped {
                    let raw = Data(bytes[start..<index])
                    guard String(data: raw, encoding: .utf8) != nil,
                          let decoded = try? JSONDecoder().decode(String.self, from: raw) else {
                        throw PluginJSONError.malformed
                    }
                    return decoded
                }
                if byte < 0x20 && !escaped { throw PluginJSONError.malformed }
                escaped = byte == 92 && !escaped
                if byte != 92 { escaped = false }
            }
            throw PluginJSONError.malformed
        }

        mutating func number() {
            while let byte = current, (byte == 45 || byte == 43 || byte == 46 || byte == 101 || byte == 69 || (48...57).contains(byte)) { index += 1 }
        }

        mutating func literal(_ literal: String) throws {
            let bytes = Array(literal.utf8)
            guard self.bytes[index..<min(index + bytes.count, self.bytes.count)] == bytes[...] else { throw PluginJSONError.malformed }
            index += bytes.count
        }

        mutating func skipWhitespace() { while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 } }
        var current: UInt8? { index < bytes.count ? bytes[index] : nil }
    }
}
