import Foundation

/// A local, private repository. Keeps the original .ovpn bytes unchanged.
public actor ProfileStore {
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("profiles.json") }
    public init(root: URL) { self.root = root }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
    public func list() throws -> [VPNProfile] {
        try prepare()
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        return try JSONDecoder().decode([VPNProfile].self, from: Data(contentsOf: indexURL))
    }
    public func importProfile(from file: URL) throws -> VPNProfile {
        try prepare()
        guard file.pathExtension.lowercased() == "ovpn" else { throw StoreError.invalidFile }
        let contents = try Data(contentsOf: file)
        guard !contents.isEmpty, contents.count <= 2_000_000,
              let string = String(data: contents, encoding: .utf8),
              string.contains("remote ") || string.contains("\nremote ") else { throw StoreError.invalidFile }
        let id = UUID()
        let filename = "\(id.uuidString).ovpn"
        let destination = root.appendingPathComponent(filename)
        try contents.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let profile = VPNProfile(id: id, name: file.deletingPathExtension().lastPathComponent,
                                 sourceFilename: file.lastPathComponent, relativePath: filename)
        var profiles = try list()
        profiles.append(profile)
        try save(profiles)
        return profile
    }
    public func update(_ profile: VPNProfile) throws {
        var profiles = try list()
        guard let idx = profiles.firstIndex(where: { $0.id == profile.id }) else { throw StoreError.notFound }
        profiles[idx] = profile
        try save(profiles)
    }
    public func original(for profile: VPNProfile) throws -> String {
        // Never allow untrusted persisted paths to escape the store.
        guard profile.relativePath == "\(profile.id.uuidString).ovpn" else { throw StoreError.invalidFile }
        return try String(contentsOf: root.appendingPathComponent(profile.relativePath), encoding: .utf8)
    }
    public func delete(id: UUID) throws {
        var profiles = try list()
        guard let item = profiles.first(where: { $0.id == id }) else { throw StoreError.notFound }
        profiles.removeAll { $0.id == id }
        try save(profiles)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(item.id.uuidString).ovpn"))
    }
    private func save(_ profiles: [VPNProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}
public enum StoreError: Error { case invalidFile, notFound }
