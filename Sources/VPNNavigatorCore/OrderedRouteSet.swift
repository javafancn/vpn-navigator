import Foundation

/// Stable ownership order with amortized constant-time insertion/removal.
/// Tombstones avoid shifting all later routes on every live policy change.
public struct OrderedRouteSet<Element: Hashable & Sendable>: Sendable {
    private var storage: [Element?] = []
    private var positions: [Element: Int] = [:]
    public init(_ elements: [Element] = []) {
        for element in elements { insert(element) }
    }
    public var elements: [Element] { storage.compactMap { $0 } }
    public var isEmpty: Bool { positions.isEmpty }
    public var count: Int { positions.count }
    public func contains(_ element: Element) -> Bool { positions[element] != nil }
    public mutating func insert(_ element: Element) {
        guard positions[element] == nil else { return }
        positions[element] = storage.count; storage.append(element)
    }
    public mutating func remove(_ element: Element) {
        guard let index = positions.removeValue(forKey: element) else { return }
        storage[index] = nil
        if positions.isEmpty { storage.removeAll(keepingCapacity: true) }
        else if storage.count > 1024 && storage.count > positions.count * 2 {
            let live = elements
            storage.removeAll(keepingCapacity: true); positions.removeAll(keepingCapacity: true)
            for value in live { insert(value) }
        }
    }
}
