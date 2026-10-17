import Foundation
import SystemConfiguration

/// React to route/interface notifications instead of relying solely on the
/// five-second watchdog. This checks routing; it is not a packet filter.
final class NetworkChangeMonitor {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        store = SCDynamicStoreCreate(nil, "VPNNavigator.NetworkMonitor" as CFString, { _, _, pointer in
            guard let pointer else { return }
            Unmanaged<NetworkChangeMonitor>.fromOpaque(pointer).takeUnretainedValue().changed()
        }, &context)
        guard let store else { return }
        let patterns = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                        "State:/Network/Interface/.*/Link", "State:/Network/Interface/.*/IPv4"]
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns as CFArray),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }
    deinit {
        if let source { CFRunLoopSourceInvalidate(source) }
    }
}
