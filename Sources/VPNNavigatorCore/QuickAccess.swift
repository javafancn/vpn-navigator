import Foundation

public enum QuickAccessShortcut: String, CaseIterable, Identifiable, Sendable {
    case disabled, controlOptionCommandV, controlOptionCommandJ, controlOptionCommandSpace
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .disabled: return L10n.text("关闭")
        case .controlOptionCommandV: return "⌃⌥⌘ V"
        case .controlOptionCommandJ: return "⌃⌥⌘ J"
        case .controlOptionCommandSpace: return L10n.text("⌃⌥⌘ 空格")
        }
    }
}

/// Searches metadata only; never reads configuration, certificates or secrets.
public enum QuickProfileSearch {
    public static func results(_ profiles: [VPNProfile], query: String) -> [VPNProfile] {
        guard query.count <= 256 else { return [] }
        func folded(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                          locale: Locale(identifier: "en_US_POSIX"))
        }
        let clean = folded(query).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let tokens = clean.split(separator: " ").map(String.init)
        let matches = profiles.compactMap { profile -> (VPNProfile, String, Int)? in
            let name = folded(profile.name)
            let fields = [name, folded(profile.sourceFilename), folded(profile.group)]
            guard tokens.allSatisfy({ token in fields.contains { $0.contains(token) } }) else { return nil }
            let rank = clean.isEmpty ? 2 : name == clean ? 0 : name.hasPrefix(clean) ? 1 : 2
            return (profile, name, rank)
        }
        return matches.sorted {
            if $0.2 != $1.2 { return $0.2 < $1.2 }
            if $0.0.isFavorite != $1.0.isFavorite { return $0.0.isFavorite }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.id.uuidString < $1.0.id.uuidString
        }.map { $0.0 }
    }
    public static func movedSelection(_ selected: UUID?, in ids: [UUID], offset: Int) -> UUID? {
        guard !ids.isEmpty else { return nil }
        guard let selected, let index = ids.firstIndex(of: selected) else { return ids.first }
        let delta = offset % ids.count
        return ids[(index + delta + ids.count) % ids.count]
    }
}

public enum QuickAccessAction: Equatable, Sendable {
    case blocked, openMain, connect, requestSwitch
    public static func resolve(state: TunnelState, profileID: UUID, activeProfileID: UUID?,
                               operationInProgress: Bool, mayStart: Bool) -> Self {
        guard !operationInProgress, !ConnectionControl.inProgress(state) else { return .blocked }
        if state == .connected {
            guard let activeProfileID else { return .blocked }
            return activeProfileID == profileID ? .openMain : .requestSwitch
        }
        guard activeProfileID == nil, mayStart else { return .blocked }
        return .connect
    }
}

public struct QuickAccessSession: Equatable, Sendable {
    public let profileID: UUID
    public let attemptID: UUID
    public init(profileID: UUID, attemptID: UUID) { self.profileID = profileID; self.attemptID = attemptID }
    public func matches(_ report: SessionReport) -> Bool {
        // Active DNS/route/PF journals are expected while connected. The
        // existing stop path must clean them before a replacement can start.
        report.state == .connected && report.activeProfileID == profileID && report.attemptID == attemptID &&
            report.challenge == nil
    }
}
