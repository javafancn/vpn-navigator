import Foundation
import SystemConfiguration

// In-memory SystemConfiguration boundary. Compile the unchanged journal and
// self-test against this store; no real service, resolver or route is modified.
final class FixtureDNSStore {}
private var fixtureDNSValues: [String: Any] = [:]
func FixtureSCDynamicStoreCreate(_ allocator: CFAllocator?, _ name: CFString,
                          _ callback: SCDynamicStoreCallBack?, _ context: UnsafeMutablePointer<SCDynamicStoreContext>?) -> FixtureDNSStore? {
    FixtureDNSStore()
}
func FixtureSCDynamicStoreCopyValue(_ store: FixtureDNSStore, _ key: CFString) -> CFPropertyList? {
    fixtureDNSValues[key as String] as CFPropertyList?
}
func FixtureSCDynamicStoreCopyKeyList(_ store: FixtureDNSStore, _ pattern: CFString) -> CFArray? {
    fixtureDNSValues.keys.filter { $0.range(of: pattern as String, options: .regularExpression) != nil } as CFArray
}
@discardableResult func FixtureSCDynamicStoreSetValue(_ store: FixtureDNSStore, _ key: CFString, _ value: CFPropertyList) -> Bool {
    fixtureDNSValues[key as String] = value
    return true
}
@discardableResult func FixtureSCDynamicStoreRemoveValue(_ store: FixtureDNSStore, _ key: CFString) -> Bool {
    fixtureDNSValues.removeValue(forKey: key as String)
    return true
}
func FixtureSCDynamicStoreSetMultiple(_ store: FixtureDNSStore, _ set: CFDictionary?, _ remove: CFArray?, _ notify: CFArray?) -> Bool {
    for (key, value) in set as? [String: Any] ?? [:] { fixtureDNSValues[key] = value }
    for key in remove as? [String] ?? [] { fixtureDNSValues.removeValue(forKey: key) }
    return true
}
enum RouteExecutionError: Error { case commandFailed(String) }
enum RouteExecutor {
    static func command(_ executable: String, _ arguments: [String]) throws -> String {
        fatalError("Fixture must inject cache operations; no system command may run")
    }
}
@main struct DNSCacheFailureRegression {
    static func main() throws {
        try DNSJournalSelfTest.run()
        precondition(fixtureDNSValues.isEmpty, "Fixture left DNS state behind")
        print("PASS: complete DNS journal suite with real private files and an isolated in-memory store; no system DNS changes")
    }
}
