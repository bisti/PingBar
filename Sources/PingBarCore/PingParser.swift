import Foundation

public enum PingParser {
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
        guard let marker = output.range(of: "time=") ?? output.range(of: "time<") else {
            return nil
        }

        return number(after: marker.upperBound, in: output)
    }

    private static func roundTripAverageMilliseconds(from output: String) -> Double? {
        guard output.contains("round-trip"),
              let equals = output.firstIndex(of: "="),
              let slash = output[equals...].firstIndex(of: "/") else {
            return nil
        }

        let averageStart = output.index(after: slash)
        return number(after: averageStart, in: output)
    }

    private static func number(after index: String.Index, in output: String) -> Double? {
        var start = index

        while start < output.endIndex, output[start].isWhitespace {
            start = output.index(after: start)
        }

        var end = start
        var hasDigit = false
        var hasDecimalSeparator = false

        while end < output.endIndex {
            let character = output[end]

            if character.isNumber {
                hasDigit = true
            } else if character == ".", !hasDecimalSeparator {
                hasDecimalSeparator = true
            } else {
                break
            }

            end = output.index(after: end)
        }

        guard hasDigit else {
            return nil
        }

        return Double(output[start..<end])
    }
}
