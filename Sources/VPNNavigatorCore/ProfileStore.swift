import Foundation

/// A private profile repository with version history.
public struct ProfileRevision: Identifiable, Sendable {
    public let filename: String
    public let createdAt: Date
    public var id: String { filename }
}
/// The initially imported source is saved to history on the first edit.
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
        // Normalize external inline-capable certificates into a private runtime copy.
        // Preserve the user's original bytes as the canonical source.
        let runtime = try ProfileMaterializer.materialize(text: string, directory: file.deletingLastPathComponent())
        let id = UUID()
        let filename = "\(id.uuidString).ovpn"
        let destination = root.appendingPathComponent(filename)
        try contents.write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        let runtimeURL = root.appendingPathComponent("\(id.uuidString).runtime.ovpn")
        try runtime.write(to: runtimeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
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
    public func runtimeConfig(for profile: VPNProfile) throws -> String {
        guard profile.relativePath == "\(profile.id.uuidString).ovpn" else { throw StoreError.invalidFile }
        let normalized = root.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
        guard FileManager.default.fileExists(atPath: normalized.path) else { return try original(for: profile) }
        return try String(contentsOf: normalized, encoding: .utf8)
    }
    private func historyDirectory(for id: UUID) -> URL {
        root.appendingPathComponent("History", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    public func revisions(for profile: VPNProfile) throws -> [ProfileRevision] {
        let folder = historyDirectory(for: profile.id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
            .filter {
                $0.pathExtension == "ovpn" &&
                UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
            }
            .map {
                let attr = try $0.resourceValues(forKeys: [.contentModificationDateKey])
                return ProfileRevision(filename: $0.lastPathComponent,
                                       createdAt: attr.contentModificationDate ?? Date.distantPast)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Save a safe, self-contained profile while preserving its prior source.
    public func revise(_ profile: VPNProfile, text: String) throws {
        try prepare()
        guard (try list()).contains(where: { $0.id == profile.id }),
              profile.relativePath == "\(profile.id.uuidString).ovpn" else {
            throw StoreError.notFound
        }
        _ = try ProfileSafety.validate(text)
        let oldSource = try original(for: profile)
        let oldRuntime = try runtimeConfig(for: profile)
        guard oldSource != text else { return }
        let history = historyDirectory(for: profile.id)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: history.path)
        let archived = history.appendingPathComponent(UUID().uuidString + ".ovpn")
        try oldSource.write(to: archived, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archived.path)
        let sourceURL = root.appendingPathComponent(profile.relativePath)
        let runtimeURL = root.appendingPathComponent("\(profile.id.uuidString).runtime.ovpn")
        do {
            try text.write(to: sourceURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sourceURL.path)
            try text.write(to: runtimeURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
        } catch {
            try? oldSource.write(to: sourceURL, atomically: true, encoding: .utf8)
            try? oldRuntime.write(to: runtimeURL, atomically: true, encoding: .utf8)
            throw error
        }
    }

    public func restore(_ profile: VPNProfile, revision filename: String) throws {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              filename.hasSuffix(".ovpn"),
              UUID(uuidString: String(filename.dropLast(5))) != nil else {
            throw StoreError.invalidFile
        }
        let old = try String(contentsOf: historyDirectory(for: profile.id)
            .appendingPathComponent(filename), encoding: .utf8)
        try revise(profile, text: old)
    }

    public func delete(id: UUID) throws {
        var profiles = try list()
        guard let item = profiles.first(where: { $0.id == id }) else { throw StoreError.notFound }
        profiles.removeAll { $0.id == id }
        try save(profiles)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(item.id.uuidString).ovpn"))
        try? FileManager.default.removeItem(at: root.appendingPathComponent("\(item.id.uuidString).runtime.ovpn"))
        try? FileManager.default.removeItem(at: historyDirectory(for: item.id))
    }
    private func save(_ profiles: [VPNProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profiles).write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }
}
public enum StoreError: Error { case invalidFile, notFound }
