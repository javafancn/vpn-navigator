import Foundation
import VPNNavigatorCore

/// Invoked only by the existing destructive Local service acceptance command
/// on a disposable CI Mac. Uses the production model and actual user launchd.
@MainActor
enum BackgroundServicesSelfTest {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true" else {
            throw LocalInstallError.unsafe
        }
        let suite = "com.javafancn.vpn-navigator.services-fixture." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw LocalInstallError.command }
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(backgroundServiceDefaults: defaults)
        await model.setAutomaticRules(false)
        await model.setLaunchAtLogin(false)
        guard model.backgroundServicesIssue == nil else { throw LocalInstallError.command }

        // Existing loaded jobs cannot override an explicit disabled choice.
        try UserServices.enableRules()
        try UserServices.setLogin(true)
        let disabled = AppModel(backgroundServiceDefaults: defaults)
        await disabled.restoreBackgroundServices()
        guard !disabled.automaticRulesEnabled, !disabled.launchAtLogin,
              disabled.backgroundServicesIssue == nil,
              UserServices.rulesStatus == .notRegistered,
              UserServices.loginStatus == .notRegistered else { throw LocalInstallError.command }

        await disabled.setAutomaticRules(true)
        await disabled.setLaunchAtLogin(true)
        guard disabled.backgroundServicesIssue == nil,
              UserServices.rulesStatus == .enabled,
              UserServices.loginStatus == .enabled else { throw LocalInstallError.command }

        // Maintenance/repair stop jobs without changing saved intent. The
        // exact same code hash must restore both on the next application run.
        try await UserServices.disableRules()
        try UserServices.setLogin(false)
        let restored = AppModel(backgroundServiceDefaults: defaults)
        await restored.restoreBackgroundServices()
        guard restored.automaticRulesEnabled, restored.launchAtLogin,
              restored.backgroundServicesIssue == nil,
              UserServices.rulesStatus == .enabled,
              UserServices.loginStatus == .enabled else { throw LocalInstallError.command }
        let rules = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.javafancn.vpn-navigator.local-rules.plist")
        let before = try FileManager.default.attributesOfItem(atPath: rules.path)[.modificationDate] as? Date
        await restored.restoreBackgroundServices()
        let after = try FileManager.default.attributesOfItem(atPath: rules.path)[.modificationDate] as? Date
        guard before != nil, before == after, restored.backgroundServicesIssue == nil else {
            throw LocalInstallError.command
        }
        guard await restored.prepareMaintenance(removeProfiles: false),
              UserServices.rulesStatus == .notRegistered,
              UserServices.loginStatus == .notRegistered else { throw LocalInstallError.command }
        guard BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: false).loginEnabled,
              BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: false).rulesEnabled else {
            throw LocalInstallError.command
        }
        print("PASS: saved disabled choices, same-build rules/login restoration and idempotent reconciliation through actual launchd.")
    }
}
