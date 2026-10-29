import Foundation

/// Managed modes must not send their resolver traffic through country bypasses.
/// Prefer server DNS. Without a global server resolver, use public resolvers
/// through the allocated VPN family; Original mode is never changed.
public enum ManagedDNSPolicy {
    public static func hookExitStatus(in line: String) -> Int? {
        let text = line.lowercased(), marker = "dns up command exited with status "
        guard let range = text.range(of: marker),
              let status = Int(text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)),
              (-1...65535).contains(status) else { return nil }
        return status
    }
    public static func servers(provided: [String], has4: Bool, has6: Bool) throws -> [String] {
        guard provided.count <= 16 else { throw CustomRouteError.tooMany }
        let source = provided.isEmpty
            ? (has4 ? ["1.1.1.1", "9.9.9.9"] : []) + (has6 ? ["2606:4700:4700::1111", "2620:fe::fe"] : [])
            : provided
        var result: [String] = []
        for text in source {
            guard let ip = IPAddress.canonical(text) else { throw CustomRouteError.invalidPrefix }
            if let address = IPv4CIDR.parseAddress(ip) {
                guard has4 else { continue }
                guard address >> 24 != 0, address >> 24 != 127, address >> 24 < 224,
                      address & 0xffff0000 != 0xa9fe0000 else { throw CustomRouteError.invalidPrefix }
            } else {
                guard has6 else { continue }
                guard let bytes = IPv6CIDR.parseAddress(ip), bytes.contains(where: { $0 != 0 }),
                      ip != "::1", bytes[0] != 255,
                      !(bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80), !ip.hasPrefix("::ffff:") else { throw CustomRouteError.invalidPrefix }
            }
            if !result.contains(ip) { result.append(ip) }
        }
        guard !result.isEmpty else { throw DualStackError.missingTunnel }
        return result
    }
}
