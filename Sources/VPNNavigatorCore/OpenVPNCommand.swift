import Foundation

/// OpenVPN parses script command strings again after receiving an argv value.
/// Preserve one executable path through that second parse, including spaces,
/// quotes and backslashes. This does not invoke a shell or accept arguments.
public enum OpenVPNCommand {
    public static func quotedExecutable(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OpenVPNCommandError.invalidPath
        }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
public enum OpenVPNCommandError: Error { case invalidPath }
