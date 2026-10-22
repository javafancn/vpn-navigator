import Foundation

/// In-memory file requests. Admission never reads a file or follows a link.
public struct ProfileOpenQueue: Equatable, Sendable {
    public static let maximumFiles = ProfileBatchImporter.maximumFiles
    public private(set) var urls: [URL] = []
    public private(set) var unsupportedCount = 0
    public private(set) var duplicateCount = 0
    public private(set) var overflowCount = 0
    public private(set) var unreadableCount = 0
    public init() {}
    public var isEmpty: Bool { urls.isEmpty && unsupportedCount == 0 && overflowCount == 0 && unreadableCount == 0 }
    public var filenames: [String] { urls.map { ProfileImportResult(filename: $0.lastPathComponent).filename } }

    public mutating func append(_ incoming: [URL]) {
        overflowCount = bounded(overflowCount, max(0, incoming.count - Self.maximumFiles))
        for url in incoming.prefix(Self.maximumFiles) {
            guard url.isFileURL, (url.host ?? "").isEmpty || url.host?.lowercased() == "localhost",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.absoluteString.utf8.count <= 16_384, !url.path.contains("\0"),
                  !url.hasDirectoryPath, url.pathExtension.lowercased() == "ovpn" else {
                unsupportedCount = bounded(unsupportedCount, 1); continue
            }
            let normalized = Self.lexicalPath(url)
            guard !urls.contains(where: { Self.lexicalPath($0) == normalized }) else {
                duplicateCount = bounded(duplicateCount, 1); continue
            }
            guard urls.count < Self.maximumFiles else { overflowCount = bounded(overflowCount, 1); continue }
            // Preserve the original URL and its possible security scope.
            urls.append(url)
        }
    }
    public mutating func merge(_ other: Self) {
        append(other.urls)
        unsupportedCount = bounded(unsupportedCount, other.unsupportedCount)
        duplicateCount = bounded(duplicateCount, other.duplicateCount)
        overflowCount = bounded(overflowCount, other.overflowCount)
        unreadableCount = bounded(unreadableCount, other.unreadableCount)
    }
    public mutating func recordUnresolved(_ count: Int, overflow: Int = 0) {
        unreadableCount = bounded(unreadableCount, max(0, count))
        overflowCount = bounded(overflowCount, max(0, overflow))
    }
    public mutating func clear() { self = Self() }
    private func bounded(_ existing: Int, _ added: Int) -> Int { existing + min(max(0, added), 1_000_000 - existing) }
    private static func lexicalPath(_ url: URL) -> String {
        // Foundation's file-path standardization can consult the filesystem.
        // Admission only folds textual dot components; retain the original URL.
        var components: [Substring] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !components.isEmpty { components.removeLast() } }
            else { components.append(part) }
        }
        return "/" + components.joined(separator: "/")
    }
}
