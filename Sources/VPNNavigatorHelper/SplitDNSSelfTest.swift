#if DEBUG
import Foundation
import VPNNavigatorCore

enum SplitDNSSelfTest {
    static func run() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", CommandLine.arguments.count == 5,
              let domestic = UInt16(CommandLine.arguments[2]), let vpn = UInt16(CommandLine.arguments[3]) else { throw DNSJournalError.unavailable }
        let domains = try ChinaDNSRules.read(URL(fileURLWithPath: CommandLine.arguments[4]))
        guard domains.contains("www.baidu.com"), domains.contains("www.bilibili.com"),
              !domains.contains("www.google.com"), !domains.contains("baidu.com.evil.test") else { throw DNSJournalError.unavailable }
        let proxy = SplitDNSProxy(domains: domains, domestic: [.init(address: "127.0.0.1", port: domestic)],
            vpn: [.init(address: "127.0.0.1", port: vpn)])
        try proxy.start(); try proxy.verify()
        print("DNS_PROXY_PORT=\(proxy.port)"); fflush(stdout)
        // Explicitly disposable debug process; no routes, journal or service
        // activation. The caller terminates only the child Process it started.
        RunLoop.main.run()
        proxy.stop()
    }
}
#endif
