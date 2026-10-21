import Foundation

/// Desired user services are independent of their temporary launchd state.
/// Maintenance must stop jobs without overwriting these choices.
public final class BackgroundServicePreferences {
    private let defaults: UserDefaults
    private let rulesKey = "backgroundRulesEnabled"
    private let loginKey = "backgroundLoginEnabled"

    public init(defaults: UserDefaults = .standard, existingLoginEnabled: Bool) {
        self.defaults = defaults
        if defaults.object(forKey: rulesKey) == nil {
            defaults.set(true, forKey: rulesKey)
        }
        if defaults.object(forKey: loginKey) == nil {
            defaults.set(existingLoginEnabled, forKey: loginKey)
        }
    }
    public var rulesEnabled: Bool {
        get { defaults.bool(forKey: rulesKey) }
        set { defaults.set(newValue, forKey: rulesKey) }
    }
    public var loginEnabled: Bool {
        get { defaults.bool(forKey: loginKey) }
        set { defaults.set(newValue, forKey: loginKey) }
    }
}
