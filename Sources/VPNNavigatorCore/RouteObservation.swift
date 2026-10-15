import Foundation

/// Observation parsed from macOS '/sbin/route -n get -net <network>'.
/// In absence of reliable exact mask information, never assume ownership.
public struct ObservedIPv4Route: Sendable {
    public let gateway: String?
    public let interface: String?
    public let mask: String?
    public let destination: String?

    public init(commandOutput: String) {
        let fields = Dictionary(commandOutput.components(separatedBy: .newlines).compactMap { row -> (String,String)? in
            let parts = row.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]).trimmingCharacters(in: .whitespaces))
        }, uniquingKeysWith: { first, _ in first })
        gateway = fields["gateway"]
        interface = fields["interface"]
        mask = fields["mask"]
        destination = fields["destination"]
    }

    public func isExactly(_ target: RouteTarget) -> Bool {
        // Host routes may omit a mask; non-host routes must report the exact
        // netmask to avoid confusing an inherited /1 or default route with ours.
        if target.prefix.prefix != 32 {
            guard normalizedMask == target.prefix.netmask else { return false }
        } else if let normalizedMask, normalizedMask != target.prefix.netmask {
            return false
        }
        if let destination, let dest = IPv4CIDR.parseAddress(destination) {
            guard dest == target.prefix.network else { return false }
        }
        switch target.destination {
        case .viaGateway(let expected):
            return gateway == expected
        case .interface(let expected):
            return interface == expected
        }
    }

    private var normalizedMask: String? {
        guard let mask else { return nil }
        if mask.hasPrefix("0x"), let bits = UInt32(mask.dropFirst(2), radix: 16) {
            return IPv4CIDR.parseAddressString(bits)
        }
        return mask
    }
}
