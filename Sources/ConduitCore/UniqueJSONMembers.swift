import Foundation

/// Check original JSON bytes before a dictionary decoder discards repeated keys.
/// JSONSerialization remains responsible for value syntax and representation.
enum UniqueJSONMembers {
    static func object(from data: Data) throws -> Any {
        let object = try JSONSerialization.jsonObject(with: data)
        var scanner = Scanner(bytes: Array(data))
        try scanner.value()
        scanner.whitespace()
        guard scanner.position == scanner.bytes.count else { throw Failure.malformed }
        return object
    }

    private enum Failure: Error { case duplicateMember, malformed }

    private struct Scanner {
        let bytes: [UInt8]
        var position = 0

        mutating func whitespace() {
            while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) {
                position += 1
            }
        }

        mutating func string() throws -> String {
            let start = position
            guard position < bytes.count, bytes[position] == 34 else { throw Failure.malformed }
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 92 { position += 1 }
                else if byte == 34 {
                    let data = Data(bytes[start..<position])
                    guard let result = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String else {
                        throw Failure.malformed
                    }
                    return result
                }
            }
            throw Failure.malformed
        }

        mutating func value() throws {
            whitespace()
            guard position < bytes.count else { throw Failure.malformed }
            switch bytes[position] {
            case 123: // object
                position += 1
                whitespace()
                var keys = Set<String>()
                if position < bytes.count, bytes[position] == 125 { position += 1; return }
                while true {
                    whitespace()
                    let key = try string()
                    guard keys.insert(key).inserted else { throw Failure.duplicateMember }
                    whitespace()
                    guard position < bytes.count, bytes[position] == 58 else { throw Failure.malformed }
                    position += 1
                    try value()
                    whitespace()
                    guard position < bytes.count else { throw Failure.malformed }
                    if bytes[position] == 125 { position += 1; return }
                    guard bytes[position] == 44 else { throw Failure.malformed }
                    position += 1
                }
            case 91: // array
                position += 1
                whitespace()
                if position < bytes.count, bytes[position] == 93 { position += 1; return }
                while true {
                    try value()
                    whitespace()
                    guard position < bytes.count else { throw Failure.malformed }
                    if bytes[position] == 93 { position += 1; return }
                    guard bytes[position] == 44 else { throw Failure.malformed }
                    position += 1
                }
            case 34: _ = try string()
            default:
                let start = position
                while position < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[position]) {
                    position += 1
                }
                guard position > start else { throw Failure.malformed }
            }
        }
    }
}
