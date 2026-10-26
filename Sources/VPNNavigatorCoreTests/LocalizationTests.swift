import XCTest
@testable import VPNNavigatorCore

final class LocalizationTests: XCTestCase {
    func testSupportedLanguageResolution() {
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["fr-FR", "zh-Hans-CN"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["en-GB", "zh-CN"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["zh_TW"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve(.system, preferredLanguages: ["fr"]), .english)
        XCTAssertEqual(AppLanguage.resolve(.chinese, preferredLanguages: ["en"]), .chinese)
        XCTAssertEqual(AppLanguage.resolve(.english, preferredLanguages: ["zh"]), .english)
    }
    func testCatalogIsCompleteAndUnique() {
        XCTAssertGreaterThan(L10n.entries.count, 1000)
        XCTAssertEqual(Set(L10n.entries.map(\.key)).count, L10n.entries.count)
        for entry in L10n.entries { XCTAssertFalse(entry.zh.isEmpty); XCTAssertFalse(entry.en.isEmpty) }
    }
    func testPlaceholdersMatchInBothLanguages() throws {
        let pattern = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ text: String) -> [String] {
            pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        for entry in L10n.entries { XCTAssertEqual(tokens(entry.key), tokens(entry.zh)); XCTAssertEqual(tokens(entry.key), tokens(entry.en)) }
    }
    func testEnglishCatalogHasNoUntranslatedChinese() {
        for entry in L10n.entries { XCTAssertFalse(entry.en.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }, entry.key) }
    }
    func testPrimaryFlowsAndLegacyErrors() {
        XCTAssertEqual(L10n.text("连接总览", language: .english), "Connection overview")
        XCTAssertEqual(L10n.text("配置健康检查", language: .english), "Profile health check")
        XCTAssertEqual(L10n.text("Invalid IPv4 CIDR", language: .chinese), "无效的 IPv4 CIDR 网段")
        XCTAssertEqual(L10n.text("unknown external text", language: .english), "unknown external text")
    }
    func testUntrustedArgumentsAreNeverTranslatedOrRescanned() {
        let raw = "工作网络 {1} %@ \\(secret)"
        let output = L10n.format("目标接口：{0}；系统解析器：{1} 个。", [raw, "2"], language: .english)
        XCTAssertEqual(output, "Target interface: " + raw + "; system resolvers: 2.")
    }
    func testTranslatedArgumentsMayReorderSafely() {
        XCTAssertEqual(L10n.format("Managed routing cannot import '{0}' on line {1}. Remove conflicting routes from the profile or use Original mode.", ["route {1}", "9"], language: .chinese), "受管路由不能导入第 9 行的“route {1}”。请移除冲突路由或使用原始配置模式。")
    }
    func testPreferenceStorageIsScopedAndDoesNotApplyLive() throws {
        let name = "VPNNavLocalizationTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("keep", forKey: "profile")
        let before = L10n.language
        AppLanguage.save(.english, defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "english")
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])
        AppLanguage.save(.chinese, defaults: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])
        AppLanguage.save(.system, defaults: defaults)
        // The getter still inherits the system's global AppleLanguages after removing our override.
        XCTAssertNil(defaults.persistentDomain(forName: name)?["AppleLanguages"])
        XCTAssertEqual(defaults.string(forKey: AppLanguage.preferenceKey), "system")
        XCTAssertEqual(defaults.string(forKey: "profile"), "keep")
        XCTAssertEqual(L10n.language, before)
    }
    func testWireValuesAndProfileDataRemainStable() throws {
        XCTAssertEqual(RoutingMode.allCases.map(\.rawValue), ["Original", "Full VPN", "China Direct"])
        let profile = VPNProfile(name: "工作网络 {0}", sourceFilename: "私人.ovpn", relativePath: "id", group: "工作")
        let decoded = try JSONDecoder().decode(VPNProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(decoded.name, "工作网络 {0}")
        XCTAssertEqual(decoded.group, "工作")
    }
}
