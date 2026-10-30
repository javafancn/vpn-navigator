import Foundation

/// Transient, bounded framing for startup diagnostics. Only a predefined
/// category escapes; raw configuration paths, endpoints and credentials do not.
public struct OpenVPNStartupLog: Sendable {
    private var pending = Data()
    private var droppingLine = false
    public private(set) var failure: DiagnosticCode?
    public init() {}

    public mutating func receive(_ data: Data) {
        for byte in data {
            if byte == 10 {
                if !droppingLine { classifyPending() }
                pending.removeAll(keepingCapacity: true)
                droppingLine = false
            } else if !droppingLine {
                if pending.count < 8192 { pending.append(byte) }
                else { pending.removeAll(keepingCapacity: true); droppingLine = true }
            }
        }
    }
    public mutating func finish() {
        if !droppingLine { classifyPending() }
        pending.removeAll(keepingCapacity: false)
        droppingLine = false
    }
    private mutating func classifyPending() {
        guard failure == nil, !pending.isEmpty,
              let line = String(data: pending, encoding: .utf8) else { return }
        failure = OpenVPNLogClassifier.classify(line)
    }
}
