#if DEBUG
import Foundation
import VPNNavigatorCore

enum SplitDNSSelfTest {
    static func run() throws {
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", CommandLine.arguments.count == 7,
              let domestic = UInt16(CommandLine.arguments[2]), let domesticBackup = UInt16(CommandLine.arguments[3]),
              let vpn = UInt16(CommandLine.arguments[4]), let vpnBackup = UInt16(CommandLine.arguments[5]) else { throw DNSJournalError.unavailable }
        let domains = try ChinaDNSRules.read(URL(fileURLWithPath: CommandLine.arguments[6]))
        guard domains.contains("www.baidu.com"), domains.contains("www.bilibili.com"),
              !domains.contains("www.google.com"), !domains.contains("baidu.com.evil.test") else { throw DNSJournalError.unavailable }
        let proxy = SplitDNSProxy(domains: domains,
            domestic: [domestic, domesticBackup].map { .init(address: "127.0.0.1", port: $0) },
            vpn: [vpn, vpnBackup].map { .init(address: "127.0.0.1", port: $0) })
        try proxy.start(); try proxy.verify()
        print("DNS_PROXY_PORT=\(proxy.port)"); fflush(stdout)
        // Explicitly disposable debug process; no routes, journal or service
        // activation. The caller terminates only the child Process it started.
        RunLoop.main.run()
        proxy.stop()
    }
}
#endif
