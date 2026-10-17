import Foundation

/// Creates a self-contained *runtime copy* from a user-selected .ovpn and adjacent
/// certificate files. The original .ovpn remains byte-for-byte unchanged.
/// A privileged process never resolves paths supplied by the profile itself.
public enum ProfileMaterializer {
    private static let external: Set<String> = ["ca", "cert", "key", "tls-auth", "tls-crypt", "tls-crypt-v2", "pkcs12"]

    public static func materialize(text: String, directory: URL) throws -> String {
        var result: [String] = []
        var inside: String?
        let base = directory.standardizedFileURL.resolvingSymlinksInPath()
        for (index, row) in text.components(separatedBy: .newlines).enumerated() {
            let trim = row.trimmingCharacters(in: .whitespaces)
            if let tag = inside {
                result.append(row)
                if trim == "</\(tag)>" { inside = nil }
                continue
            }
            if trim.hasPrefix("<"), trim.hasSuffix(">"),
               !trim.hasPrefix("</") {
                let tag = String(trim.dropFirst().dropLast())
                inside = tag
                result.append(row)
                continue
            }
            let tokens: [String]
            do { tokens = try OpenVPNOptionLexer.tokens(trim) }
            catch { throw MaterializeError.invalidPath(index + 1) }
            guard let directive = tokens.first else { result.append(row); continue }
            if directive == "auth-user-pass", tokens.count == 2 {
                // Do not import cleartext credentials from external files.
                // The app prompts for the username/password via a secure field.
                result.append("auth-user-pass")
                continue
            }
            if external.contains(directive) && (tokens.count == 2 || directive == "tls-auth" && tokens.count == 3) {
                let relative = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !relative.hasPrefix("/"), !relative.contains("\0"),
                      !relative.contains("~") else { throw MaterializeError.invalidPath(index + 1) }
                let source = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
                guard source.path.hasPrefix(base.path + "/"),
                      (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                else { throw MaterializeError.invalidPath(index + 1) }
                let file = try Data(contentsOf: source)
                guard file.count < 1_000_000 else { throw MaterializeError.tooLarge(index + 1) }
                let body: String
                if directive == "pkcs12" {
                    body = file.base64EncodedString()
                } else {
                    guard let text = String(data: file, encoding: .utf8) else {
                        throw MaterializeError.invalidEncoding(index + 1)
                    }
                    body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                result += ["<\(directive)>", body, "</\(directive)>"]
                if directive == "tls-auth", tokens.count == 3 {
                    guard ["0", "1"].contains(tokens[2]) else { throw MaterializeError.invalidPath(index + 1) }
                    result.append("key-direction \(tokens[2])")
                }
            } else {
                result.append(row)
            }
        }
        return result.joined(separator: "\n")
    }
}
public enum MaterializeError: Error, LocalizedError {
    case invalidPath(Int), tooLarge(Int), invalidEncoding(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidPath(let line): return "Certificate file is missing, unsafe, or outside the selected folder (line \(line))."
        case .tooLarge(let line): return "Certificate file exceeds size limit (line \(line))."
        case .invalidEncoding(let line): return "Certificate must be UTF-8 PEM (line \(line))."
        }
    }
}

