import Foundation

public enum PingParser {
    private static let timeEquals = Array("time=".utf8)
    private static let timeLessThan = Array("time<".utf8)
    private static let roundTrip = Array("round-trip".utf8)

    public static func latencyMilliseconds(from output: String) -> Double? {
        if let latency = packetLatencyMilliseconds(from: output) {
            return latency
        }

        return roundTripAverageMilliseconds(from: output)
    }

    public static func sanitizedHost(from input: String) -> String? {
        let host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, host.count <= 253, !host.hasPrefix("-") else {
            return nil
        }

        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.rangeOfCharacter(from: allowed.inverted) == nil else {
            return nil
        }

        return host
    }

    private static func packetLatencyMilliseconds(from output: String) -> Double? {
        let bytes = output.utf8
        guard let marker = firstRange(of: timeEquals, in: bytes)
            ?? firstRange(of: timeLessThan, in: bytes) else {
            return nil
        }

        return number(after: marker.upperBound, in: bytes)
    }

    private static func roundTripAverageMilliseconds(from output: String) -> Double? {
        let bytes = output.utf8
        guard firstRange(of: roundTrip, in: bytes) != nil,
              let equals = firstIndex(of: asciiEquals, in: bytes),
              let slash = firstIndex(of: asciiSlash, in: bytes, after: equals) else {
            return nil
        }

        let averageStart = bytes.index(after: slash)
        return number(after: averageStart, in: bytes)
    }

    private static func number(after index: String.UTF8View.Index, in bytes: String.UTF8View) -> Double? {
        var start = index

        while start < bytes.endIndex, isASCIISpace(bytes[start]) {
            start = bytes.index(after: start)
        }

        var current = start
        var integer = 0.0
        var fraction = 0.0
        var divisor = 1.0
        var hasDigit = false
        var hasDecimalSeparator = false

        while current < bytes.endIndex {
            let byte = bytes[current]

            if byte >= asciiZero, byte <= asciiNine {
                let digit = Double(byte - asciiZero)
                hasDigit = true

                if hasDecimalSeparator {
                    divisor *= 10
                    fraction += digit / divisor
                } else {
                    integer = integer * 10 + digit
                }
            } else if byte == asciiDot, !hasDecimalSeparator {
                hasDecimalSeparator = true
            } else {
                break
            }

            current = bytes.index(after: current)
        }

        guard hasDigit else {
            return nil
        }

        return integer + fraction
    }

    private static func firstRange(
        of pattern: [UInt8],
        in bytes: String.UTF8View
    ) -> Range<String.UTF8View.Index>? {
        guard !pattern.isEmpty else {
            return nil
        }

        var index = bytes.startIndex
        while index < bytes.endIndex {
            var cursor = index
            var patternIndex = 0

            while patternIndex < pattern.count,
                  cursor < bytes.endIndex,
                  bytes[cursor] == pattern[patternIndex] {
                cursor = bytes.index(after: cursor)
                patternIndex += 1
            }

            if patternIndex == pattern.count {
                return index..<cursor
            }

            index = bytes.index(after: index)
        }

        return nil
    }

    private static func firstIndex(
        of byte: UInt8,
        in bytes: String.UTF8View,
        after index: String.UTF8View.Index? = nil
    ) -> String.UTF8View.Index? {
        var current = index.map { bytes.index(after: $0) } ?? bytes.startIndex

        while current < bytes.endIndex {
            if bytes[current] == byte {
                return current
            }

            current = bytes.index(after: current)
        }

        return nil
    }

    private static func isASCIISpace(_ byte: UInt8) -> Bool {
        byte == asciiSpace || byte == asciiTab
    }
}

private let asciiTab = UInt8(ascii: "\t")
private let asciiSpace = UInt8(ascii: " ")
private let asciiDot = UInt8(ascii: ".")
private let asciiSlash = UInt8(ascii: "/")
private let asciiEquals = UInt8(ascii: "=")
private let asciiZero = UInt8(ascii: "0")
private let asciiNine = UInt8(ascii: "9")
