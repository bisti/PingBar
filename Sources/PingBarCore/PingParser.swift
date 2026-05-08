import Foundation

public enum PingParser {
    private static let timeRegex = try! NSRegularExpression(
        pattern: #"time[=<]\s*([0-9]+(?:\.[0-9]+)?)\s*ms"#,
        options: []
    )

    private static let roundTripRegex = try! NSRegularExpression(
        pattern: #"round-trip.*=\s*([0-9]+(?:\.[0-9]+)?)/([0-9]+(?:\.[0-9]+)?)/"#,
        options: []
    )

    public static func latencyMilliseconds(from output: String) -> Double? {
        if let match = firstCapture(in: output, using: timeRegex, group: 1) {
            return Double(match)
        }

        if let average = firstCapture(in: output, using: roundTripRegex, group: 2) {
            return Double(average)
        }

        return nil
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

    private static func firstCapture(
        in output: String,
        using regex: NSRegularExpression,
        group: Int
    ) -> String? {
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard let match = regex.firstMatch(in: output, options: [], range: range) else {
            return nil
        }

        guard let captureRange = Range(match.range(at: group), in: output) else {
            return nil
        }

        return String(output[captureRange])
    }
}
