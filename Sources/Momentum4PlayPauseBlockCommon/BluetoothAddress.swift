import Foundation

public struct BluetoothAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String {
        rawValue
    }

    public var comparableKey: String {
        Self.normalizeComparable(rawValue)!
    }

    public init?(normalizing candidate: String) {
        guard let normalized = Self.normalizeComparable(candidate) else {
            return nil
        }

        let pairs = stride(from: 0, to: normalized.count, by: 2).map { index in
            let start = normalized.index(normalized.startIndex, offsetBy: index)
            let end = normalized.index(start, offsetBy: 2)
            return String(normalized[start..<end])
        }

        self.rawValue = pairs.joined(separator: ":")
    }

    public static func normalizeComparable(_ candidate: String?) -> String? {
        guard let candidate else {
            return nil
        }

        let hexCharacters = candidate
            .uppercased()
            .filter { $0.isHexDigit }

        guard hexCharacters.count == 12 else {
            return nil
        }

        return String(hexCharacters)
    }

    public static func sanitizeUserEntry(_ candidate: String) -> String {
        let allowed = candidate.uppercased().filter { character in
            character.isHexDigit || character == ":" || character == "-"
        }

        return String(allowed.prefix(17))
    }
}
