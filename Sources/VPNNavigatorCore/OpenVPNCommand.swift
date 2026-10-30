import Foundation

/// Script command options such as --up parse command strings again. The
/// OpenVPN 2.7 --dns-updown option is different: startup parses a command,
/// while execution treats the whole value as one filename. Use a relative
/// filename from its trusted parent directory to satisfy both paths.
public enum OpenVPNCommand {
    public static func dnsUpDownInvocation(_ path: String) throws -> (directory: URL, executable: String) {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              URL(fileURLWithPath: path).lastPathComponent == "macos-dns-updown.sh" else {
            throw OpenVPNCommandError.invalidPath
        }
        return (URL(fileURLWithPath: path).deletingLastPathComponent(), "./macos-dns-updown.sh")
    }

    /// For command-string options only; never use this for --dns-updown.
    public static func quotedExecutable(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OpenVPNCommandError.invalidPath
        }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
public enum OpenVPNCommandError: Error { case invalidPath }
