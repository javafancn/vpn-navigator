import Foundation

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system, chinese, english
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
    public static let preferenceKey = "applicationLanguage"
    public static func resolve(_ preference: Self, preferredLanguages: [String]) -> Self {
        if preference != .system { return preference }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            if code == "zh" { return .chinese }
            if code == "en" { return .english }
        }
        return .english
    }
    public static func save(_ language: Self, defaults: UserDefaults) {
        defaults.set(language.rawValue, forKey: preferenceKey)
        switch language {
        case .system: defaults.removeObject(forKey: "AppleLanguages")
        case .chinese: defaults.set(["zh-Hans"], forKey: "AppleLanguages")
        case .english: defaults.set(["en"], forKey: "AppleLanguages")
        }
    }
}

/// An immutable process snapshot. Changing a preference never changes a live
/// session, persisted identifiers, wire values or user-provided text.
public enum L10n {
    public struct Entry: Codable, Sendable { public let key: String; public let zh: String; public let en: String }
    public static let entries: [Entry] = (try? JSONDecoder().decode([Entry].self, from: Data(EmbeddedLocalizationCatalog.json.utf8))) ?? []
    private static let catalog = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    public static let language: AppLanguage = {
        let arguments = ProcessInfo.processInfo.arguments
        // Existing fixtures remain deterministic. Explicit CI captures and
        // localization tests can independently exercise either language.
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
           let override = arguments.first(where: { $0.hasPrefix("--vpnnav-language=") })?.split(separator: "=").last {
            if override == "en" { return .english }
            if override == "zh-Hans" { return .chinese }
        }
        guard ProcessInfo.processInfo.processName == "VPNNavigatorApp" else { return .chinese }
        if ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
           arguments.contains(where: { $0.hasPrefix("--vpnnav-") && ($0.hasSuffix("-self-test") || $0.hasSuffix("-snapshot")) }) { return .chinese }
        let preference = AppLanguage(rawValue: UserDefaults.standard.string(forKey: AppLanguage.preferenceKey) ?? "") ?? .system
        return AppLanguage.resolve(preference, preferredLanguages: Locale.preferredLanguages)
    }()
    public static var locale: Locale {
        let region = Locale.current.region?.identifier ?? (language == .chinese ? "CN" : "US")
        return Locale(identifier: (language == .chinese ? "zh_Hans_" : "en_") + region)
    }
    public static func text(_ key: String, language requested: AppLanguage? = nil) -> String {
        guard let entry = catalog[key] else { return key }
        let choice = requested == .system ? language : (requested ?? language)
        return choice == .english ? entry.en : entry.zh
    }
    public static func format(_ key: String, _ arguments: [String], language: AppLanguage? = nil) -> String {
        let template = text(key, language: language)
        var output = "", cursor = template.startIndex
        // Substitute only template tokens, once. Argument contents are never
        // parsed, translated or treated as additional format instructions.
        while cursor < template.endIndex {
            if template[cursor] == "{", let end = template[cursor...].firstIndex(of: "}"),
               let number = Int(template[template.index(after: cursor)..<end]), arguments.indices.contains(number) {
                output += arguments[number]; cursor = template.index(after: end)
            } else { output.append(template[cursor]); cursor = template.index(after: cursor) }
        }
        return output
    }
}
