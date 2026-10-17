import Foundation

/// Accept only stable, numeric macOS release versions.
public struct ReleaseVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3 else { return nil }
        var numbers: [Int] = []
        for component in components {
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(component), number >= 0 else { return nil }
            numbers.append(number)
        }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
    public var description: String { "\(major).\(minor).\(patch)" }
}

public enum ReleaseAssetPolicy {
    public static func supportsArchitecture(_ filename: String, architecture: String) -> Bool {
        guard ["arm64", "x86_64"].contains(architecture), filename.lowercased().hasSuffix(".pkg") else { return false }
        let name = filename.lowercased()
        if name.contains("universal") { return true }
        if name.contains("arm64") { return architecture == "arm64" }
        if name.contains("x86_64") || name.contains("x64") { return architecture == "x86_64" }
        // Older releases used one installer name without an architecture suffix.
        return !name.contains("intel") && !name.contains("aarch64")
    }
    public static func isApprovedReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" &&
        url.path.hasPrefix("/javafancn/vpn-navigator/releases/tag/")
    }
    public static func isApprovedInstaller(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" &&
        url.path.hasPrefix("/javafancn/vpn-navigator/releases/download/") &&
        url.pathExtension.lowercased() == "pkg"
    }
}

