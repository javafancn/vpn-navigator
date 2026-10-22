import AppKit
import UniformTypeIdentifiers
import VPNNavigatorCore

/// Loads file-URL representations only. Start inside SwiftUI's drop callback;
/// a provider never gets permission to copy or import configuration contents.
@MainActor
final class ProfileDropLoader {
    private var remaining: Set<Int>
    private var urls: [Int: URL] = [:]
    private let count: Int
    private let overflow: Int
    private var completion: (([URL], Int, Int) -> Void)?
    private var deadline: Task<Void, Never>?

    private init(count: Int, overflow: Int, completion: @escaping ([URL], Int, Int) -> Void) {
        self.count = count; remaining = Set(0..<count); self.overflow = overflow; self.completion = completion
    }
    static func start(_ providers: [NSItemProvider], timeoutNanoseconds: UInt64 = 3_000_000_000,
                      completion: @escaping ([URL], Int, Int) -> Void) {
        let count = min(providers.count, ProfileOpenQueue.maximumFiles)
        let batch = ProfileDropLoader(count: count, overflow: providers.count - count, completion: completion)
        guard count > 0 else { batch.finish(); return }
        batch.deadline = Task {
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            batch.finish()
        }
        for (index, provider) in providers.prefix(count).enumerated() {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url = Self.decode(item)
                Task { @MainActor in batch.receive(index, url: url) }
            }
        }
    }
    nonisolated static func decode(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data, data.count <= 16_384 {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        return nil
    }
    private func receive(_ index: Int, url: URL?) {
        guard completion != nil, remaining.remove(index) != nil else { return }
        if let url { urls[index] = url }
        if remaining.isEmpty { finish() }
    }
    private func finish() {
        guard let completion else { return }
        self.completion = nil; deadline?.cancel(); deadline = nil
        let ordered = urls.keys.sorted().compactMap { urls[$0] }
        // Missing, failed and timed-out representations share a safe category.
        completion(ordered, count - ordered.count, overflow)
    }
}
