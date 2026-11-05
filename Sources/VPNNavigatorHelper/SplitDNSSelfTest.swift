#if DEBUG
import Foundation
import Darwin
import VPNNavigatorCore

enum SplitDNSSelfTest {
    static func run() throws {
        let options = Array(CommandLine.arguments.dropFirst(7))
        let full = options.contains("--full-vpn")
        guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true", CommandLine.arguments.count >= 7,
              options.allSatisfy({ ["--full-vpn", "--ipv4-only", "--ipv6-only"].contains($0) || $0.hasPrefix("--port=") }),
              let domestic = UInt16(CommandLine.arguments[2]), let domesticBackup = UInt16(CommandLine.arguments[3]),
              let vpn = UInt16(CommandLine.arguments[4]), let vpnBackup = UInt16(CommandLine.arguments[5]) else { throw DNSJournalError.unavailable }
        let domains = try ChinaDNSRules.read(URL(fileURLWithPath: CommandLine.arguments[6]))
        guard domains.contains("www.baidu.com"), domains.contains("www.bilibili.com"),
              domains.contains("www.apple.com"), domains.contains("is1-ssl.mzstatic.com"),
              domains.contains("updates.cdn-apple.com"), !domains.contains("tv.apple.com"),
              !domains.contains("www.google.com"), !domains.contains("baidu.com.evil.test") else { throw DNSJournalError.unavailable }
        let proxy = SplitDNSProxy(domains: domains,
            domestic: [domestic, domesticBackup].map { .init(address: "127.0.0.1", port: $0) },
            vpn: [vpn, vpnBackup].map { .init(address: "127.0.0.1", port: $0) }, mode: full ? .fullVPN : .chinaDirect,
            hasIPv4: !options.contains("--ipv6-only"), hasIPv6: !options.contains("--ipv4-only"),
            preferredPort: options.first(where: { $0.hasPrefix("--port=") }).flatMap { UInt16($0.dropFirst(7)) } ?? 0)
        try proxy.start(); try proxy.verify()
        print("DNS_PROXY_PORT=\(proxy.port)"); fflush(stdout)
        DispatchQueue.global(qos: .utility).async {
            while let command = readLine() {
                if command == "STOP" {
                    proxy.stop(); proxy.stop()
                    print("DNS_PROXY_STOPPED"); fflush(stdout); exit(0)
                }
                guard ["FULL", "SPLIT"].contains(command) else { exit(1) }
                do {
                    try proxy.reconfigure(domains: domains,
                        domestic: [domestic, domesticBackup].map { .init(address: "127.0.0.1", port: $0) },
                        vpn: [vpn, vpnBackup].map { .init(address: "127.0.0.1", port: $0) },
                        mode: command == "FULL" ? .fullVPN : .chinaDirect,
                        hasIPv4: !options.contains("--ipv6-only"), hasIPv6: !options.contains("--ipv4-only"))
                    print("DNS_PROXY_PORT=\(proxy.port)"); fflush(stdout)
                } catch { exit(1) }
            }
        }
        // Explicitly disposable debug process; no routes, journal or service
        // activation. The caller terminates only the child Process it started.
        RunLoop.main.run()
        proxy.stop()
    }
}
#endif
