import Foundation

/// Script command options such as --up parse command strings again. The
/// OpenVPN 2.7 --dns-updown option is different: startup parses a command,
/// while execution treats the whole value as one filename. Use a relative
/// filename from its trusted parent directory to satisfy both paths.
public enum OpenVPNCommand {
    /// Only TCP transports use TCP_NODELAY. Keep the server's protocol and
    /// the profile's MTU/MSS unchanged; neither can be guessed from the client.
    public static func latencyArguments(for profile: String) -> [String] {
        guard let remotes = try? GuardEndpoint.candidates(profile), !remotes.isEmpty,
              remotes.allSatisfy({ $0.transport == .tcp }) else { return [] }
        return ["--socket-flags", "TCP_NODELAY"]
    }
    /// Reserve time for alternate pinned endpoints inside the same total
    /// connection deadline. Explicit user timeouts always take precedence.
    public static func candidateTimeoutArguments(for profile: String, remainingSeconds: Int, candidateCount: Int) -> [String] {
        guard candidateCount > 1 else { return [] }
        var inline: String?
        for row in profile.components(separatedBy: .newlines) {
            let text = row.trimmingCharacters(in: .whitespaces)
            if let tag = inline { if text == "</\(tag)>" { inline = nil }; continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { inline = String(text.dropFirst().dropLast()); continue }
            guard let tokens = try? OpenVPNOptionLexer.tokens(text) else { return [] }
            if ["connect-timeout", "server-poll-timeout"].contains(tokens.first ?? "") { return [] }
        }
        let seconds = min(10, max(1, remainingSeconds / min(candidateCount, 4)))
        return ["--server-poll-timeout", String(seconds)]
    }
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
