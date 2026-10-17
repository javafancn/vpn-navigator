import Foundation

public enum DiagnosticTargetPolicy {
    public static func validHostname(_ input: String) -> Bool {
        guard !input.isEmpty, input.utf8.count <= 253 else { return false }
        return input.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
public struct PingSummary: Equatable, Sendable {
    public let received: Int
    public let loss: Double
    public let averageMilliseconds: Double?
    public static func parse(_ output: String) -> Self? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+) packets transmitted, (\d+) packets received, ([0-9.]+)% packet loss"#),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let countRange = Range(match.range(at: 2), in: output),
              let lossRange = Range(match.range(at: 3), in: output),
              let received = Int(output[countRange]), let loss = Double(output[lossRange]) else { return nil }
        let latency = output.components(separatedBy: .newlines).first { $0.contains("min/avg/max") }?
            .components(separatedBy: "=").last?.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "/").dropFirst().first.flatMap(Double.init)
        return .init(received: received, loss: loss, averageMilliseconds: latency)
    }
}
