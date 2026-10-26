import Foundation

public enum ProfileLibraryScope: Equatable, Sendable {
    case all, favorites, group(String)
    public var title: String {
        switch self {
        case .all: return L10n.text("全部配置")
        case .favorites: return L10n.text("收藏配置")
        case .group(let name): return name
        }
    }
}

public enum ProfileLibrarySort: String, CaseIterable, Identifiable, Sendable {
    case recommended, name, newest
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recommended: return L10n.text("收藏优先")
        case .name: return L10n.text("名称排序")
        case .newest: return L10n.text("最近导入")
        }
    }
    public init(savedValue: String?) { self = savedValue.flatMap(Self.init(rawValue:)) ?? .recommended }
}

public struct ProfileGroupSummary: Identifiable, Equatable, Sendable {
    public let name: String
    public let count: Int
    public var id: String { name }
}

/// Pure metadata projection. Search shares quick access's bounded, folded,
/// all-token matching; notes, file contents and credentials are never searched.
public struct ProfileLibraryQuery: Equatable, Sendable {
    public var query: String
    public var scope: ProfileLibraryScope
    public var sort: ProfileLibrarySort
    public init(query: String = "", scope: ProfileLibraryScope = .all, sort: ProfileLibrarySort = .recommended) {
        self.query = query; self.scope = scope; self.sort = sort
    }
    private static func groupName(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func nameBefore(_ a: VPNProfile, _ b: VPNProfile) -> Bool {
        let order = a.name.compare(b.name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive, .numeric],
                                   locale: Locale(identifier: "zh_CN"))
        return order == .orderedSame ? a.id.uuidString < b.id.uuidString : order == .orderedAscending
    }
    public static func groups(_ profiles: [VPNProfile]) -> [ProfileGroupSummary] {
        let counts = profiles.reduce(into: [String: Int]()) { result, profile in
            let key = groupName(profile.group)
            if !key.isEmpty { result[key, default: 0] += 1 }
        }
        return counts.map { ProfileGroupSummary(name: $0.key, count: $0.value) }.sorted {
            let order = $0.name.compare($1.name, options: [.numeric], locale: Locale(identifier: "zh_CN"))
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }
    public static func groupChoices(_ profiles: [VPNProfile], current: String = "") -> [String] {
        let names = ["个人", "工作", "家庭", "其他", current] + groups(profiles).map(\.name)
        let valid = Set(names.map(groupName).filter { !$0.isEmpty && $0.count <= 48 })
        return valid.sorted {
            let order = $0.compare($1, options: [.numeric], locale: Locale(identifier: "zh_CN"))
            return order == .orderedSame ? $0 < $1 : order == .orderedAscending
        }
    }
    public func results(_ profiles: [VPNProfile]) -> [VPNProfile] {
        let scoped = profiles.filter { profile in
            switch scope {
            case .all: return true
            case .favorites: return profile.isFavorite
            case .group(let group): return Self.groupName(profile.group) == Self.groupName(group)
            }
        }
        let matches = QuickProfileSearch.results(scoped, query: query)
        switch sort {
        case .recommended: return matches
        case .name: return matches.sorted(by: Self.nameBefore)
        case .newest: return matches.sorted {
            $0.importedAt == $1.importedAt ? Self.nameBefore($0, $1) : $0.importedAt > $1.importedAt
        }
        }
    }
    /// A deleted/renamed last group returns to All. Empty Favorites and
    /// unmatched searches remain explicit user filters, not silent fallbacks.
    public mutating func reconcileGroups(_ profiles: [VPNProfile]) {
        if case .group(let name) = scope,
           !Self.groups(profiles).contains(where: { $0.name == Self.groupName(name) }) { scope = .all }
    }
    public mutating func clearFilters() { query = ""; scope = .all }
    public func selectedProfile(_ selectedID: UUID?, in profiles: [VPNProfile]) -> VPNProfile? {
        results(profiles).first { $0.id == selectedID }
    }
}
