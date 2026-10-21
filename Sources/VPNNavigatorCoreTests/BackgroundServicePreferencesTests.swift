import XCTest
@testable import VPNNavigatorCore

final class BackgroundServicePreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "vpnnav-services-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
    func testNewInstallEnablesRulesButDoesNotOptIntoLogin() {
        withDefaults { defaults in
            let preferences = BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: false)
            XCTAssertTrue(preferences.rulesEnabled)
            XCTAssertFalse(preferences.loginEnabled)
        }
    }
    func testMigrationPreservesExistingLoginService() {
        withDefaults { defaults in
            XCTAssertTrue(BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: true).loginEnabled)
        }
    }
    func testDisabledChoicesSurviveRecreationAndLoadedJobs() {
        withDefaults { defaults in
            let preferences = BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: true)
            preferences.rulesEnabled = false
            preferences.loginEnabled = false
            let restored = BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: true)
            XCTAssertFalse(restored.rulesEnabled)
            XCTAssertFalse(restored.loginEnabled)
        }
    }
    func testEnabledChoicesSurviveTemporaryServiceRemoval() {
        withDefaults { defaults in
            let preferences = BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: false)
            preferences.loginEnabled = true
            let restored = BackgroundServicePreferences(defaults: defaults, existingLoginEnabled: false)
            XCTAssertTrue(restored.rulesEnabled)
            XCTAssertTrue(restored.loginEnabled)
        }
    }
}
