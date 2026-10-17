import Foundation

/// Tokenizes one non-inline configuration line; never evaluates a shell.
/// Used for validation/materialization only. The engine receives the original
/// validated text, preserving OpenVPN's own option semantics.
public enum OpenVPNOptionLexer {
    public static func tokens(_ line: String) throws -> [String] {
        var result: [String] = [], current = ""
        var quote: Character?, escaped = false, started = false
        for character in line {
            if escaped { current.append(character); escaped = false; started = true; continue }
            if character == "\\", quote != "'" { escaped = true; started = true; continue }
            if let active = quote {
                if character == active { quote = nil } else { current.append(character) }
                started = true; continue
            }
            if character == "\"" || character == "'" { quote = character; started = true; continue }
            if character.isWhitespace {
                if started { result.append(current); current = ""; started = false }
            } else if (character == "#" || character == ";"), !started {
                break
            } else { current.append(character); started = true }
        }
        guard quote == nil, !escaped else { throw OpenVPNOptionLexerError.unterminated }
        if started { result.append(current) }
        return result
    }
}
public enum OpenVPNOptionLexerError: Error { case unterminated }
