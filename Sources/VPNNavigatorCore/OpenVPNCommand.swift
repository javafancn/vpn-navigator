import Foundation

/// Script command options such as --up parse command strings again. The
/// OpenVPN 2.7 --dns-updown option is different: startup parses a command,
/// while execution treats the whole value as one filename. Use a relative
/// filename from its trusted parent directory to satisfy both paths.
public enum OpenVPNCommand {
    /// TCP transports use TCP_NODELAY; UDP transports raise macOS socket
    /// buffers above the 9 KB default unless the profile already sets them.
    public static func latencyArguments(for profile: String) -> [String] {
        guard let remotes = try? GuardEndpoint.candidates(profile), !remotes.isEmpty,
              let directives = configuredDirectives(in: profile) else { return [] }
        if remotes.allSatisfy({ $0.transport == .tcp }) {
            return directives.contains("socket-flags") ? [] : ["--socket-flags", "TCP_NODELAY"]
        }
        if remotes.allSatisfy({ $0.transport == .udp }) {
            var arguments: [String] = []
            if !directives.contains("sndbuf") { arguments += ["--sndbuf", "524288"] }
            if !directives.contains("rcvbuf") { arguments += ["--rcvbuf", "524288"] }
            return arguments
        }
        return []
    }
    /// Reserve time for alternate pinned endpoints inside the same total
    /// connection deadline. Explicit user timeouts always take precedence.
    public static func candidateTimeoutArguments(for profile: String, remainingSeconds: Int, candidateCount: Int) -> [String] {
        guard candidateCount > 1,
              let directives = configuredDirectives(in: profile),
              !directives.contains("connect-timeout"),
              !directives.contains("server-poll-timeout") else { return [] }
        let seconds = min(10, max(1, remainingSeconds / min(candidateCount, 4)))
        return ["--server-poll-timeout", String(seconds)]
    }
    private static func configuredDirectives(in profile: String) -> Set<String>? {
        var inline: String?
        var directives: Set<String> = []
        for row in profile.components(separatedBy: .newlines) {
            let text = row.trimmingCharacters(in: .whitespaces)
            if let tag = inline { if text == "</\(tag)>" { inline = nil }; continue }
            if text.isEmpty || text.hasPrefix("#") || text.hasPrefix(";") { continue }
            if text.hasPrefix("<"), text.hasSuffix(">") { inline = String(text.dropFirst().dropLast()); continue }
            guard let tokens = try? OpenVPNOptionLexer.tokens(text) else { return nil }
            if let first = tokens.first { directives.insert(first) }
        }
        return inline == nil ? directives : nil
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
