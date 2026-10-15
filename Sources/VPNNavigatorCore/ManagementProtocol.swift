import Foundation

public enum TunnelState: String, Codable, Sendable {
    case disconnected, connecting, authenticating, connected, reconnecting, stopping, failed
}
public struct TunnelSnapshot: Equatable, Sendable {
    public let state: TunnelState
    public let remoteIPv4: String?
    public let localTunnelIPv4: String?
    public let message: String
}
public struct TunnelTraffic: Equatable, Sendable {
    public let receivedBytes: UInt64
    public let sentBytes: UInt64
    public init(receivedBytes: UInt64, sentBytes: UInt64) {
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}
public enum ManagementParser {
    public static func parseByteCount(_ line: String) -> TunnelTraffic? {
        guard line.hasPrefix(">BYTECOUNT:") else { return nil }
        let numbers = line.dropFirst(">BYTECOUNT:".count)
            .split(separator: ",", omittingEmptySubsequences: false)
        guard numbers.count == 2,
              let received = UInt64(numbers[0]),
              let sent = UInt64(numbers[1]) else { return nil }
        return TunnelTraffic(receivedBytes: received, sentBytes: sent)
    }

    public static func parseState(_ line: String) -> TunnelSnapshot? {
        // OpenVPN state: epoch,STATE,description,local_ip,remote_ip,...
        let clean = line.hasPrefix(">STATE:") ? String(line.dropFirst(7)) : line
        let fields = clean.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 2 else { return nil }
        let state: TunnelState
        switch fields[1] {
        case "CONNECTING", "WAIT", "RESOLVE", "TCP_CONNECT", "GET_CONFIG", "ASSIGN_IP", "ADD_ROUTES":
            state = .connecting
        case "AUTH": state = .authenticating
        case "AUTH_FAILED": state = .failed
        case "CONNECTED": state = .connected
        case "RECONNECTING": state = .reconnecting
        case "EXITING": state = .stopping
        default: return nil
        }
        let local = fields.count > 3 && IPv4CIDR.parseAddress(fields[3]) != nil ? fields[3] : nil
        let remote = fields.count > 4 && IPv4CIDR.parseAddress(fields[4]) != nil ? fields[4] : nil
        return TunnelSnapshot(state: state, remoteIPv4: remote, localTunnelIPv4: local,
                              message: fields.count > 2 ? fields[2] : "")
    }
    public static func parsePasswordChallenge(_ line: String) -> Bool {
        line.hasPrefix(">PASSWORD:Need 'Auth' username/password")
    }
}

/// Values for the OpenVPN management text protocol, not shell quoting.
/// Caller must reject control characters before using this escape function.
public enum ManagementEscaping {
    public static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
