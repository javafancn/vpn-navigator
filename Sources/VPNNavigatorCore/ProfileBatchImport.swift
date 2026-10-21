import Foundation

public struct ProfileImportResult: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case waiting, importing, imported(UUID), failed(ProfileImportFailure), cancelled
    }
    public let id = UUID()
    public let filename: String
    public var status: Status
    public init(filename: String, status: Status = .waiting) {
        self.filename = String(filename.filter { !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }.prefix(180))
        self.status = status
    }
}
public enum ProfileImportFailure: String, Sendable {
    case invalidFile, material, tooLarge, storage
    public var summary: String {
        switch self {
        case .invalidFile: return "不是有效的 UTF-8 OpenVPN 配置"
        case .material: return "证书材料缺失、过大或引用不安全"
        case .tooLarge: return "配置超过 2 MB 限制"
        case .storage: return "读取或保存失败，请检查文件和目录权限"
        }
    }
    static func classify(_ error: Error) -> Self {
        if error is MaterializeError { return .material }
        if error is StoreError { return .invalidFile }
        if let failure = error as? ProfileFileIO.Failure, case .tooLarge = failure { return .tooLarge }
        return .storage
    }
}
public final class ProfileImportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}
public struct ProfileBatchImporter: Sendable {
    public static let maximumFiles = 100
    private let store: ProfileStore
    public init(store: ProfileStore) { self.store = store }
    public func run(_ urls: [URL], cancellation: ProfileImportCancellation,
                    progress: @escaping @Sendable ([ProfileImportResult]) async -> Void = { _ in }) async throws -> [ProfileImportResult] {
        guard !urls.isEmpty, urls.count <= Self.maximumFiles else { throw Failure.fileCount }
        var results = urls.map { ProfileImportResult(filename: $0.lastPathComponent) }
        await progress(results)
        for index in urls.indices {
            if cancellation.isCancelled || Task.isCancelled {
                for remaining in index..<urls.count { results[remaining].status = .cancelled }
                await progress(results)
                break
            }
            results[index].status = .importing
            await progress(results)
            let granted = urls[index].startAccessingSecurityScopedResource()
            defer { if granted { urls[index].stopAccessingSecurityScopedResource() } }
            do { results[index].status = .imported(try await store.importProfile(from: urls[index]).id) }
            catch { results[index].status = .failed(.classify(error)) }
            await progress(results)
        }
        return results
    }
    public enum Failure: Error, LocalizedError {
        case fileCount
        public var errorDescription: String? { "一次请选择 1–100 个配置文件。" }
    }
}
