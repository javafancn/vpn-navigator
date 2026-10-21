import Foundation

public enum ProfileExportKind: Equatable, Sendable { case portable, routePreview }
public enum ProfileExport {
    public static func render(runtime: String, kind: ProfileExportKind, mode: RoutingMode, rules: RuleSet?) throws -> Data {
        // Runtime material is already self-contained. Never resolve original
        // external paths, read Keychain or serialize the UI credential fields.
        let validated = try ProfileSafety.validate(runtime)
        let text: String
        switch kind {
        case .portable: text = validated.text
        case .routePreview: text = try ProfileCompiler.render(original: validated.text, mode: mode, rules: rules)
        }
        return Data(text.utf8)
    }
    public static func filename(name: String, kind: ProfileExportKind) -> String {
        var safe = ""
        for character in name {
            guard character != "/", character != "\\", character != ":",
                  !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
            if (safe + String(character)).utf8.count > 120 { break }
            safe.append(character)
        }
        safe = safe.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if safe.isEmpty { safe = "VPN-profile" }
        return safe + (kind == .portable ? ".ovpn" : "-routes-preview.ovpn")
    }
}
